//
//  NetworkCutTests.swift
//
//  Regression tests for dead-connection detection: a network cut (RST or
//  firewall-style blackhole) must end the shell session in bounded time —
//  begin() returning is what lets the app flip its connection state; before
//  the fix it never returned and the UI showed a live (green) session with a
//  frozen terminal forever.
//
//  The rig runs a real user-mode sshd (temp host key, pubkey auth as the
//  current user) behind a controllable TCP proxy, and cuts the link once the
//  shell produces output. macOS only; skipped where /usr/sbin/sshd is absent.
//

import XCTest
@testable import NSRemoteShell

final class NetworkCutTests: XCTestCase {
    // MARK: - Rig

    enum ProxyMode { case relay, blackhole }

    final class Rig {
        let work: URL
        let sshdPort: Int
        let proxyPort: Int
        let sshd: Process
        let clientPub: String
        let clientPriv: String

        private let lock = NSLock()
        private var mode: ProxyMode = .relay
        private var appSideFD: Int32 = -1
        private var upstreamFD: Int32 = -1
        private var listenFD: Int32 = -1

        init() throws {
            signal(SIGPIPE, SIG_IGN)
            work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nsremoteshell-netcut-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            func keygen(_ path: String) throws {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                p.arguments = ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
            }
            let hostKey = work.appendingPathComponent("host_rsa").path
            let clientKey = work.appendingPathComponent("client_rsa").path
            try keygen(hostKey)
            try keygen(clientKey)
            clientPub = try String(contentsOfFile: clientKey + ".pub", encoding: .utf8)
            clientPriv = try String(contentsOfFile: clientKey, encoding: .utf8)
            try clientPub.write(
                toFile: work.appendingPathComponent("authorized_keys").path,
                atomically: true, encoding: .utf8
            )

            sshdPort = Int.random(in: 42000 ..< 43000)
            proxyPort = sshdPort + 1000
            let config = """
            Port \(sshdPort)
            ListenAddress 127.0.0.1
            HostKey \(hostKey)
            PidFile \(work.path)/sshd.pid
            AuthorizedKeysFile \(work.path)/authorized_keys
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            UsePAM no
            StrictModes no
            LogLevel INFO
            """
            let configPath = work.appendingPathComponent("sshd_config").path
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)

            sshd = Process()
            sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            sshd.arguments = ["-D", "-f", configPath, "-E", work.appendingPathComponent("sshd.log").path]
            sshd.standardOutput = FileHandle.nullDevice
            sshd.standardError = FileHandle.nullDevice
            try sshd.run()
            Thread.sleep(forTimeInterval: 1.0)
            guard sshd.isRunning else { throw XCTSkip("sshd failed to start in test environment") }
            try startProxy()
        }

        deinit {
            if sshd.isRunning { sshd.terminate() }
            if listenFD >= 0 { close(listenFD) }
            if appSideFD >= 0 { close(appSideFD) }
            if upstreamFD >= 0 { close(upstreamFD) }
            try? FileManager.default.removeItem(at: work)
        }

        private func currentMode() -> ProxyMode {
            lock.lock(); defer { lock.unlock() }
            return mode
        }

        private func startProxy() throws {
            listenFD = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(proxyPort).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let fd = listenFD
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc == 0, listen(listenFD, 4) == 0 else {
                throw XCTSkip("proxy bind failed (port \(proxyPort) busy?)")
            }

            let sshdPort = self.sshdPort
            Thread.detachNewThread { [weak self] in
                guard let listenFD = self?.listenFD else { return }
                var clientAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
                }
                guard client >= 0 else { return }
                let up = socket(AF_INET, SOCK_STREAM, 0)
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = in_port_t(sshdPort).bigEndian
                target.sin_addr.s_addr = inet_addr("127.0.0.1")
                let rc = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(up, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard rc == 0 else { close(client); return }
                self?.appSideFD = client
                self?.upstreamFD = up
                Thread.detachNewThread { [weak self] in self?.pump(client, up) }
                self?.pump(up, client)
            }
        }

        private func pump(_ from: Int32, _ to: Int32) {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                if currentMode() == .blackhole { Thread.sleep(forTimeInterval: 0.05); continue }
                var pfd = pollfd(fd: from, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, 100)
                if pr < 0 { break }
                if pr == 0 { continue }
                let n = read(from, &buf, buf.count)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    // &buf[off] would pass a pointer to a 1-element temporary
                    let w = buf.withUnsafeBytes { p in
                        write(to, p.baseAddress!.advanced(by: off), n - off)
                    }
                    if w <= 0 { return }
                    off += w
                }
            }
        }

        func cutBlackhole() {
            lock.lock(); mode = .blackhole; lock.unlock()
        }

        func cutRST() {
            var lin = linger(l_onoff: 1, l_linger: 0)
            setsockopt(appSideFD, SOL_SOCKET, SO_LINGER, &lin, socklen_t(MemoryLayout<linger>.size))
            close(appSideFD)
            close(upstreamFD)
            appSideFD = -1
            upstreamFD = -1
        }
    }

    // MARK: - Shared scenario

    private struct Outcome {
        let detected: TimeInterval?
        let sessionEnd: NSRemoteShellSessionEnd
    }

    /// Connects a shell through the rig, waits for output, applies `cut`,
    /// and returns the seconds until the session end was detected (begin()
    /// returned or isConnected flipped; nil if never within `window`) plus
    /// the reason the shell reported. `input` feeds the write buffer.
    private func detectionTime(
        keepAlive: Int,
        wantReply: Bool,
        window: TimeInterval,
        input: (() -> String)? = nil,
        cut: (Rig) -> Void
    ) throws -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else {
            throw XCTSkip("no sshd on this platform")
        }
        let rig = try Rig()

        let shell = NSRemoteShell()
            .setupConnectionHost("127.0.0.1")
            .setupConnectionPort(NSNumber(value: rig.proxyPort))
            .setupConnectionTimeout(NSNumber(value: 30))
            .setupKeepAliveInterval(NSNumber(value: keepAlive))
            .setupKeepAliveWantReply(wantReply)
        defer { shell.destroyPermanently() }

        shell.requestConnectAndWait()
        guard shell.isConnected else {
            throw XCTSkip("connect through local proxy failed — see \(rig.work.path)/sshd.log")
        }
        shell.authenticate(with: NSUserName(), andPublicKey: rig.clientPub,
                           andPrivateKey: rig.clientPriv, andPassword: "")
        guard shell.isAuthenticated else {
            throw XCTSkip("pubkey auth against local sshd failed — see \(rig.work.path)/sshd.log")
        }

        let outputSeen = expectation(description: "shell output")
        outputSeen.assertForOverFulfill = false
        let beginReturned = NSLock()
        var didReturn = false

        Thread.detachNewThread {
            shell.begin(
                withTerminalType: "xterm-256color",
                withOnCreate: {},
                withTerminalSize: { CGSize(width: 80, height: 24) },
                withWriteDataBuffer: input ?? { "" },
                withOutputDataBuffer: { _ in outputSeen.fulfill() },
                withContinuationHandler: { true }
            )
            beginReturned.lock(); didReturn = true; beginReturned.unlock()
        }
        wait(for: [outputSeen], timeout: 15)
        Thread.sleep(forTimeInterval: 1.0)

        cut(rig)
        let cutAt = Date()
        while Date().timeIntervalSince(cutAt) < window {
            beginReturned.lock(); let r = didReturn; beginReturned.unlock()
            if r || !shell.isConnected {
                return Outcome(detected: Date().timeIntervalSince(cutAt),
                               sessionEnd: shell.lastShellSessionEnd)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return Outcome(detected: nil, sessionEnd: shell.lastShellSessionEnd)
    }

    // MARK: - Tests

    /// A hard cut (RST — what most network tools send when killing a
    /// connection) must end the session promptly even with keep-alive off,
    /// which is the app's default profile setting — and report it as a
    /// transport error, not a clean close.
    func testRSTCutEndsSessionPromptlyWithoutKeepAlive() throws {
        let outcome = try detectionTime(keepAlive: 0, wantReply: false, window: 10, cut: { $0.cutRST() })
        XCTAssertNotNil(outcome.detected, "RST cut was never detected: session stays 'connected' forever (green dot, frozen terminal)")
        if let t = outcome.detected { XCTAssertLessThan(t, 5, "RST cut detection should be near-immediate") }
        XCTAssertEqual(outcome.sessionEnd, .transportError, "an RST cut is an unexpected transport failure")
    }

    /// A silent cut (firewall-style blackhole: sockets stay open, no bytes
    /// flow) must be detected via keep-alive within ~3 missed intervals when
    /// the interval is configured — and also report a transport failure.
    func testBlackholeCutDetectedByKeepAlive() throws {
        let interval = 2
        let outcome = try detectionTime(keepAlive: interval, wantReply: true, window: 25, cut: { $0.cutBlackhole() })
        XCTAssertNotNil(outcome.detected, "blackhole cut was never detected despite keep-alive \(interval)s: session stays 'connected' forever")
        XCTAssertEqual(outcome.sessionEnd, .transportError, "a dead-peer keep-alive end is an unexpected transport failure")
    }

    /// Typing `exit` ends the session through the remote's orderly close —
    /// the shell must report RemoteClosed so the app can message it as a
    /// normal end rather than a connection failure.
    func testCleanRemoteExitReportsRemoteClosed() throws {
        let sent = NSLock()
        var didSend = false
        let outcome = try detectionTime(
            keepAlive: 0, wantReply: false, window: 15,
            input: {
                sent.lock(); defer { sent.unlock() }
                if didSend { return "" }
                didSend = true
                return "exit\n"
            },
            cut: { _ in }  // no cut — the remote closes on its own
        )
        XCTAssertNotNil(outcome.detected, "clean exit never ended the session")
        XCTAssertEqual(outcome.sessionEnd, .remoteClosed, "an orderly remote close must not read as a failure")
    }
}
