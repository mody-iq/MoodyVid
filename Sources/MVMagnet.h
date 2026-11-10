#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A parsed `magnet:` link (BEP 9).
///
/// Only the parts a downloader acts on are kept: the info-hash that names the
/// torrent, and the trackers to announce to. The display name is carried for the
/// row, but a magnet cannot be downloaded from the name alone.
@interface MVMagnet : NSObject

/// The 20-byte (SHA-1) or 32-byte (BEP 52) info-hash, or nil when absent.
@property (nonatomic, copy, nullable) NSData *infoHash;
/// YES when the info-hash is a 32-byte BEP 52 (v2) hash, which this engine
/// does not speak yet.
@property (nonatomic, readonly) BOOL isV2;
@property (nonatomic, copy, nullable) NSString *displayName;
/// `tr=` trackers, in the order given, deduplicated.
@property (nonatomic, copy) NSArray<NSString *> *trackers;

/// YES when `url` starts with the `magnet:` scheme.
+ (BOOL)isMagnetURL:(nullable NSString *)url;

/// Parses a magnet link. Returns nil when there is no usable info-hash.
+ (nullable instancetype)magnetWithURL:(NSString *)url;

/// The info-hash as lowercase hex, or nil.
- (nullable NSString *)infoHashHex;

@end

NS_ASSUME_NONNULL_END
