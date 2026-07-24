//
//  NSRemoteChannelAgentForward.m
//
//

#import "NSRemoteChannelAgentForward.h"

@interface NSRemoteChannelAgentForward ()

@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, nullable, readwrite, assign) LIBSSH2_CHANNEL *representedChannel;
@property (nonatomic, nullable, strong) NSRemoteAgentForwardHandler handler;
@property (nonatomic, strong) NSMutableData *outgoing;
@property (nonatomic, readwrite) BOOL channelCompleted;

@end

@implementation NSRemoteChannelAgentForward

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedChannel:(LIBSSH2_CHANNEL *)representedChannel
                                withHandler:(NSRemoteAgentForwardHandler)handler {
    self = [super init];
    if (self) {
        _representedSession = representedSession;
        _representedChannel = representedChannel;
        _handler = handler;
        _outgoing = [[NSMutableData alloc] init];
        _channelCompleted = NO;
    }
    return self;
}

- (void)dealloc {
    [self unsafeDisconnectAndPrepareForRelease];
}

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.channelCompleted = YES; return NO; }
    if (!self.representedChannel) { self.channelCompleted = YES; return NO; }
    return YES;
}

// Drain everything the server sent, feed each chunk to the handler (which
// frames agent messages itself), queue the replies, then flush. Agent
// traffic is tiny (list identities + a sign or two), so reading to EAGAIN
// per tick can't starve the loop.
- (void)unsafeAgentPump {
    char buffer[BUFFER_SIZE];
    while (true) {
        long rc = libssh2_channel_read(self.representedChannel, buffer, (ssize_t)sizeof(buffer));
        if (rc > 0) {
            NSData *incoming = [NSData dataWithBytes:buffer length:rc];
            NSData *response = self.handler ? self.handler(incoming) : nil;
            if (response.length > 0) { [self.outgoing appendData:response]; }
            continue;
        }
        break; // EAGAIN, 0, or error — nothing more to read this tick
    }
    [self unsafeFlushOutgoing];
}

- (void)unsafeFlushOutgoing {
    while (self.outgoing.length > 0) {
        long rc = libssh2_channel_write(self.representedChannel,
                                        self.outgoing.bytes,
                                        self.outgoing.length);
        if (rc == LIBSSH2_ERROR_EAGAIN) { break; } // retry next tick
        if (rc < 0) { self.channelCompleted = YES; break; }
        if (rc == 0) { break; }
        [self.outgoing replaceBytesInRange:NSMakeRange(0, rc) withBytes:NULL length:0];
    }
}

- (BOOL)unsafeShouldTerminate {
    long rc = libssh2_channel_eof(self.representedChannel);
    if (rc == 1) { return YES; }
    if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { return YES; }
    return NO;
}

// MARK: - NSRemoteOperableObject

- (void)unsafeCallNonblockingOperations {
    if (self.channelCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeAgentPump];
    if ([self unsafeShouldTerminate]) { self.channelCompleted = YES; }
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    if (self.channelCompleted) { return NO; }
    if (![self seatbeltCheckPassed]) { return NO; }
    return YES;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.channelCompleted) { self.channelCompleted = YES; }
    if (!self.representedSession) { return; }
    if (!self.representedChannel) { return; }
    LIBSSH2_CHANNEL *channel = self.representedChannel;
    self.representedChannel = NULL;
    self.representedSession = NULL;
    self.handler = NULL;
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_send_eof(channel));
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_close(channel));
    LIBSSH2_BOUNDED_SHUTDOWN_STEP(libssh2_channel_free(channel));
}

@end
