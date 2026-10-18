//
//  GenericNetworking.m
//
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "GenericNetworking.h"
#import <errno.h>
#import <string.h>
#import <poll.h>
#import <fcntl.h>

@implementation GenericNetworking

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost
{
    if (!candidateHost) return [[NSArray alloc] init];
    NSArray<NSData*> *candidateHostData = [[NSArray alloc] init];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = PF_UNSPEC;        // PF_INET if you want only IPv4 addresses
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addrs, *addr;
    getaddrinfo([candidateHost UTF8String], NULL, &hints, &addrs);
    for (addr = addrs; addr; addr = addr->ai_next) {
        char host[NI_MAXHOST];
        getnameinfo(addr->ai_addr, addr->ai_addrlen, host, sizeof(host), NULL, 0, NI_NUMERICHOST);
        if (strlen(host) <= 0) { continue; }
        NSString *hostStr = [[NSString alloc] initWithUTF8String:host];
        NSLog(@"resolving host %@ loading result: %@", candidateHost, hostStr);
        NSData *build = [[NSData alloc] initWithBytes:addr->ai_addr length: addr->ai_addrlen];
        candidateHostData = [candidateHostData arrayByAddingObject:build];
    }
    freeaddrinfo(addrs);
    return candidateHostData;
}

+ (BOOL)isValidateWithPort:(NSNumber*)port {
    int p = [port intValue];
    // we are treating 0 as a valid port and technically it should work!
    if (p >= 0 && p <= 65535) {
        return YES;
    }
    return NO;
}

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort
{
    return [self createSocketNonblockingListenerWithLocalPort:localPort actualPort:NULL];
}

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort actualPort:(int*)actualPort
{
    if (![GenericNetworking isValidateWithPort:localPort]) {
        NSLog(@"invalid port %@", [localPort stringValue]);
        return 0;
    }
    
    int port = [localPort intValue];
    struct sockaddr_in server4;
    int socket_desc4 = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_desc4 <= 0) {
        NSLog(@"failed to create socket for ipv4 at port %d", port);
        return 0;
    }
    server4.sin_family = AF_INET;
    server4.sin_addr.s_addr = inet_addr("127.0.0.1"); // for security?
    server4.sin_port = htons(port);
    if (setsockopt(socket_desc4, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int)) == -1) {
        NSLog(@"failed to setsockopt for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (bind(socket_desc4, (struct sockaddr*)&server4, sizeof(server4)) < 0) {
        NSLog(@"failed to bind socket for ipv4 at port %d, errno: %d, error: %s", port, errno, strerror(errno));
        close(socket_desc4);
        return 0;
    } else {
        // If port was 0, get the actual assigned port
        if (port == 0) {
            struct sockaddr_in actualAddr;
            socklen_t addrLen = sizeof(actualAddr);
            if (getsockname(socket_desc4, (struct sockaddr*)&actualAddr, &addrLen) == 0) {
                int assignedPort = ntohs(actualAddr.sin_port);
                NSLog(@"bound listener v4 for OS-assigned port %d", assignedPort);
                if (actualPort) {
                    *actualPort = assignedPort;
                }
            } else {
                NSLog(@"bound listener v4 for port %d (failed to get actual port)", port);
            }
        } else {
            NSLog(@"bound listener v4 for port %d", port);
            if (actualPort) {
                *actualPort = port;
            }
        }
    }
    if (fcntl(socket_desc4, F_SETFL, fcntl(socket_desc4, F_GETFL, 0) | O_NONBLOCK) == -1) {
        NSLog(@"failed to call fcntl for none-blocking ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (listen(socket_desc4, SOCKET_QUEUE_MAXSIZE) == -1) {
        NSLog(@"failed to call listen for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    
    NSLog(@"socket listener for port %d booted", port);
    return socket_desc4;
}

+ (int)createSocketWithTargetHost:(NSString *)targetHost
                   withTargetPort:(NSNumber *)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
{
    return [self connectSocketToHost:targetHost
                                port:targetPort
                             timeout:0
                requireNonblockingIO:useNonblocking
                              events:nil
                             failure:NULL];
}

static NSString *GNNumericAddress(const struct sockaddr *addr, socklen_t len) {
    char host[NI_MAXHOST];
    if (getnameinfo(addr, len, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) { return nil; }
    if (strlen(host) == 0) { return nil; }
    return [[NSString alloc] initWithUTF8String:host];
}

/// Non-blocking connect bounded by `seconds` (<= 0: unbounded). Returns 0
/// on success, else the errno (ETIMEDOUT when the bound ran out).
static int GNConnectWithin(int sock, const struct sockaddr *addr, socklen_t len, double seconds) {
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags == -1 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) == -1) { return errno; }
    int result = 0;
    if (connect(sock, addr, len) != 0) {
        if (errno != EINPROGRESS) {
            result = errno;
        } else {
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
            while (true) {
                int waitMs = -1;
                if (seconds > 0) {
                    double left = deadline - CFAbsoluteTimeGetCurrent();
                    if (left <= 0) { result = ETIMEDOUT; break; }
                    waitMs = (int)ceil(left * 1000);
                }
                struct pollfd pfd = { .fd = sock, .events = POLLOUT, .revents = 0 };
                int rv = poll(&pfd, 1, waitMs);
                if (rv < 0) {
                    if (errno == EINTR) { continue; }
                    result = errno;
                    break;
                }
                if (rv == 0) { result = ETIMEDOUT; break; }
                int soError = 0;
                socklen_t soLen = sizeof(soError);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen) != 0) {
                    result = errno;
                } else {
                    result = soError;
                }
                break;
            }
        }
    }
    // Callers that did not ask for non-blocking IO get the socket back in
    // blocking mode, exactly as the old blocking connect left it.
    if (result == 0 && fcntl(sock, F_SETFL, flags) == -1) { result = errno; }
    return result;
}

+ (int)connectSocketToHost:(NSString *)targetHost
                      port:(NSNumber *)targetPort
                   timeout:(double)timeout
      requireNonblockingIO:(BOOL)useNonblocking
                    events:(NSRemoteShellConnectEventHandler)events
                   failure:(NSString * _Nullable __autoreleasing *)failure
{
    NSString *host = targetHost ?: @"";
    NSInteger port = [targetPort integerValue];
    void (^report)(NSRemoteShellConnectStep, NSString *, NSArray *, int, NSString *, double) =
        ^(NSRemoteShellConnectStep step, NSString *address, NSArray *addresses, int code, NSString *detail, double seconds) {
            if (!events) { return; }
            events([[NSRemoteShellConnectEvent alloc] initWithStep:step
                                                              host:host
                                                              port:port
                                                           address:address
                                                         addresses:addresses
                                                         errorCode:code
                                                            detail:detail
                                                           timeout:seconds]);
        };
    if (![self isValidateWithPort:targetPort]) {
        if (failure) { *failure = [NSString stringWithFormat:@"Invalid port %@", targetPort]; }
        return 0;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = PF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    // An IP literal needs no lookup step on screen.
    struct addrinfo numericHints = hints;
    numericHints.ai_flags = AI_NUMERICHOST;
    struct addrinfo *addrs = NULL;
    BOOL isLiteral = getaddrinfo([host UTF8String], NULL, &numericHints, &addrs) == 0;
    if (!isLiteral) {
        report(NSRemoteShellConnectStepResolving, nil, nil, 0, nil, 0);
        int rc = getaddrinfo([host UTF8String], NULL, &hints, &addrs);
        if (rc != 0 || !addrs) {
            NSString *reason = [[NSString alloc] initWithUTF8String:gai_strerror(rc != 0 ? rc : EAI_NONAME)];
            NSLog(@"resolving host %@ failed: %@", host, reason);
            report(NSRemoteShellConnectStepResolveFailed, nil, nil, rc, reason, 0);
            if (failure) { *failure = [NSString stringWithFormat:@"Could not resolve host %@: %@", host, reason]; }
            if (addrs) { freeaddrinfo(addrs); }
            return 0;
        }
    }

    NSMutableArray<NSData *> *candidates = [[NSMutableArray alloc] init];
    NSMutableArray<NSString *> *names = [[NSMutableArray alloc] init];
    for (struct addrinfo *addr = addrs; addr; addr = addr->ai_next) {
        if (addr->ai_family != AF_INET && addr->ai_family != AF_INET6) { continue; }
        NSString *name = GNNumericAddress(addr->ai_addr, addr->ai_addrlen);
        if (!name || [names containsObject:name]) { continue; }
        [names addObject:name];
        [candidates addObject:[[NSData alloc] initWithBytes:addr->ai_addr length:addr->ai_addrlen]];
    }
    freeaddrinfo(addrs);
    if (!isLiteral) {
        NSLog(@"resolved host %@ to %@", host, [names componentsJoinedByString:@", "]);
        report(NSRemoteShellConnectStepResolved, nil, names, 0, nil, 0);
    }
    if (candidates.count == 0) {
        if (failure) { *failure = [NSString stringWithFormat:@"Host %@ has no usable address", host]; }
        return 0;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    NSMutableArray<NSString *> *reasons = [[NSMutableArray alloc] init];
    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSString *name = names[i];
        // Even share of what is left, so a dead first address (often an
        // IPv6 one with no IPv6 route) cannot eat the whole budget.
        double share = 0;
        if (timeout > 0) {
            double left = deadline - CFAbsoluteTimeGetCurrent();
            if (left <= 0) {
                [reasons addObject:[NSString stringWithFormat:@"%@: not tried, time ran out", name]];
                continue;
            }
            share = left / (double)(candidates.count - i);
        }
        NSData *candidate = candidates[i];
        struct sockaddr_storage storage;
        memset(&storage, 0, sizeof(storage));
        [candidate getBytes:&storage length:MIN(candidate.length, sizeof(storage))];
        socklen_t len = (socklen_t)candidate.length;
        if (storage.ss_family == AF_INET) {
            ((struct sockaddr_in *)&storage)->sin_port = htons((uint16_t)port);
        } else {
            ((struct sockaddr_in6 *)&storage)->sin6_port = htons((uint16_t)port);
        }

        report(NSRemoteShellConnectStepDialing, name, nil, 0, nil, share);
        int sock = socket(storage.ss_family, SOCK_STREAM, IPPROTO_TCP);
        if (sock <= 0) {
            int code = errno;
            NSString *detail = [[NSString alloc] initWithUTF8String:strerror(code)];
            report(NSRemoteShellConnectStepDialFailed, name, nil, code, detail, share);
            [reasons addObject:[NSString stringWithFormat:@"%@: %@", name, detail]];
            continue;
        }
        int code = GNConnectWithin(sock, (struct sockaddr *)&storage, len, share);
        if (code == 0 && useNonblocking
            && fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK) == -1) {
            code = errno;
        }
        if (code != 0) {
            close(sock);
            NSString *detail = code == ETIMEDOUT && share > 0
                ? [NSString stringWithFormat:@"no answer within %.0f s", share]
                : [[NSString alloc] initWithUTF8String:strerror(code)];
            NSLog(@"connecting to %@ port %ld failed: %@", name, (long)port, detail);
            report(NSRemoteShellConnectStepDialFailed, name, nil, code, detail, share);
            [reasons addObject:[NSString stringWithFormat:@"%@: %@", name, detail]];
            continue;
        }
        NSLog(@"created socket %d to address %@", sock, name);
        report(NSRemoteShellConnectStepConnected, name, nil, 0, nil, share);
        return sock;
    }
    if (failure) {
        *failure = [NSString stringWithFormat:@"Could not connect to %@ port %ld (%@)",
                    host, (long)port, [reasons componentsJoinedByString:@"; "]];
    }
    return 0;
}

+ (void)destroyNativeSocket:(int)socketDescriptor {
    if (socketDescriptor > 0) {
        NSLog(@"closing socket fd %d", socketDescriptor);
        close(socketDescriptor);
    }
}

+ (NSString*)getResolvedIpAddressWith:(int)socket {
    if (!socket) { return @""; }
    struct sockaddr_in sin;
    socklen_t len = sizeof(sin);
    getpeername(socket, (struct sockaddr*)&sin, &len);
    char buf[255];
    memset(buf, 0, sizeof(buf));
    switch(sin.sin_family) {
        case AF_INET: {
            struct sockaddr_in *addr_in = (struct sockaddr_in *)&sin;
            inet_ntop(AF_INET, &(addr_in->sin_addr), buf, INET_ADDRSTRLEN);
            break;
        }
        case AF_INET6: {
            struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)&sin;
            inet_ntop(AF_INET6, &(addr_in6->sin6_addr), buf, INET6_ADDRSTRLEN);
            break;
        }
        default:
            break;
    }
    return [[NSString alloc] initWithUTF8String:buf];
}

@end
