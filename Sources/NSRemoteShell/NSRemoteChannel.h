//
//  NSRemoteChannel.h
//  
//
//  Created by Lakr Aream on 2022/2/6.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"
#import "NSRemoteShell.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSRemoteChannel : NSObject <NSRemoteOperableObject>

typedef NSString* _Nonnull (^NSRemoteChannelRequestDataBlock)(void);
// Raw bytes as read from the channel — NOT a string. Terminal output is a byte
// stream that is routinely invalid UTF-8 (vim's t_u7 ambiguous-width probe
// emits a bare 0xbd, binaries get cat'ed, multi-byte characters straddle chunk
// boundaries) and may contain NULs; decoding here would lose whole reads.
typedef void (^NSRemoteChannelReceiveDataBlock)(NSData *);
typedef BOOL (^NSRemoteChannelContinuationBlock)(void);
typedef CGSize (^NSRemoteChannelTerminalSizeBlock)(void);

/// Why this channel completed (first detected cause wins; Unknown until
/// something terminal happens). Read by NSRemoteShell when the shell
/// channel's termination fires.
@property (nonatomic, readonly) NSRemoteShellSessionEnd terminationReason;

@property (nonatomic, nullable, readonly, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, nullable, readonly, assign) LIBSSH2_CHANNEL *representedChannel;

@property (nonatomic, readonly) BOOL channelCompleted;

@property (nonatomic, readonly, assign) int exitStatus;

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION*)representedSession
                     withRepresentedChanel:(LIBSSH2_CHANNEL*)representedChannel;

- (void)onTermination:(dispatch_block_t)terminationHandler;

- (void)setRequestDataChain:(NSRemoteChannelRequestDataBlock _Nonnull)requestData;
- (void)setReceivedDataChain:(NSRemoteChannelReceiveDataBlock _Nonnull)receiveData;
- (void)setContinuationChain:(NSRemoteChannelContinuationBlock _Nonnull)continuation;
- (void)setTerminalSizeChain:(NSRemoteChannelTerminalSizeBlock _Nonnull)terminalSize;

- (void)setChannelTimeoutWith:(double)timeoutValueFromNowInSecond;
- (void)setChannelTimeoutWithScheduled:(NSDate*)timeoutDate;

- (void)unsafeChannelTerminalSizeUpdate;

- (void)unsafeCallNonblockingOperations;
- (BOOL)unsafeInsanityCheckAndReturnDidSuccess;
- (void)unsafeDisconnectAndPrepareForRelease;

@end

NS_ASSUME_NONNULL_END
