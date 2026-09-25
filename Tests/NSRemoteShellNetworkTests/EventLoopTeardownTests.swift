//
//  EventLoopTeardownTests.swift
//
//  Regression tests for a shell used or destroyed right after it was
//  created. Before 1.2.3 the event-loop thread filled in its run loop,
//  port and timer after init had returned, while destroyLoop (and every
//  request's port nudge) read them from other threads: a read that landed
//  mid-assignment hit the Xcode 26 runtime's 0x400000000000bad0 setter
//  sentinel and crashed, and a destroy that came before the thread's setup
//  did nothing, leaving the loop idling until the shell was released.
//
//  The first test pins the invariant that closes the race: what other
//  threads read exists before init returns. The others pin that the
//  teardown, now done by the loop thread itself, still ends every loop —
//  the event loop retains itself (thread target, timer target) until it
//  has ended, so its deallocation is the proof. No network needed.
//

import XCTest
@testable import NSRemoteShell

final class EventLoopTeardownTests: XCTestCase {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    private func eventLoop(of shell: NSRemoteShell) -> WeakBox {
        WeakBox(shell.value(forKey: "associatedLoop") as AnyObject?)
    }

    private func waitUntilReleased(_ loops: [WeakBox], file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while loops.contains(where: { $0.object != nil }), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let alive = loops.filter { $0.object != nil }.count
        XCTAssertEqual(alive, 0, "\(alive) of \(loops.count) event loops never stopped", file: file, line: line)
    }

    func testPortAndTimerExistWhenInitReturns() {
        var missing = 0
        for _ in 0..<200 {
            autoreleasepool {
                let shell = NSRemoteShell()
                let loop = shell.value(forKey: "associatedLoop") as? NSObject
                if loop?.value(forKey: "associatedPort") == nil
                    || loop?.value(forKey: "associatedTimer") == nil {
                    missing += 1
                }
                shell.destroyPermanently()
            }
        }
        XCTAssertEqual(missing, 0, "\(missing) of 200 shells returned from init before their loop was set up")
    }

    func testShellsDestroyedAtCreationStopTheirLoops() {
        var loops: [WeakBox] = []
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            autoreleasepool {
                let shell = NSRemoteShell()
                let loop = eventLoop(of: shell)
                shell.destroyPermanently()
                objc_sync_enter(self); loops.append(loop); objc_sync_exit(self)
            }
        }
        waitUntilReleased(loops)
    }

    func testShellsReleasedAtCreationStopTheirLoops() {
        var loops: [WeakBox] = []
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            autoreleasepool {
                let loop = eventLoop(of: NSRemoteShell())
                objc_sync_enter(self); loops.append(loop); objc_sync_exit(self)
            }
        }
        waitUntilReleased(loops)
    }

    func testRequestRightAfterCreationRunsOnTheLoop() {
        var loops: [WeakBox] = []
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            autoreleasepool {
                let shell = NSRemoteShell()
                // Queues a block and nudges the port from this thread, then
                // waits for the loop thread to run it — a loop that never
                // started or lost the nudge would hang here.
                shell.requestDisconnectAndWait()
                let loop = eventLoop(of: shell)
                shell.destroyPermanently()
                objc_sync_enter(self); loops.append(loop); objc_sync_exit(self)
            }
        }
        waitUntilReleased(loops)
    }
}
