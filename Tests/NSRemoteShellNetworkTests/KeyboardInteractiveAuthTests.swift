//
//  KeyboardInteractiveAuthTests.swift
//
//  Regression test for password sign-in against a PAM-backed sshd that
//  offers only publickey,keyboard-interactive (FreeBSD's default sshd:
//  PasswordAuthentication no). Before the fix, authenticateWith:andPassword:
//  only tried the "password" method and such servers could never be reached
//  with a password.
//
//  A user-mode sshd can't run PAM, so this targets a real host and is
//  skipped unless the environment names one:
//
//    NSREMOTESHELL_KBDINT_HOST=… NSREMOTESHELL_KBDINT_USER=… \
//    NSREMOTESHELL_KBDINT_PASSWORD=… swift test --filter KeyboardInteractive
//

import XCTest
@testable import NSRemoteShell

final class KeyboardInteractiveAuthTests: XCTestCase {
    private func target() throws -> (host: String, port: Int, user: String, password: String) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["NSREMOTESHELL_KBDINT_HOST"],
              let user = env["NSREMOTESHELL_KBDINT_USER"],
              let password = env["NSREMOTESHELL_KBDINT_PASSWORD"] else {
            throw XCTSkip("set NSREMOTESHELL_KBDINT_HOST/USER/PASSWORD to run")
        }
        let port = env["NSREMOTESHELL_KBDINT_PORT"].flatMap(Int.init) ?? 22
        return (host, port, user, password)
    }

    private func connect(_ host: String, _ port: Int) -> NSRemoteShell {
        let shell = NSRemoteShell()
            .setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: port))
            .setupConnectionTimeout(NSNumber(value: 10))
        shell.requestConnectAndWait()
        return shell
    }

    func testCorrectPasswordAuthenticates() throws {
        let t = try target()
        let shell = connect(t.host, t.port)
        defer { shell.requestDisconnectAndWait() }
        XCTAssertTrue(shell.isConnected)
        shell.authenticate(with: t.user, andPassword: t.password)
        XCTAssertTrue(shell.isAuthenticated, shell.getLastError() ?? "no error")
    }

    // The app's flow with nothing stored: a silent empty-password try, then
    // the typed password on the same connection.
    func testWrongThenCorrectPasswordOnOneConnection() throws {
        let t = try target()
        let shell = connect(t.host, t.port)
        defer { shell.requestDisconnectAndWait() }
        shell.authenticate(with: t.user, andPassword: "")
        XCTAssertFalse(shell.isAuthenticated)
        shell.authenticate(with: t.user, andPassword: t.password)
        XCTAssertTrue(shell.isAuthenticated, shell.getLastError() ?? "no error")
    }
}
