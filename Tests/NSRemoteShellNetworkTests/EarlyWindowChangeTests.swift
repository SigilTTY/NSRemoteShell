//
//  EarlyWindowChangeTests.swift
//
//  Regression test for servers that deadlock on a window-change sent
//  between pty-req and the shell request. gliderlabs/ssh (JumpServer's koko
//  gateway) puts the pty-req size into a one-slot channel that only drains
//  once the shell handler runs; an early window-change blocks its request
//  loop, so the shell request never gets a reply and nothing is ever drawn.
//  Before the fix the pty-req always carried 80x24 and the real size
//  followed as a window-change before the shell — any size but 80x24 hung.
//
//  OpenSSH's sshd doesn't show the bug, so this targets a real gliderlabs
//  server and is skipped unless the environment names one:
//
//    NSREMOTESHELL_GLIDER_HOST=… NSREMOTESHELL_GLIDER_PORT=2222 \
//    NSREMOTESHELL_GLIDER_USER=… NSREMOTESHELL_GLIDER_PASSWORD=… \
//    swift test --filter EarlyWindowChange
//

import XCTest
@testable import NSRemoteShell

final class EarlyWindowChangeTests: XCTestCase {
    func testShellOpensWithNonDefaultSize() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["NSREMOTESHELL_GLIDER_HOST"],
              let user = env["NSREMOTESHELL_GLIDER_USER"],
              let password = env["NSREMOTESHELL_GLIDER_PASSWORD"] else {
            throw XCTSkip("set NSREMOTESHELL_GLIDER_HOST/USER/PASSWORD to run")
        }
        let port = env["NSREMOTESHELL_GLIDER_PORT"].flatMap(Int.init) ?? 22

        let shell = NSRemoteShell()
            .setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: port))
            .setupConnectionTimeout(NSNumber(value: 10))
        shell.requestConnectAndWait()
        defer { shell.requestDisconnectAndWait() }
        shell.authenticate(with: user, andPassword: password)
        XCTAssertTrue(shell.isAuthenticated, shell.getLastError() ?? "no error")

        let lock = NSLock()
        var created = false
        var received = 0
        let deadline = Date(timeIntervalSinceNow: 8)
        let done = expectation(description: "shell ended")
        DispatchQueue.global().async {
            shell.begin(withTerminalType: "xterm-256color",
                withOnCreate: { lock.withLock { created = true } },
                withTerminalSize: { CGSize(width: 120, height: 40) },
                withWriteDataBuffer: { "" },
                withRawWriteDataBuffer: nil,
                withOutputDataBuffer: { data in lock.withLock { received += data.count } },
                withContinuationHandler: { Date() < deadline }
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        lock.withLock {
            XCTAssertTrue(created, "shell request never completed")
            // A drawn 120x40 screen is tens of KB; a hung request yields 0.
            XCTAssertGreaterThan(received, 1024)
        }
    }
}
