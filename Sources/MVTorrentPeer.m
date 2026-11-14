#import "MVTorrentPeer.h"
#include <string.h>
#import "MVBencode.h"
#import "MVLang.h"
#import "MVLog.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

/// A peer that sends nothing for this long is dropped.
static const NSTimeInterval kIdleTimeout = 90;
/// The wire protocol version this client announces.
static const char kProtocol[] = "BitTorrent protocol";

@implementation MVTorrentBlock

+ (instancetype)blockWithIndex:(NSInteger)index begin:(NSInteger)begin length:(NSInteger)length {
    MVTorrentBlock *block = [MVTorrentBlock new];
    block.index = index;
    block.begin = begin;
    block.length = length;
    return block;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:MVTorrentBlock.class]) return NO;
    MVTorrentBlock *other = object;
    return other.index == _index && other.begin == _begin && other.length == _length;
}

- (NSUInteger)hash {
    return (NSUInteger)(_index * 31 + _begin);
}

@end

@interface MVTorrentPeer ()
/// Everything the socket thread reads and writes. The lock keeps the engine's
/// queue and the socket thread from touching it at once.
@property (nonatomic, strong) NSMutableData *sendQueue;
@property (nonatomic, strong) NSMutableIndexSet *pieces;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL stopping;
@property (nonatomic) BOOL handshakeSent;
@property (nonatomic) BOOL handshakeReceived;
@property (nonatomic) BOOL interestedSent;
@property (nonatomic) NSTimeInterval lastActivity;
/// Blocks we asked for and have not received, by "index:begin".
@property (nonatomic, strong) NSMutableDictionary<NSString *, MVTorrentBlock *> *outstanding;
/// When each outstanding block was requested, so a lost block is retried even
/// while the peer keeps sending other data.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *outstandingSince;
@end

@implementation MVTorrentPeer {
    int _socket;
    dispatch_queue_t _queue;
    NSData *_infoHash;
    NSData *_peerID;
    NSInteger _pieceCount;
    __weak id<MVTorrentPeerDelegate> _delegate;
    NSMutableData *_receiveBuffer;
    dispatch_queue_t _engineQueue;
    NSDictionary *_extendedHandshake;
    BOOL _extendedHandshakeReceived;
    BOOL _unchoked; // protected by @synchronized(self)
}

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    infoHash:(NSData *)infoHash
                     peerID:(NSData *)peerID
                  pieceCount:(NSInteger)pieceCount
                    delegate:(id<MVTorrentPeerDelegate>)delegate {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _infoHash = infoHash;
        _peerID = peerID;
        _pieceCount = pieceCount;
        _delegate = delegate;
        _socket = -1;
        _pieces = [NSMutableIndexSet indexSet];
        _sendQueue = [NSMutableData data];
        _outstanding = [NSMutableDictionary dictionary];
        _outstandingSince = [NSMutableDictionary dictionary];
        _receiveBuffer = [NSMutableData data];
        _maxInFlight = 16;
        _queue = dispatch_queue_create("com.mody.moodyvid.torrent.peer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSIndexSet *)availablePieces {
    @synchronized (self) { return [_pieces copy]; }
}

- (NSInteger)blocksInFlight {
    @synchronized (self) { return (NSInteger)_outstanding.count; }
}

- (NSDictionary *)extendedHandshake {
    @synchronized (self) { return _extendedHandshake; }
}

- (BOOL)extendedHandshakeReceived {
    @synchronized (self) { return _extendedHandshakeReceived; }
}

- (BOOL)connected {
    @synchronized (self) { return _handshakeReceived && _socket >= 0 && !_stopping; }
}

- (BOOL)unchoked {
    @synchronized (self) { return _unchoked; }
}

- (void)setCallbackQueue:(dispatch_queue_t)queue {
    _engineQueue = queue;
}

#pragma mark - Socket thread

- (void)start {
    @synchronized (self) {
        if (_started) return;
        _started = YES;
    }
    dispatch_async(_queue, ^{ [self run]; });
}

- (void)run {
    @autoreleasepool {
        if (![self openSocket]) {
            [self reportDisconnect:_failureReason];
            return;
        }
        [self sendHandshake];
        [self readLoop];
        [self closeSocket];
    }
}

- (BOOL)openSocket {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *result = NULL;
    NSString *portString = [NSString stringWithFormat:@"%ld", (long)_port];
    if (getaddrinfo(_host.UTF8String, portString.UTF8String, &hints, &result) != 0 || !result) {
        self.failureReason = @"could not resolve the peer address";
        return NO;
    }

    int fd = -1;
    for (struct addrinfo *candidate = result; candidate; candidate = candidate->ai_next) {
        @synchronized (self) { if (_stopping) break; }
        fd = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
        if (fd < 0) continue;
        if (self.boundInterfaceIndex) {
            unsigned int index = self.boundInterfaceIndex;
            int level = candidate->ai_family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP;
            int option = candidate->ai_family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF;
            if ((candidate->ai_family != AF_INET && candidate->ai_family != AF_INET6) ||
                setsockopt(fd, level, option, &index, sizeof(index)) != 0) {
                close(fd);
                fd = -1;
                continue; // fail closed, never fall back to another interface
            }
        }
        // Short socket timeouts so a dead peer is noticed quickly: the read loop
        // wakes on these and the engine's idle/block timeouts drop the peer.
        struct timeval sendTimeout = {.tv_sec = 15, .tv_usec = 0};
        // Engine requests are queued from another thread; wake regularly to
        // flush them instead of waiting 15 seconds for the next incoming byte.
        struct timeval receiveTimeout = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        // A remote close during send must be an error, not SIGPIPE to the app.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        if (connect(fd, candidate->ai_addr, candidate->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(result);
    if (fd < 0) {
        self.failureReason = @"connection refused";
        return NO;
    }
    @synchronized (self) {
        // stop may have arrived while DNS/connect was blocking, before there
        // was a socket for it to shut down. Do not revive a cancelled peer.
        if (_stopping) { close(fd); return NO; }
        _socket = fd;
    }
    self.lastActivity = NSProcessInfo.processInfo.systemUptime;
    return YES;
}

- (void)closeSocket {
    @synchronized (self) {
        if (_socket >= 0) { close(_socket); _socket = -1; }
    }
}

- (void)sendHandshake {
    NSMutableData *packet = [NSMutableData data];
    uint8_t length = (uint8_t)strlen(kProtocol);
    [packet appendBytes:&length length:1];
    [packet appendBytes:kProtocol length:length];
    // Reserved bytes: the sixth advertises the extended protocol (BEP 10). The
    // DHT bit (BEP 5) is deliberately left clear — this client does not speak
    // DHT, and advertising it would invite messages we cannot answer.
    uint8_t reserved[8] = {0, 0, 0, 0, 0, 0x10, 0, 0};
    [packet appendBytes:reserved length:8];
    [packet appendData:_infoHash];
    [packet appendData:_peerID];
    [self rawSend:packet];
    @synchronized (self) { _handshakeSent = YES; }
}

/// The blocking read loop. Runs on its own queue; the socket timeouts keep it
/// from parking forever on a silent peer.
- (void)readLoop {
    uint8_t buffer[65536];
    while (YES) {
        @synchronized (self) { if (_stopping) break; }
        [self flushSendQueue];
        // Only this socket thread closes the descriptor. -stop uses shutdown
        // to wake recv, preventing a concurrent close/reuse of the fd.
        int fd;
        @synchronized (self) { fd = _socket; }
        if (fd < 0) break;
        ssize_t got = recv(fd, buffer, sizeof(buffer), 0);
        if (got > 0) {
            [_receiveBuffer appendBytes:buffer length:(NSUInteger)got];
            self.lastActivity = NSProcessInfo.processInfo.systemUptime;
            [self processBuffer];
            [self checkOutstandingTimeouts]; // active peers can still lose individual blocks
            continue;
        }
        if (got == 0) {
            self.failureReason = @"peer closed the connection";
            break;
        }
        // EAGAIN / EWOULDBLOCK from the receive timeout: keep waiting until the
        // peer has been quiet for too long. Use monotonic uptime so a wall-clock
        // adjustment does not disconnect an active peer or hide an idle one.
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (NSProcessInfo.processInfo.systemUptime - self.lastActivity > kIdleTimeout) {
                self.failureReason = @"peer timed out";
                break;
            }
            [self checkOutstandingTimeouts];
            continue;
        }
        self.failureReason = @"the connection was lost";
        break;
    }
    [self reportDisconnect:self.failureReason];
}

/// A block that has not arrived after this long is considered lost.
static const NSTimeInterval kBlockTimeout = 30;

- (void)checkOutstandingTimeouts {
    NSArray<MVTorrentBlock *> *lost = nil;
    @synchronized (self) {
        NSMutableArray *expired = [NSMutableArray array];
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        for (NSString *key in _outstanding.allKeys) {
            NSNumber *requested = _outstandingSince[key];
            // Use a monotonic clock; wall-clock corrections must not hide a
            // lost request or expire it immediately.
            if (!requested || now - requested.doubleValue > kBlockTimeout) {
                [expired addObject:_outstanding[key]];
            }
        }
        if (expired.count) {
            for (MVTorrentBlock *block in expired) {
                NSString *key = [self keyForBlock:block];
                [_outstanding removeObjectForKey:key];
                [_outstandingSince removeObjectForKey:key];
            }
            lost = expired;
        }
    }
    for (MVTorrentBlock *block in lost) {
        [self onEngineQueue:^{
            id<MVTorrentPeerDelegate> delegate = _delegate;
            if ([delegate respondsToSelector:@selector(peer:didLoseBlock:)]) {
                [delegate peer:self didLoseBlock:block];
            }
        }];
    }
}

#pragma mark - Sending

- (void)flushSendQueue {
    NSData *pending = nil;
    int fd = -1;
    @synchronized (self) {
        if (!_sendQueue.length || _socket < 0) return;
        fd = _socket;
        pending = [_sendQueue copy];
        [_sendQueue setLength:0];
    }
    const uint8_t *bytes = pending.bytes;
    size_t total = pending.length;
    size_t sent = 0;
    while (sent < total) {
        ssize_t n = send(fd, bytes + sent, total - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // Preserve wire ordering: a partially sent frame must precede any
            // new frames enqueued while send() was blocked.
            @synchronized (self) {
                [_sendQueue replaceBytesInRange:NSMakeRange(0, 0) withBytes:bytes + sent length:total - sent];
            }
            return;
        }
        if (n <= 0) {
            self.failureReason = @"the connection was lost";
            @synchronized (self) { _stopping = YES; }
            return;
        }
        sent += (size_t)n;
    }
}

- (void)rawSend:(NSData *)data {
    @synchronized (self) {
        if (_socket < 0) return;
        [_sendQueue appendData:data];
    }
}

/// A wire message: a 4-byte big-endian length, then the id and payload.
- (void)sendMessage:(uint8_t)messageID payload:(nullable NSData *)payload {
    NSMutableData *packet = [NSMutableData data];
    uint32_t length = (uint32_t)(1 + (payload ? payload.length : 0));
    uint32_t bigLength = htonl(length);
    [packet appendBytes:&bigLength length:4];
    [packet appendBytes:&messageID length:1];
    if (payload.length) [packet appendData:payload];
    [self rawSend:packet];
}

- (void)sendMessage:(uint8_t)messageID integer:(NSInteger)value {
    uint32_t big = htonl((uint32_t)value);
    [self sendMessage:messageID payload:[NSData dataWithBytes:&big length:4]];
}

- (void)sendHave:(NSInteger)index {
    [self sendMessage:4 integer:index];
}

- (void)sendNotInterested {
    [self sendMessage:3 payload:nil];
}

- (void)sendRequest:(MVTorrentBlock *)block {
    NSMutableData *payload = [NSMutableData data];
    uint32_t index = htonl((uint32_t)block.index);
    uint32_t begin = htonl((uint32_t)block.begin);
    uint32_t length = htonl((uint32_t)block.length);
    [payload appendBytes:&index length:4];
    [payload appendBytes:&begin length:4];
    [payload appendBytes:&length length:4];
    [self sendMessage:6 payload:payload];
}

- (void)sendMetadataRequestForPiece:(NSInteger)piece {
    // The request goes out under the id the peer chose for ut_metadata in its
    // own handshake, not a fixed number.
    NSDictionary *handshake = self.extendedHandshake;
    NSDictionary *m = [handshake[@"m"] isKindOfClass:NSDictionary.class] ? handshake[@"m"] : nil;
    NSNumber *metadataID = m[@"ut_metadata"];
    if (![metadataID isKindOfClass:NSNumber.class] || metadataID.longLongValue < 1 || metadataID.longLongValue > 255) return;
    NSData *payload = [MVBencode encode:@{@"msg_type": @0, @"piece": @(piece)}];
    [self sendExtendedMessage:metadataID.integerValue payload:payload];
}

- (void)sendExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload {
    NSMutableData *body = [NSMutableData data];
    uint8_t identifier = (uint8_t)extendedID;
    [body appendBytes:&identifier length:1];
    if (payload.length) [body appendData:payload];
    [self sendMessage:20 payload:body];
}

#pragma mark - Receiving

- (void)processBuffer {
    while (YES) {
        if (_receiveBuffer.length < 4) return;
        // The first bytes on the wire are the peer's handshake: 68 bytes with a
        // 19-byte protocol string, not a length-prefixed message.
        if (!_handshakeReceived) {
            if ([self tryReadHandshake]) continue;
            return;
        }
        const uint8_t *bytes = _receiveBuffer.bytes;
        uint32_t bigLength = 0;
        memcpy(&bigLength, bytes, 4);
        uint32_t length = ntohl(bigLength);

        if (length == 0) {
            // A keep-alive.
            [_receiveBuffer replaceBytesInRange:NSMakeRange(0, 4) withBytes:NULL length:0];
            continue;
        }
        if (length > 2 * 1024 * 1024) {
            self.failureReason = @"peer sent an oversized message";
            @synchronized (self) { _stopping = YES; }
            return;
        }
        if (_receiveBuffer.length < 4 + length) return;
        NSData *message = [_receiveBuffer subdataWithRange:NSMakeRange(4, length)];
        [_receiveBuffer replaceBytesInRange:NSMakeRange(0, 4 + length) withBytes:NULL length:0];
        [self handleMessage:message];
        @synchronized (self) { if (_stopping) return; }
    }
}

/// Consumes the peer's handshake when it has arrived. Returns YES when the
/// buffer should be re-examined (a handshake was consumed or is still partial).
- (BOOL)tryReadHandshake {
    static const NSUInteger kHandshakeLength = 68;
    if (_receiveBuffer.length < 1) return NO;
    const uint8_t *bytes = _receiveBuffer.bytes;
    NSUInteger protocolLength = bytes[0];
    if (protocolLength != strlen(kProtocol)) {
        self.failureReason = @"peer is not speaking BitTorrent";
        @synchronized (self) { _stopping = YES; }
        return NO;
    }
    // TCP may split the protocol string at any byte. Never memcmp past the
    // received buffer while waiting for the rest of the handshake.
    if (_receiveBuffer.length < 1 + protocolLength) return NO;
    if (memcmp(bytes + 1, kProtocol, protocolLength) != 0) {
        self.failureReason = @"peer is not speaking BitTorrent";
        @synchronized (self) { _stopping = YES; }
        return NO;
    }
    if (_receiveBuffer.length < kHandshakeLength) return NO;

    NSData *remoteInfoHash = [_receiveBuffer subdataWithRange:NSMakeRange(28, 20)];
    if (![remoteInfoHash isEqualToData:_infoHash]) {
        self.failureReason = @"peer is serving a different torrent";
        @synchronized (self) { _stopping = YES; }
        return NO;
    }
    [_receiveBuffer replaceBytesInRange:NSMakeRange(0, kHandshakeLength) withBytes:NULL length:0];
    @synchronized (self) { _handshakeReceived = YES; }

    // Now that the peer is there, say we want its pieces. We advertise the
    // extended protocol in the reserved bytes, so we must send our extended
    // handshake too — waiting for the peer's first would never happen, because
    // it is waiting for ours.
    [self sendMessage:2 payload:nil];   // interested
    NSDictionary *handshake = @{@"m": @{@"ut_metadata": @1}};
    [self sendExtendedMessage:0 payload:[MVBencode encode:handshake]];
    [self onEngineQueue:^{
        [_delegate peerDidConnect:self];
    }];
    return YES;
}

- (void)handleMessage:(NSData *)message {
    if (!message.length) return;
    const uint8_t *bytes = message.bytes;
    uint8_t messageID = bytes[0];
    NSData *payload = message.length > 1 ? [message subdataWithRange:NSMakeRange(1, message.length - 1)] : [NSData data];

    switch (messageID) {
        case 0:   // choke
            [self setUnchoked:NO];
            break;
        case 1:   // unchoke
            [self setUnchoked:YES];
            break;
        case 4:   // have
            [self handleHave:payload];
            break;
        case 5:   // bitfield
            [self handleBitfield:payload];
            break;
        case 7:   // piece
            [self handlePiece:payload];
            break;
        case 20:  // extended (BEP 10)
            [self handleExtended:payload];
            break;
        default:
            break;
    }
}

- (void)setUnchoked:(BOOL)unchoked {
    BOOL changed;
    NSArray<MVTorrentBlock *> *lost = nil;
    @synchronized (self) {
        changed = (_unchoked != unchoked);
        _unchoked = unchoked;
        if (changed && !unchoked) {
            lost = _outstanding.allValues;
            [_outstanding removeAllObjects];
            [_outstandingSince removeAllObjects];
        }
    }
    if (changed) {
        // Report each lost request even if an unchoke arrives before this block
        // reaches the engine queue. A late piece must not own someone else's work.
        [self onEngineQueue:^{
            id<MVTorrentPeerDelegate> delegate = _delegate;
            for (MVTorrentBlock *block in lost) [delegate peer:self didLoseBlock:block];
            [delegate peerDidChangeAvailability:self];
        }];
    }
}

- (void)handleHave:(NSData *)payload {
    if (payload.length < 4) return;
    uint32_t big = 0;
    memcpy(&big, payload.bytes, 4);
    NSInteger index = (NSInteger)ntohl(big);
    if (index < 0 || index >= _pieceCount) return;
    @synchronized (self) { [_pieces addIndex:(NSUInteger)index]; }
    [self onEngineQueue:^{
        [_delegate peerDidChangeAvailability:self];
    }];
}

- (void)handleBitfield:(NSData *)payload {
    @synchronized (self) {
        const uint8_t *bits = payload.bytes;
        for (NSInteger i = 0; i < _pieceCount; i++) {
            NSUInteger byteIndex = (NSUInteger)(i / 8);
            if (byteIndex >= payload.length) break;
            uint8_t mask = (uint8_t)(0x80 >> (i % 8));
            if (bits[byteIndex] & mask) [_pieces addIndex:(NSUInteger)i];
        }
    }
    [self onEngineQueue:^{
        [_delegate peerDidChangeAvailability:self];
    }];
}

- (void)handlePiece:(NSData *)payload {
    if (payload.length < 8) return;
    const uint8_t *bytes = payload.bytes;
    uint32_t bigIndex = 0, bigBegin = 0;
    memcpy(&bigIndex, bytes, 4);
    memcpy(&bigBegin, bytes + 4, 4);
    NSInteger index = (NSInteger)ntohl(bigIndex);
    NSInteger begin = (NSInteger)ntohl(bigBegin);
    NSData *data = payload.length > 8 ? [payload subdataWithRange:NSMakeRange(8, payload.length - 8)] : [NSData data];

    NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)index, (long)begin];
    MVTorrentBlock *block;
    @synchronized (self) {
        block = _outstanding[key];
        if (!block) return; // unsolicited, timed out or already returned on choke
        [_outstanding removeObjectForKey:key];
        [_outstandingSince removeObjectForKey:key];
    }
    if (data.length != (NSUInteger)block.length) {
        [self onEngineQueue:^{ [_delegate peer:self didLoseBlock:block]; }];
        return;
    }
    [self onEngineQueue:^{
        [_delegate peer:self didReceiveBlock:block data:data];
    }];
}

- (void)handleExtended:(NSData *)payload {
    if (!payload.length) return;
    const uint8_t *bytes = payload.bytes;
    NSInteger extendedID = bytes[0];
    NSData *body = payload.length > 1 ? [payload subdataWithRange:NSMakeRange(1, payload.length - 1)] : [NSData data];
    if (extendedID == 0) {
        // The peer's extended handshake (BEP 10). Its `m` map names the extended
        // messages it speaks; `ut_metadata` is the id it wants BEP 9 requests
        // sent under, which is per-peer and so must be read from here.
        NSString *error = nil;
        id decoded = [MVBencode decode:body error:&error];
        if ([decoded isKindOfClass:NSDictionary.class]) {
            @synchronized (self) {
                _extendedHandshake = decoded;
                _extendedHandshakeReceived = YES;
            }
        }
        [self onEngineQueue:^{
            id<MVTorrentPeerDelegate> delegate = _delegate;
            if ([delegate respondsToSelector:@selector(peer:didReceiveExtendedMessage:payload:)]) {
                [delegate peer:self didReceiveExtendedMessage:0 payload:body];
            }
        }];
        return;
    }
    [self onEngineQueue:^{
        id<MVTorrentPeerDelegate> delegate = _delegate;
        if ([delegate respondsToSelector:@selector(peer:didReceiveExtendedMessage:payload:)]) {
            [delegate peer:self didReceiveExtendedMessage:extendedID payload:body];
        }
    }];
}

#pragma mark - Engine-facing

- (void)requestBlock:(MVTorrentBlock *)block {
    NSString *key = [self keyForBlock:block];
    @synchronized (self) {
        if (_stopping || !_unchoked) {
            [self onEngineQueue:^{ [_delegate peer:self didLoseBlock:block]; }];
            return;
        }
        _outstanding[key] = block;
        _outstandingSince[key] = @(NSProcessInfo.processInfo.systemUptime);
    }
    [self sendRequest:block];
}

- (void)stop {
    @synchronized (self) {
        if (_stopping) return;
        _stopping = YES;
        // Wake recv/send, but leave close to the socket thread. Closing here
        // could let the descriptor be reused before that thread calls recv.
        if (_socket >= 0) shutdown(_socket, SHUT_RDWR);
    }
}

- (NSString *)keyForBlock:(MVTorrentBlock *)block {
    return [NSString stringWithFormat:@"%ld:%ld", (long)block.index, (long)block.begin];
}

/// Hops back onto the engine's queue. The engine hands its queue in when it
/// creates the peer; until then, the main queue is a safe stand-in.
- (void)onEngineQueue:(dispatch_block_t)block {
    dispatch_queue_t queue = _engineQueue ?: dispatch_get_main_queue();
    dispatch_async(queue, block);
}

- (void)reportDisconnect:(nullable NSString *)reason {
    [self onEngineQueue:^{
        id<MVTorrentPeerDelegate> delegate = _delegate;
        if ([delegate respondsToSelector:@selector(peerDidDisconnect:reason:)]) {
            [delegate peerDidDisconnect:self reason:reason];
        }
    }];
}

@end
