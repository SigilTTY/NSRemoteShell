//
//  LocalForwardOpenFailureTests.swift
//
//  A local forward whose direct-tcpip open is refused must say why. The
//  connection dialed through the forward only sees its socket close, so a
//  jump-host caller has nothing to show but "connection rejected" unless the
//  forward records libssh2's reason (JumpServer's koko refuses with
//  "administratively prohibited" when port forwarding is disabled).
//
//  Runs against a throwaway user-mode sshd on loopback, like NetworkCutTests.
//

import XCTest
@testable import NSRemoteShell

final class LocalForwardOpenFailureTests: XCTestCase {
    private final class Sshd {
        let work: URL
        let port: Int
        let process: Process
        let clientPub: String
        let clientPriv: String

        init(allowTcpForwarding: Bool) throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else {
                throw XCTSkip("no sshd on this platform")
            }
            work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nsremoteshell-fwd-\(UUID().uuidString.prefix(8))")
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
            try clientPub.write(toFile: work.appendingPathComponent("authorized_keys").path,
                                atomically: true, encoding: .utf8)

            port = Int.random(in: 44000 ..< 45000)
            let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey)
            PidFile \(work.path)/sshd.pid
            AuthorizedKeysFile \(work.path)/authorized_keys
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            UsePAM no
            StrictModes no
            AllowTcpForwarding \(allowTcpForwarding ? "yes" : "no")
            """
            let configPath = work.appendingPathComponent("sshd_config").path
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)

            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-f", configPath, "-E", work.appendingPathComponent("sshd.log").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            Thread.sleep(forTimeInterval: 1.0)
            guard process.isRunning else { throw XCTSkip("sshd failed to start in test environment") }
        }

        deinit {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: work)
        }
    }

    /// Opens a local forward to the sshd's own port, dials it once and
    /// returns what the forwarding shell recorded plus whether the dialed
    /// connection got an SSH banner back.
    private func dialThroughForward(allowTcpForwarding: Bool) throws -> (failure: String?, gotBanner: Bool) {
        let sshd = try Sshd(allowTcpForwarding: allowTcpForwarding)
        let shell = NSRemoteShell()
            .setupConnectionHost("127.0.0.1")
            .setupConnectionPort(NSNumber(value: sshd.port))
            .setupConnectionTimeout(NSNumber(value: 10))
        defer { shell.destroyPermanently() }
        shell.requestConnectAndWait()
        shell.authenticate(with: NSUserName(), andPublicKey: sshd.clientPub,
                           andPrivateKey: sshd.clientPriv, andPassword: "")
        guard shell.isAuthenticated else {
            throw XCTSkip("pubkey auth against local sshd failed — see \(sshd.work.path)/sshd.log")
        }

        let created = expectation(description: "forward listening")
        var keepRunning = true
        let lock = NSLock()
        Thread.detachNewThread {
            shell.createPortForward(withLocalPort: NSNumber(value: 0),
                withForwardTargetHost: "127.0.0.1",
                withForwardTargetPort: NSNumber(value: sshd.port),
                withOnCreate: { created.fulfill() },
                withContinuationHandler: { lock.withLock { keepRunning } })
        }
        wait(for: [created], timeout: 10)
        defer { lock.withLock { keepRunning = false } }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(shell.lastUsedLocalPort).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(rc, 0, "dialing the forward's listener failed")
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        let gotBanner = n > 0 && String(decoding: buf.prefix(max(n, 0)), as: UTF8.self).hasPrefix("SSH-")
        // The reason is recorded before the dialed socket closes; the
        // property is set from the event loop, so give it a moment anyway.
        Thread.sleep(forTimeInterval: 0.5)
        return (shell.lastForwardOpenFailure, gotBanner)
    }

    func testRefusedForwardRecordsServerReason() throws {
        let result = try dialThroughForward(allowTcpForwarding: false)
        XCTAssertFalse(result.gotBanner)
        let failure = try XCTUnwrap(result.failure, "no reason recorded for the refused channel")
        XCTAssertTrue(failure.localizedCaseInsensitiveContains("prohibited"), failure)
    }

    func testWorkingForwardRecordsNothing() throws {
        let result = try dialThroughForward(allowTcpForwarding: true)
        XCTAssertTrue(result.gotBanner)
        XCTAssertNil(result.failure)
    }
}
