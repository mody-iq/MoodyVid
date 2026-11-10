#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One peer a tracker told us about.
@interface MVTorrentPeerAddress : NSObject
@property (nonatomic, copy) NSString *host;
@property (nonatomic) NSInteger port;
+ (instancetype)addressWithHost:(NSString *)host port:(NSInteger)port;
/// The "host:port" form used as a dictionary key so a peer is not added twice.
@property (nonatomic, readonly) NSString *key;
@end

/// A tracker announce (BEP 3 / BEP 23).
///
/// Only HTTP(S) trackers are spoken: the response is bencoded, so the same codec
/// that reads a `.torrent` reads the reply. UDP trackers (BEP 15) and the DHT
/// are not used here — a torrent with no HTTP tracker has no peer source, which
/// the engine reports honestly rather than hanging.
@interface MVTorrentTracker : NSObject

/// Builds the announce URL: the tracker plus `info_hash`, `peer_id`, `port`,
/// `uploaded`, `downloaded`, `left`, `compact=1` and the event.
///
/// The info-hash and peer-id are raw 20-byte strings that must be
/// percent-encoded byte-for-byte, so they are encoded here rather than by
/// NSURLComponents (which would treat them as text).
+ (nullable NSURL *)announceURLForTracker:(NSString *)tracker
                                 infoHash:(NSData *)infoHash
                                   peerID:(NSData *)peerID
                                     port:(NSInteger)port
                                   uploaded:(long long)uploaded
                                 downloaded:(long long)downloaded
                                       left:(long long)left
                                      event:(nullable NSString *)event;

/// The peers in a bencoded announce response. Handles both the compact form
/// (`peers` as 6-byte records, `peers6` as 18-byte records) and the dictionary
/// form (`peers` as a list of `{ip, port}`), because old trackers still send it.
+ (nullable NSArray<MVTorrentPeerAddress *> *)peersFromAnnounceResponse:(NSData *)response
                                                                   error:(NSString *_Nullable *_Nullable)error;

/// The `interval` the tracker asked us to wait, or a sane default when absent.
+ (NSTimeInterval)intervalFromAnnounceResponse:(NSData *)response;

@end

NS_ASSUME_NONNULL_END
