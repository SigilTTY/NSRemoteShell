//
//  NSRemoteShell.h
//
//
//  Created by Lakr Aream on 2022/2/4.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "NSRemoteFile.h"

NS_ASSUME_NONNULL_BEGIN

/// Why the last shell channel ended — lets the app distinguish a clean
/// remote close (`exit`, server logout) from a broken link (network cut)
/// and from its own decision to stop.
typedef NS_ENUM(NSInteger, NSRemoteShellSessionEnd) {
    NSRemoteShellSessionEndUnknown = 0,
    /// The remote sent EOF / closed the channel in an orderly way.
    NSRemoteShellSessionEndRemoteClosed,
    /// A socket or protocol error killed the transport (cut network,
    /// keep-alive dead-peer detection, RST).
    NSRemoteShellSessionEndTransportError,
    /// The continuation handler asked to stop (app/user initiated).
    NSRemoteShellSessionEndContinuationEnded,
};

@interface NSRemoteShell : NSObject

@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, getter=isConnectedFileTransfer) BOOL connectedFileTransfer;
@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;

@property (nonatomic, readonly, strong) NSString *remoteHost;
@property (nonatomic, readonly, strong) NSNumber *remotePort;
@property (nonatomic, readonly, strong) NSNumber *operationTimeout;

@property (nonatomic, readonly, nullable, strong) NSString *resolvedRemoteIpAddress;
@property (nonatomic, readonly, nullable, strong) NSString *remoteBanner;
@property (nonatomic, readonly, nullable, strong) NSString *remoteFingerPrint;
// OpenSSH-style "SHA256:" + unpadded base64 host-key fingerprint, matching
// `ssh-keygen -l` output; used for known-host (TOFU) verification.
@property (nonatomic, readonly, nullable, strong) NSString *remoteFingerprintSHA256;

@property (nonatomic, readonly, strong) NSNumber *keepAliveInterval;
@property (nonatomic, readonly) BOOL keepAliveWantReply;
@property (nonatomic, readonly) NSInteger lastUsedLocalPort;

/// Why the last interactive shell (beginShellWithTerminalType…) ended.
/// Reset to Unknown on every connect attempt.
@property (nonatomic, readonly) NSRemoteShellSessionEnd lastShellSessionEnd;

#pragma mark initializer

- (instancetype)init;
- (instancetype)setupConnectionHost:(NSString *)targetHost;
- (instancetype)setupConnectionPort:(NSNumber *)targetPort;
- (instancetype)setupConnectionTimeout:(NSNumber *)timeout;
- (instancetype)setupKeepAliveInterval:(NSNumber *)interval;
- (instancetype)setupKeepAliveWantReply:(BOOL)wantReply;

#pragma mark event loop

- (void)handleRequestsIfNeeded;
- (void)explicitRequestStatusPickup;

#pragma mark connection

- (void)requestConnectAndWait;
- (void)requestDisconnectAndWait;

#pragma mark authenticate

- (void)authenticateWith:(NSString *)username
             andPassword:(NSString *)password;
- (void)authenticateWith:(NSString *)username
            andPublicKey:(nullable NSString *)publicKey
           andPrivateKey:(NSString *)privateKey
             andPassword:(nullable NSString *)password;

#pragma mark helper

- (nullable NSString *)getLastError;
- (nullable NSString*)getLastFileTransferError;

#pragma mark execution

- (int)beginExecuteWithCommand:(NSString*)withCommand
                   withTimeout:(NSNumber*)withTimeoutSecond
                  withOnCreate:(dispatch_block_t)withOnCreate
                    withOutput:(nullable void (^)(NSString*))withOutput
       withContinuationHandler:(nullable BOOL (^)(void))withContinuationBlock;

- (void)beginShellWithTerminalType:(nullable NSString*)withTerminalType
                      withOnCreate:(dispatch_block_t)withOnCreate
                  withTerminalSize:(nullable CGSize (^)(void))withRequestTerminalSize
               withWriteDataBuffer:(nullable NSString* (^)(void))withWriteDataBuffer
// Output is delivered as raw bytes: a pty stream carries arbitrary encodings
// and control sequences, so decoding it to a string here would drop every
// chunk that is not valid UTF-8. Callers own the decoding (the terminal feeds
// the bytes straight to the emulator).
              withOutputDataBuffer:(void (^)(NSData * _Nonnull))withOutputDataBuffer
           withContinuationHandler:(BOOL (^)(void))withContinuationBlock;

#pragma mark agent forwarding

// Enables SSH agent forwarding on the next interactive shell. `handler` is
// invoked on the event-loop thread with the raw bytes read from the reverse
// auth-agent channel and returns the bytes to write back (nil/empty while a
// request is still incomplete). Set it BEFORE beginShellWithTerminalType;
// passing nil disables forwarding for subsequent shells.
- (void)installAgentForwardHandler:(nullable NSData * _Nullable (^)(NSData * _Nonnull incoming))handler;

#pragma mark shell environment

// Environment variables to request on the next interactive shell (e.g.
// COLORTERM=truecolor). Each pair is sent as an SSH `env` channel request
// right before the pty/shell request. Set it BEFORE beginShellWithTerminalType;
// passing nil/empty clears it for subsequent shells. A rejected request is
// non-fatal — the shell still opens — and sshd only honors variables listed in
// its `AcceptEnv` allowlist, so delivery is best-effort.
- (void)installShellEnvironment:(nullable NSDictionary<NSString*, NSString*>*)environment;

#pragma mark port map

- (void)createPortForwardWithLocalPort:(NSNumber*)localPort
                 withForwardTargetHost:(NSString*)targetHost
                 withForwardTargetPort:(NSNumber*)targetPort
                          withOnCreate:(dispatch_block_t)withOnCreate
               withContinuationHandler:(BOOL (^)(void))continuationBlock;

- (void)createPortForwardWithRemotePort:(NSNumber*)remotePort
                  withForwardTargetHost:(NSString*)targetHost
                  withForwardTargetPort:(NSNumber*)targetPort
                           withOnCreate:(dispatch_block_t)withOnCreate
                withContinuationHandler:(BOOL (^)(void))continuationBlock;

#pragma mark sftp

typedef void (^NSRemoteFileTransferProgressBlock)(NSString *filename, NSProgress *uploadProgress, long bytesPerSecond);
typedef void (^NSRemoteFileDeleteProgressBlock)(NSString *currentFile);

- (void)requestConnectFileTransferAndWait;
- (void)requestDisconnectFileTransferAndWait;
- (nullable NSArray<NSRemoteFile*>*)requestFileListAt:(NSString*)atDirPath;
- (nullable NSRemoteFile*)requestFileInfoAt:(NSString*)atPath;
- (nullable NSString*)requestRealpathAt:(NSString*)atPath;
- (BOOL)requestRenameFileAndWait:(NSString*)atPath
                     withNewPath:(NSString*)newPath;
- (BOOL)requestUploadForFileAndWait:(NSString*)atPath
                        toDirectory:(NSString*)toDirectory
                         onProgress:(NSRemoteFileTransferProgressBlock _Nonnull)onProgress
            withContinuationHandler:(BOOL (^)(void))continuationBlock;
- (BOOL)requestDeleteForFileAndWait:(NSString*)atPath
                  withProgressBlock:(NSRemoteFileDeleteProgressBlock _Nonnull)onProgress
            withContinuationHandler:(BOOL (^)(void))continuationBlock;
//- (void)requestDeleteUsingRMCommandForFileAndWait:(NSString*)atPath; // how to escape parameters safely?
- (BOOL)requestCreateDirAndWait:(NSString*)atPath;
- (BOOL)requestDownloadFromFileAndWait:(NSString*)atPath
                           toLocalPath:(NSString*)toPath
                            onProgress:(NSRemoteFileTransferProgressBlock _Nonnull)onProgress               withContinuationHandler:(BOOL (^)(void))continuationBlock;

#pragma mark destory

/// This function is used to force shutdown everything, including the run loop and it's associated thread
/// when ARC is not working, call this function
- (void)destroyPermanently;

@end

NS_ASSUME_NONNULL_END
