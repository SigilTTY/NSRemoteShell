//
//  AuxiliaryExecTests.swift
//
//  A PTY exec side channel (beginAuxiliaryExecuteWithCommand) running next
//  to the connection's interactive session must leave lastShellSessionEnd
//  alone: SigilTTY reads it to explain why the user's terminal ended, and
//  the Assistant's own shell closing is not that.
//
//  Needs any OpenSSH server with password auth:
//
//    NSREMOTESHELL_TEST_HOST=… NSREMOTESHELL_TEST_PORT=22 \
//    NSREMOTESHELL_TEST_USER=… NSREMOTESHELL_TEST_PASSWORD=… \
//    swift test --filter AuxiliaryExec
//

import XCTest
@testable import NSRemoteShell

final class AuxiliaryExecTests: XCTestCase {
    func testAuxiliaryChannelEndLeavesSessionEndAlone() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["NSREMOTESHELL_TEST_HOST"],
              let user = env["NSREMOTESHELL_TEST_USER"],
              let password = env["NSREMOTESHELL_TEST_PASSWORD"] else {
            throw XCTSkip("set NSREMOTESHELL_TEST_HOST/USER/PASSWORD to run")
        }
        let port = env["NSREMOTESHELL_TEST_PORT"].flatMap(Int.init) ?? 22

        let shell = NSRemoteShell()
            .setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: port))
            .setupConnectionTimeout(NSNumber(value: 10))
        shell.requestConnectAndWait()
        defer { shell.requestDisconnectAndWait() }
        shell.authenticate(with: user, andPassword: password)
        XCTAssertTrue(shell.isAuthenticated, shell.getLastError() ?? "no error")

        // The interactive session stays up for the whole test.
        let lock = NSLock()
        var keepShell = true
        let shellEnded = expectation(description: "shell ended")
        DispatchQueue.global().async {
            shell.begin(withTerminalType: "xterm-256color",
                withOnCreate: {},
                withTerminalSize: { CGSize(width: 80, height: 24) },
                withWriteDataBuffer: { "" },
                withRawWriteDataBuffer: nil,
                withOutputDataBuffer: { _ in },
                withContinuationHandler: { lock.withLock { keepShell } }
            )
            shellEnded.fulfill()
        }

        var created = false
        var output = Data()
        let status = shell.beginAuxiliaryExecute(withCommand: "printf aux-ok; exit 3",
            withTerminalType: "xterm-256color",
            withOnCreate: { lock.withLock { created = true } },
            withTerminalSize: { CGSize(width: 160, height: 48) },
            withWriteDataBuffer: { "" },
            withRawWriteDataBuffer: nil,
            withOutputDataBuffer: { data in lock.withLock { output.append(data) } },
            withContinuationHandler: { true }
        )

        lock.withLock {
            XCTAssertTrue(created)
            XCTAssertEqual(status, 3)
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("aux-ok"))
        }
        XCTAssertEqual(shell.lastShellSessionEnd, .unknown,
                       "the side channel's end must not stand in for the session's")
        XCTAssertTrue(shell.isConnected)

        lock.withLock { keepShell = false }
        wait(for: [shellEnded], timeout: 10)
    }
}
