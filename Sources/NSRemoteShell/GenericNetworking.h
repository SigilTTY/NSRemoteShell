//
//  GenericNetworking.h
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import <Foundation/Foundation.h>

#import "GenericHeaders.h"
#import "NSRemoteShell.h"

NS_ASSUME_NONNULL_BEGIN

@interface GenericNetworking : NSObject

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost;

+ (BOOL)isValidateWithPort:(NSNumber*)port;

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort;
+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort actualPort:(int*)actualPort;

+ (int)createSocketWithTargetHost:(NSString*)targetHost
                   withTargetPort:(NSNumber*)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
;

/// Resolves and dials `targetHost`, trying each address in turn within
/// `timeout` seconds overall (<= 0: no limit, each connect waits out the
/// system SYN timeout). Reports every step to `events` and, on failure,
/// a one-line English reason through `failure`. Returns the socket, or 0.
+ (int)connectSocketToHost:(NSString*)targetHost
                      port:(NSNumber*)targetPort
                   timeout:(double)timeout
      requireNonblockingIO:(BOOL)useNonblocking
                    events:(nullable NSRemoteShellConnectEventHandler)events
                   failure:(NSString * _Nullable * _Nullable)failure;

+ (void)destroyNativeSocket:(int)socketDescriptor;

+ (NSString*)getResolvedIpAddressWith:(int)socket;

@end

NS_ASSUME_NONNULL_END
