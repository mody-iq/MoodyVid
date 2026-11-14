#include <dispatch/dispatch.h>

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One 16 KiB slice of a piece. Peers exchange pieces block by block, so this is
/// the unit the engine schedules.
@interface MVTorrentBlock : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) NSInteger begin;
@property (nonatomic) NSInteger length;
+ (instancetype)blockWithIndex:(NSInteger)index begin:(NSInteger)begin length:(NSInteger)length;
@end

@class MVTorrentPeer;

/// What the engine listens to on a peer. Every method is called on the queue the
/// peer was created with, so the engine's state is never touched concurrently.
@protocol MVTorrentPeerDelegate <NSObject>
/// The handshake completed and the peer's bitfield is known.
- (void)peerDidConnect:(MVTorrentPeer *)peer;
/// The peer's piece availability changed (bitfield or have).
- (void)peerDidChangeAvailability:(MVTorrentPeer *)peer;
/// A block arrived.
- (void)peer:(MVTorrentPeer *)peer didReceiveBlock:(MVTorrentBlock *)block data:(NSData *)data;
/// A requested block did not arrive in time; the engine should give it to
/// another peer or this one again.
- (void)peer:(MVTorrentPeer *)peer didLoseBlock:(MVTorrentBlock *)block;
/// An extended-protocol message (BEP 10) arrived. `extendedID` is 0 for the
/// handshake itself, and `payload` is the raw bencoded/opaque body.
- (void)peer:(MVTorrentPeer *)peer didReceiveExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload;
/// The peer closed, timed out, or a requested block was lost.
- (void)peerDidDisconnect:(MVTorrentPeer *)peer reason:(nullable NSString *)reason;
@end

/// A connection to one peer, speaking the BitTorrent peer wire protocol (BEP 3)
/// over its own socket thread.
///
/// The peer is deliberately dumb about which pieces matter: it reports what it
/// has and asks the engine for the next block. All the piece bookkeeping — which
/// piece is wanted, which blocks are outstanding, which peer got which block —
/// stays in the engine, where it is easy to reason about.
@interface MVTorrentPeer : NSObject

@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) NSInteger port;
/// YES once the handshake is done and the connection is usable.
@property (nonatomic, readonly) BOOL connected;
/// YES when the peer is not choking us.
@property (nonatomic, readonly) BOOL unchoked;
/// The pieces the peer has said it holds.
@property (nonatomic, readonly) NSIndexSet *availablePieces;
/// How many blocks this peer may have in flight at once.
@property (nonatomic) NSInteger maxInFlight;
/// Nonzero binds the socket to this interface. Set before start; a failed bind
/// closes the socket instead of falling back to cellular.
@property (nonatomic) unsigned int boundInterfaceIndex;
/// Filled in when the connection ends, for the log.
@property (nonatomic, copy, nullable) NSString *failureReason;
/// The engine's job key, so a delegate callback can find the job it belongs to.
@property (nonatomic, copy, nullable) NSString *jobIdentifier;
/// How many requested blocks have not arrived yet.
@property (nonatomic, readonly) NSInteger blocksInFlight;

/// The peer's BEP 10 extended handshake (its `m` map), once it has arrived, or
/// nil. The engine reads the peer's `ut_metadata` id from here before asking it
/// for the metadata of a magnet link.
@property (nonatomic, readonly, nullable) NSDictionary *extendedHandshake;
/// YES once the peer's extended handshake has been parsed.
@property (nonatomic, readonly) BOOL extendedHandshakeReceived;

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    infoHash:(NSData *)infoHash
                     peerID:(NSData *)peerID
                  pieceCount:(NSInteger)pieceCount
                    delegate:(id<MVTorrentPeerDelegate>)delegate;

/// Starts the socket thread. Idempotent.
- (void)start;
/// The queue delegate callbacks are delivered on. Set before -start so the
/// engine never sees a callback on the peer's socket thread.
- (void)setCallbackQueue:(dispatch_queue_t)queue;
/// Asks the peer for a block. Ignored unless the peer has unchoked us.
- (void)requestBlock:(MVTorrentBlock *)block;
/// Tells the peer we have a piece now.
- (void)sendHave:(NSInteger)index;
/// Tells the peer we are no longer interested.
- (void)sendNotInterested;
/// Sends an extended-protocol message (BEP 10). `extendedID` 0 is the handshake.
- (void)sendExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload;

/// Sends a BEP 9 `ut_metadata` request for the metadata piece `piece`. The peer
/// must have advertised a `ut_metadata` id in its extended handshake first.
- (void)sendMetadataRequestForPiece:(NSInteger)piece;
/// Stops the peer and closes the socket.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
