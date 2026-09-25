//
//  NSRemoteEvent.m
//
//
//  Created by Lakr Aream on 2022/2/5.
//

// TS: Thread Safe

#import "TSEventLoop.h"

#import <stdatomic.h>

// Threading contract. The port and the timer are created in init, before
// the loop thread starts, and never reassigned, so any thread may read
// them. Only the loop thread touches its run loop: it schedules the port
// and the timer, runs until a stop is requested, then unschedules them
// itself (NSRunLoop is not thread-safe, and a timer must be invalidated on
// the thread that installed it). Other threads only raise stopRequested and
// nudge the loop through the port.
//
// Before 1.2.3 the loop thread assigned these properties after init had
// returned, while destroyLoop and explicitRequestHandle read them from
// other threads. A shell destroyed, or sent a request, right after it was
// created could read a property mid-assignment — under the Xcode 26
// runtime that is the 0x400000000000bad0 setter sentinel, and a crash.

@interface TSEventLoop () {
    atomic_bool _stopRequested;
}

@property (nonatomic, nonnull, strong) NSThread *associatedThread;
@property (nonatomic, nonnull, strong) NSTimer *associatedTimer;
@property (nonatomic, nonnull, strong) NSPort *associatedPort;
@property (nonatomic, nullable, weak) NSRemoteShell *parent;

@end

@implementation TSEventLoop

- (instancetype)initWithParent:(__weak NSRemoteShell*)parent {
    if (self = [super init]) {
        _parent = parent;
        atomic_init(&_stopRequested, false);
        _associatedPort = [[NSPort alloc] init];
        _associatedPort.delegate = self;
        _associatedTimer = [[NSTimer alloc] initWithFireDate: [[NSDate alloc] init]
                                                    interval:0.1
                                                      target:self selector:@selector(associatedLoopHandler)
                                                    userInfo:NULL
                                                     repeats:YES];
        _associatedThread = [[NSThread alloc] initWithTarget:self
                                                    selector:@selector(associatedThreadHandler)
                                                      object:NULL];
        NSString *threadName = [[NSString alloc] initWithFormat:@"wiki.qaq.shell.%p", parent];
        [_associatedThread setName:threadName];
        NSLog(@"opening thread %@", threadName);
        [_associatedThread start];
    }
    return self;
}

- (void)dealloc {
    // The loop thread and the timer both retain self until the loop has
    // ended and unscheduled everything, so there is nothing left to stop.
    NSLog(@"TSEventLoop object at %p deallocating", self);
}

- (void)explicitRequestHandle {
    [self.associatedPort sendBeforeDate:[[NSDate alloc] init]
                             components:NULL
                                   from:NULL
                               reserved:NO];
}

- (void)associatedThreadHandler {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    [runLoop addPort:self.associatedPort forMode:NSRunLoopCommonModes];
    [runLoop addTimer:self.associatedTimer forMode:NSRunLoopCommonModes];
    // Checked before every pass, so a stop requested before this thread
    // got here still ends it; runMode:beforeDate: returns NO only when
    // nothing is scheduled, which never happens before the teardown below.
    while (!atomic_load(&_stopRequested)) {
        BOOL ran;
        @autoreleasepool {
            ran = [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
        if (!ran) { break; }
    }
    [self.associatedTimer invalidate];
    [runLoop removePort:self.associatedPort forMode:NSRunLoopCommonModes];
    NSLog(@"thread %@ exiting", [[NSThread currentThread] name]);
}

- (void)handleMachMessage:(void *)msg {
    // we don't care about the message, if received any, call handler
    [self associatedLoopHandler];
}

- (void)associatedLoopHandler {
    if (atomic_load(&_stopRequested)) {
        // A timer firing doesn't end runMode:beforeDate:, a stop does.
        CFRunLoopStop(CFRunLoopGetCurrent());
        return;
    }
    if (!self.parent) {
        [self destroyLoop];
        return;
    }
#if DEBUG
    NSString *name = [[NSThread currentThread] name];
    NSString *want = [[NSString alloc] initWithFormat:@"wiki.qaq.shell.%p", self.parent];
    if (![name isEqualToString:want]) {
        NSLog(@"\n\n");
        NSLog(@"[E] shell name mismatch");
        NSLog(@"expect: %@", want);
        NSLog(@" found: %@", name);
        NSLog(@"\n\n");
    }
#endif
    [self.parent handleRequestsIfNeeded];
    usleep(20000); // 50 times each second
}

// Any thread, any number of times: only the first call does anything. The
// loop thread tears itself down; from elsewhere the port message wakes it
// (if the port's queue is full the loop is about to run anyway, and the
// timer re-checks every 0.1 s).
- (void)destroyLoop {
    if (atomic_exchange(&_stopRequested, true)) { return; }
    if ([NSThread currentThread] == self.associatedThread) {
        CFRunLoopStop(CFRunLoopGetCurrent());
        return;
    }
    [self explicitRequestHandle];
}

@end
