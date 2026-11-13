// Deterministic tests for the real peer parser and request bookkeeping.
#import <Foundation/Foundation.h>
#import "MVTorrentPeer.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

@interface MVTorrentPeer (Tests)
- (void)processBuffer;
- (void)setUnchoked:(BOOL)unchoked;
- (void)handleHave:(NSData *)payload;
- (void)handlePiece:(NSData *)payload;
- (void)checkOutstandingTimeouts;
@end

@interface PeerSpy : NSObject <MVTorrentPeerDelegate>
@property (nonatomic, strong) NSMutableArray<MVTorrentBlock *> *received;
@property (nonatomic, strong) NSMutableArray<MVTorrentBlock *> *lost;
@end
@implementation PeerSpy
- (instancetype)init {
    if ((self = [super init])) { _received = [NSMutableArray array]; _lost = [NSMutableArray array]; }
    return self;
}
- (void)peerDidConnect:(MVTorrentPeer *)peer { (void)peer; }
- (void)peerDidChangeAvailability:(MVTorrentPeer *)peer { (void)peer; }
- (void)peer:(MVTorrentPeer *)peer didReceiveBlock:(MVTorrentBlock *)block data:(NSData *)data {
    (void)peer; (void)data; [self.received addObject:block];
}
- (void)peer:(MVTorrentPeer *)peer didLoseBlock:(MVTorrentBlock *)block { (void)peer; [self.lost addObject:block]; }
- (void)peer:(MVTorrentPeer *)peer didReceiveExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload {
    (void)peer; (void)extendedID; (void)payload;
}
- (void)peerDidDisconnect:(MVTorrentPeer *)peer reason:(NSString *)reason { (void)peer; (void)reason; }
@end

static void drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
    CHECK(done, "main queue callbacks drained");
}

static NSData *Piece(NSInteger index, NSInteger begin, NSData *body) {
    uint32_t values[] = {htonl((uint32_t)index), htonl((uint32_t)begin)};
    NSMutableData *data = [NSMutableData dataWithBytes:values length:sizeof(values)];
    [data appendData:body];
    return data;
}

int main(void) {
    @autoreleasepool {
        PeerSpy *spy = [PeerSpy new];
        NSData *hash = [NSData dataWithBytes:"01234567890123456789" length:20];
        NSData *peerID = [NSData dataWithBytes:"-MV0001-abcdefghijkl" length:20];
        MVTorrentPeer *peer = [[MVTorrentPeer alloc] initWithHost:@"127.0.0.1" port:1 infoHash:hash
                                                          peerID:peerID pieceCount:3 delegate:spy];
        [peer setCallbackQueue:dispatch_get_main_queue()];
        uint8_t handshake[68] = {19};
        memcpy(handshake + 1, "BitTorrent protocol", 19);
        memcpy(handshake + 28, hash.bytes, 20);
        memcpy(handshake + 48, peerID.bytes, 20);
        NSMutableData *buffer = [peer valueForKey:@"receiveBuffer"];
        [buffer appendBytes:handshake length:4];
        [peer processBuffer];
        CHECK(![[peer valueForKey:@"stopping"] boolValue] && ![[peer valueForKey:@"handshakeReceived"] boolValue],
              "a fragmented handshake waits for the protocol bytes");
        [buffer appendBytes:handshake + 4 length:64];
        [peer processBuffer];
        CHECK([[peer valueForKey:@"handshakeReceived"] boolValue] && buffer.length == 0, "complete handshake accepted");

        uint32_t invalidIndex = htonl(UINT32_MAX), validIndex = htonl(1);
        [peer handleHave:[NSData dataWithBytes:&invalidIndex length:4]];
        [peer handleHave:[NSData dataWithBytes:&validIndex length:4]];
        CHECK(peer.availablePieces.count == 1 && [peer.availablePieces containsIndex:1], "HAVE respects piece bounds");

        NSData *body = [NSData dataWithBytes:"abc" length:3];
        [peer setUnchoked:YES];
        [peer handlePiece:Piece(0, 0, body)];
        drain();
        CHECK(spy.received.count == 0, "unsolicited block ignored");

        MVTorrentBlock *old = [MVTorrentBlock blockWithIndex:0 begin:0 length:3];
        [peer requestBlock:old];
        [peer setUnchoked:NO]; // queues loss of the old request
        [peer setUnchoked:YES];
        MVTorrentBlock *replacement = [MVTorrentBlock blockWithIndex:0 begin:0 length:3];
        [peer requestBlock:replacement];
        drain();
        CHECK(spy.lost.count == 1 && spy.lost.firstObject == old && peer.blocksInFlight == 1,
              "choke returns the old request without losing its replacement");
        [peer handlePiece:Piece(0, 0, body)];
        drain();
        CHECK(spy.received.count == 1 && spy.received.firstObject == replacement && peer.blocksInFlight == 0,
              "received callback retains exact request identity");

        MVTorrentBlock *shortBlock = [MVTorrentBlock blockWithIndex:1 begin:0 length:3];
        [peer requestBlock:shortBlock];
        [peer handlePiece:Piece(1, 0, [NSData dataWithBytes:"x" length:1])];
        drain();
        CHECK(spy.lost.lastObject == shortBlock && spy.received.count == 1, "short block is returned, not accepted");

        MVTorrentBlock *expired = [MVTorrentBlock blockWithIndex:2 begin:0 length:3];
        [peer requestBlock:expired];
        NSMutableDictionary *times = [peer valueForKey:@"outstandingSince"];
        times[@"2:0"] = @(-100);
        [peer checkOutstandingTimeouts];
        drain();
        CHECK(spy.lost.lastObject == expired && peer.blocksInFlight == 0, "expired block is returned");

        if (!failures) puts("torrent peer parser and ownership: OK");
    }
    return failures ? 1 : 0;
}
