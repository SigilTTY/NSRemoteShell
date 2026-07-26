//
//  NSRemoteChannel.m
//  
//
//  Created by Lakr Aream on 2022/2/6.
//

#import "NSRemoteChannel.h"

@interface NSRemoteChannel ()

@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, nullable, readwrite, assign) LIBSSH2_CHANNEL *representedChannel;

@property (nonatomic, nullable, strong) NSRemoteChannelRequestDataBlock requestDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelReceiveDataBlock receiveDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelContinuationBlock continuationDecisionBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelTerminalSizeBlock requestTerminalSizeBlock;

@property (nonatomic) CGSize currentTerminalSize;

@property (nonatomic, nullable, strong) NSDate *scheduledTermination;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;

@property (nonatomic, readwrite) BOOL channelCompleted;
@property (nonatomic, readwrite, assign) int exitStatus;
@property (nonatomic, readwrite, assign) NSRemoteShellSessionEnd terminationReason;

@end

@implementation NSRemoteChannel

// MARK: - LIFE CYCLE

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedChanel:(LIBSSH2_CHANNEL *)representedChannel
{
    self = [super init];
    if (self) {
        _representedSession = representedSession;
        _representedChannel = representedChannel;
        _channelCompleted = NO;
        _currentTerminalSize = CGSizeMake(0, 0);
        _exitStatus = 0;
        _terminationReason = NSRemoteShellSessionEndUnknown;
    }
    return self;
}

- (void)dealloc {
    NSLog(@"channel object at %p deallocating", self);
    [self unsafeDisconnectAndPrepareForRelease];
}

// MARK: - SETUP

- (void)onTermination:(dispatch_block_t)terminationHandler {
    self.terminationBlock = terminationHandler;
}

- (void)setRequestDataChain:(NSRemoteChannelRequestDataBlock _Nonnull)requestData {
    self.requestDataBlock = requestData;
}

- (void)setReceivedDataChain:(NSRemoteChannelReceiveDataBlock _Nonnull)receiveData {
    self.receiveDataBlock = receiveData;
}

- (void)setContinuationChain:(NSRemoteChannelContinuationBlock _Nonnull)continuation {
    self.continuationDecisionBlock = continuation;
}

- (void)setTerminalSizeChain:(NSRemoteChannelTerminalSizeBlock _Nonnull)terminalSize {
    self.requestTerminalSizeBlock = terminalSize;
}

- (void)setChannelTimeoutWith:(double)timeoutValueFromNowInSecond {
    if (timeoutValueFromNowInSecond <= 0) {
#if DEBUG
        NSLog(@"setChannelTimeoutWith was called with negative value or zero, setChannelTimeoutWithScheduled skipped");
#endif
    } else {
        NSDate *schedule = [[NSDate alloc] initWithTimeIntervalSinceNow:timeoutValueFromNowInSecond];
        [self setChannelTimeoutWithScheduled:schedule];
    }
}

- (void)setChannelTimeoutWithScheduled:(NSDate*)timeoutDate {
    self.scheduledTermination = timeoutDate;
}

- (void)setChannelCompleted:(BOOL)channelCompleted {
    if (_channelCompleted != channelCompleted) {
        _channelCompleted = channelCompleted;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

// First detected cause wins — later, less specific causes (e.g. the eof
// probe erroring on an already-released channel) must not overwrite it.
- (void)recordTerminationReason:(NSRemoteShellSessionEnd)reason {
    if (_terminationReason == NSRemoteShellSessionEndUnknown) {
        _terminationReason = reason;
    }
}

// MARK: - EXEC

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.channelCompleted = YES; return NO; }
    if (!self.representedChannel) { self.channelCompleted = YES; return NO; }
    return YES;
}

- (void)unsafeChannelRead {
    // Deliberately not zeroed: every consumer below is bounded by the byte
    // count libssh2 returns, so the tail is never read. Clearing 2×128 KB on
    // every pass — including the EAGAIN no-data passes this loop spins
    // through — was only ever there to NUL-terminate for a string decode.
    char buffer[BUFFER_SIZE];
    char errorBuffer[BUFFER_SIZE];

    long rcout = libssh2_channel_read(self.representedChannel, buffer, (ssize_t)sizeof(buffer));
    long rcerr = libssh2_channel_read_stderr(self.representedChannel, errorBuffer, (ssize_t)sizeof(errorBuffer));

    // Any error besides EAGAIN is terminal (socket recv/send failure after a
    // network cut, channel closed, protocol error) — the session will never
    // recover, so end the channel instead of silently retrying forever with
    // the connection still reported alive.
    if ((rcout < 0 && rcout != LIBSSH2_ERROR_EAGAIN) ||
        (rcerr < 0 && rcerr != LIBSSH2_ERROR_EAGAIN)) {
        NSLog(@"channel read failed (%ld/%ld), terminating channel", rcout, rcerr);
        [self recordTerminationReason:NSRemoteShellSessionEndTransportError];
        self.channelCompleted = YES;
        return;
    }

    // Length-delimited, never decoded here: initWithUTF8String: returns nil for
    // a chunk that is not valid UTF-8 (silently dropping the entire read) and
    // stops at the first NUL regardless of how many bytes were actually read.
    if (rcout != LIBSSH2_ERROR_EAGAIN && rcout > 0) {
        NSData *read = [[NSData alloc] initWithBytes:buffer length:rcout];
        if (self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
    if (rcerr != LIBSSH2_ERROR_EAGAIN && rcerr > 0) {
        NSData *read = [[NSData alloc] initWithBytes:errorBuffer length:rcerr];
        if (self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
}

- (void)unsafeChannelWrite {
    if (!self.requestDataBlock) {
        return;
    }
    NSString *requestedBuffer = self.requestDataBlock();
    if (!requestedBuffer || [requestedBuffer length] < 1) {
        return;
    }
    NSData *data = [requestedBuffer dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || [data length] < 1) {
        NSLog(@"error occurred during message encode, ignoring empty data");
        return;
    }
    // Bounded: on a dead link the send buffer fills and EAGAIN repeats
    // forever — an unbounded retry here would wedge the event loop thread.
    NSDate *writeDeadline = [[NSDate alloc] initWithTimeIntervalSinceNow:LIBSSH2_SHUTDOWN_GRACE_SECONDS];
    while (true) {
        if ([self unsafeChannelShouldTerminate]) {
            break;
        }
        // Actual number of bytes written or negative on failure.
        long rc = libssh2_channel_write(self.representedChannel, [data bytes], [data length]);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            if ([writeDeadline timeIntervalSinceNow] < 0) {
                NSLog(@"channel write stalled past grace period, dropping buffered input");
                break;
            }
            usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
            continue;
        }
        if (rc < 0) {
            NSLog(@"channel write failed (%ld), terminating channel", rc);
            [self recordTerminationReason:NSRemoteShellSessionEndTransportError];
            self.channelCompleted = YES;
            break;
        }
        if (rc != [data length]) {
            NSLog(@"written data was smaller than giving, data might broke");
            break;
        }
        // do not deal with error?
        break;
    }
}

- (BOOL)unsafeChannelShouldTerminate {
    do {
        if (self.scheduledTermination && [self.scheduledTermination timeIntervalSinceNow] < 0) {
            NSLog(@"channel terminating due to timeout schedule");
            [self recordTerminationReason:NSRemoteShellSessionEndContinuationEnded];
            break;
        }
        if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
            [self recordTerminationReason:NSRemoteShellSessionEndContinuationEnded];
            break;
        }
        long rc = libssh2_channel_eof(self.representedChannel);
        if (rc == 1) {
            [self recordTerminationReason:NSRemoteShellSessionEndRemoteClosed];
            break;
        }
        if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) {
            [self recordTerminationReason:NSRemoteShellSessionEndTransportError];
            break;
        }
        return NO;
    } while (0);
    self.channelCompleted = YES;
    return YES;
}

- (void)unsafeChannelTerminalSizeUpdate {
    // may called from outside
    if (![self seatbeltCheckPassed]) { return; }
    if (!self.requestTerminalSizeBlock) {
        return;
    }
    CGSize targetSize = self.requestTerminalSizeBlock();
    if (CGSizeEqualToSize(targetSize, self.currentTerminalSize)) {
        return;
    }
    self.currentTerminalSize = targetSize;
    while (true) {
        long rc = libssh2_channel_request_pty_size(self.representedChannel,
                                                   targetSize.width,
                                                   targetSize.height);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        // don't check error here?
        break;
    }
}

- (void)unsafeCallNonblockingOperations {
    if (self.channelCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeChannelRead];
    // A fatal read/write releases the channel mid-pass (setChannelCompleted
    // side effect) — the remaining steps must not touch the freed channel.
    if (self.channelCompleted) { return; }
    [self unsafeChannelTerminalSizeUpdate];
    [self unsafeChannelWrite];
    if (self.channelCompleted) { return; }
    [self unsafeChannelShouldTerminate];
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    do {
        if (self.channelCompleted) { break; }
        if (![self seatbeltCheckPassed]) { break; }
        return YES;
    } while (0);
    return NO;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.channelCompleted) { self.channelCompleted = YES; }
    if (!self.representedSession) { return; }
    if (!self.representedChannel) { return; }
    LIBSSH2_CHANNEL *channel = self.representedChannel;
    self.representedChannel = NULL;
    self.representedSession = NULL;
    // Bounded: after a network cut the close/wait-closed replies never
    // arrive; retrying EAGAIN forever would hang whichever thread runs the
    // teardown (event loop or bootstrap) with the tab stuck open.
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_send_eof(channel));
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_close(channel));
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_wait_closed(channel));
    int es = libssh2_channel_get_exit_status(channel);
    NSLog(@"channel get exit status returns: %d", es);
    self.exitStatus = es;
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_free(channel));
    if (self.terminationBlock) { self.terminationBlock(); }
    self.terminationBlock = NULL;
}

@end
