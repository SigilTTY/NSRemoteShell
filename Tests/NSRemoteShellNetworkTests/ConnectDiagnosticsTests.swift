//
//  ConnectDiagnosticsTests.swift
//
//  A connect that never reaches the SSH handshake must say where it
//  stopped, and soon. The TCP dial was a bare blocking connect(): a host
//  that drops packets waited out the system SYN timeout (75 s) per address,
//  and every failure — no such host, refused port, timeout — ended with no
//  lastError at all, so the app could only print "Connection rejected".
//

import Network
import XCTest
@testable import NSRemoteShell

final class ConnectDiagnosticsTests: XCTestCase {
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [NSRemoteShellConnectEvent] = []
        func append(_ event: NSRemoteShellConnectEvent) { lock.withLock { events.append(event) } }
        var steps: [NSRemoteShellConnectStep] { lock.withLock { events.map(\.step) } }
        var all: [NSRemoteShellConnectEvent] { lock.withLock { events } }
    }

    private func connect(host: String, port: Int, tcpTimeout: Double) -> (NSRemoteShell, EventLog, TimeInterval) {
        let log = EventLog()
        let shell = NSRemoteShell()
            .setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: port))
            .setupConnectionTimeout(NSNumber(value: 30))
            .setupTCPConnectTimeout(NSNumber(value: tcpTimeout))
            .setupConnectEventHandler { log.append($0) }
        let start = Date()
        shell.requestConnectAndWait()
        return (shell, log, Date().timeIntervalSince(start))
    }

    /// A loopback port nothing listens on: bind, read the port, close.
    private func closedLoopbackPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(fd, $0, len)
                _ = getsockname(fd, $0, &len)
            }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    func testRefusedPortSaysRefused() {
        let port = closedLoopbackPort()
        let (shell, log, elapsed) = connect(host: "127.0.0.1", port: port, tcpTimeout: 10)
        XCTAssertFalse(shell.isConnected)
        XCTAssertLessThan(elapsed, 3)
        // An IP literal is dialed straight away, no lookup step.
        XCTAssertEqual(log.steps, [.dialing, .dialFailed])
        XCTAssertEqual(log.all.last?.errorCode, ECONNREFUSED)
        XCTAssertEqual(log.all.last?.address, "127.0.0.1")
        let error = shell.getLastError() ?? ""
        XCTAssertTrue(error.contains("Connection refused"), error)
    }

    func testSilentHostTimesOutWithinTheBudget() {
        // TEST-NET-1 (RFC 5737) is never routed; depending on the network
        // the SYN is dropped (timeout) or refused by a router (unreachable).
        let (shell, log, elapsed) = connect(host: "192.0.2.1", port: 22, tcpTimeout: 2)
        XCTAssertFalse(shell.isConnected)
        XCTAssertLessThan(elapsed, 5)
        XCTAssertEqual(log.steps.first, .dialing)
        XCTAssertEqual(log.all.first?.timeout ?? 0, 2, accuracy: 0.5)
        XCTAssertEqual(log.steps.last, .dialFailed)
        let code = log.all.last?.errorCode ?? 0
        XCTAssertTrue([ETIMEDOUT, EHOSTUNREACH, ENETUNREACH].contains(code), "errno \(code)")
        XCTAssertNotNil(shell.getLastError())
    }

    func testUnknownHostSaysItCouldNotResolve() {
        let (shell, log, _) = connect(host: "no-such-host.invalid", port: 22, tcpTimeout: 5)
        XCTAssertFalse(shell.isConnected)
        XCTAssertEqual(log.steps, [.resolving, .resolveFailed])
        XCTAssertNotNil(log.all.last?.detail)
        let error = shell.getLastError() ?? ""
        XCTAssertTrue(error.hasPrefix("Could not resolve host no-such-host.invalid"), error)
    }

    func testOpenPortThatIsNotSSHReportsTheTCPConnection() throws {
        // A listener that accepts and says nothing: TCP is fine, the SSH
        // handshake is what fails, and the events must tell those apart.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listening")
        listener.newConnectionHandler = { $0.start(queue: .global()) }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = Int(listener.port?.rawValue ?? 0)

        let log = EventLog()
        let shell = NSRemoteShell()
            .setupConnectionHost("127.0.0.1")
            .setupConnectionPort(NSNumber(value: port))
            .setupConnectionTimeout(NSNumber(value: 2))
            .setupConnectEventHandler { log.append($0) }
        shell.requestConnectAndWait()
        XCTAssertFalse(shell.isConnected)
        XCTAssertEqual(log.steps, [.dialing, .connected])
        XCTAssertNotNil(shell.getLastError())
    }
}
