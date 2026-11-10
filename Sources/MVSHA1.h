#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SHA-1 (FIPS 180-1), the hash BitTorrent is built on: the info-hash that
/// names a torrent, and the per-piece check that proves a downloaded piece is
/// the one the swarm agreed on.
///
/// Implemented here rather than with CommonCrypto so the same bytes are produced
/// on device and on the build machine, where the piece logic is unit-tested.
@interface MVSHA1 : NSObject

/// The 20-byte digest of `data`.
+ (NSData *)digest:(NSData *)data;

/// YES when `data` hashes to `expected` (both 20 bytes).
+ (BOOL)data:(NSData *)data matchesDigest:(NSData *)expected;

/// The lowercase hex form, for logs and magnet URIs.
+ (NSString *)hexString:(NSData *)data;

/// Decodes a 40-character hex string into 20 bytes, or nil when malformed.
+ (nullable NSData *)dataFromHexString:(NSString *)hex;

@end

NS_ASSUME_NONNULL_END
