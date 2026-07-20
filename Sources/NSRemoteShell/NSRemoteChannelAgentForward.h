//
//  NSRemoteChannelAgentForward.h
//
//  Services a reverse `auth-agent@openssh.com` channel that sshd opens when
//  a forwarded session uses the agent (SSH agent forwarding). Unlike
//  NSRemoteChannel this is byte-exact — the SSH agent protocol is binary,
//  not UTF-8 text — and it delegates every request/response to a handler
//  (the Swift AgentResponder) rather than a terminal.
//

#import <Foundation/Foundation.h>
#import "GenericHeaders.h"

NS_ASSUME_NONNULL_BEGIN

// Given the raw bytes read from the agent channel, returns the bytes to
// write back (may be nil/empty when a message is still incomplete).
typedef NSData * _Nullable (^NSRemoteAgentForwardHandler)(NSData *incoming);

@interface NSRemoteChannelAgentForward : NSObject <NSRemoteOperableObject>

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedChannel:(LIBSSH2_CHANNEL *)representedChannel
                                withHandler:(NSRemoteAgentForwardHandler)handler;

@end

NS_ASSUME_NONNULL_END
