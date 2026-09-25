//
//  NSLocalForward.h
//  
//
//  Created by Lakr Aream on 2022/3/9.
//

#import "GenericHeaders.h"
#import "GenericNetworking.h"
#import "NSRemoteShell.h"
#import "NSRemoteChannelSocketPair.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSLocalForward : NSObject <NSRemoteOperableObject>

typedef BOOL (^NSRemoteChannelContinuationBlock)(void);
typedef void (^NSLocalForwardOpenFailureBlock)(NSString *reason);

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION*)representedSession
                     withRepresentedSocket:(int)socketDescriptor
                            withTargetHost:(NSString*)withTargetHost
                            withTargetPort:(NSNumber*)withTargetPort
                             withLocalPort:(NSNumber*)withLocalPort
                               withTimeout:(NSNumber*)withTimeout;

- (void)onTermination:(dispatch_block_t)terminationHandler;
- (void)setContinuationChain:(NSRemoteChannelContinuationBlock)continuation;
// Called on the event-loop thread with libssh2's reason when an accepted
// connection's direct-tcpip channel can't be opened, before its socket closes.
- (void)onChannelOpenFailure:(NSLocalForwardOpenFailureBlock)handler;

- (void)unsafeCallNonblockingOperations;
- (BOOL)unsafeInsanityCheckAndReturnDidSuccess;
- (void)unsafeDisconnectAndPrepareForRelease;

@end

NS_ASSUME_NONNULL_END
