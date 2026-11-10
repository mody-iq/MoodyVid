#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The bencode codec (BEP 3), the wire format a `.torrent` file and a tracker
/// response are written in.
///
/// Byte strings decode to `NSData`, never `NSString`: the info dictionary has to
/// be re-encoded byte-for-byte to compute its SHA-1 info-hash, and a lossy
/// string conversion would change the hash. Dictionary keys are the exception:
/// they decode to `NSString` when they are valid UTF-8 (a key is a field name
/// like `name` or `peers`), so callers can look them up by name; a key that is
/// not valid UTF-8 stays `NSData`. Integers decode to `NSNumber` (long long),
/// lists to `NSArray` and dictionaries to `NSDictionary`.
@interface MVBencode : NSObject

/// Decodes a whole bencoded value. Returns nil and fills `error` on malformed
/// input. Trailing bytes after the value are ignored, as the spec allows.
+ (nullable id)decode:(NSData *)data error:(NSString *_Nullable *_Nullable)error;

/// Encodes a value the codec understands back to bytes. Keys may be `NSData` or
/// `NSString`; strings likewise. Used to re-encode the info dictionary.
+ (nullable NSData *)encode:(id)object;

/// The raw, unmodified bytes of the value stored under a top-level key of a
/// bencoded dictionary.
///
/// The info-hash is the SHA-1 of the info dictionary's bytes exactly as the
/// author wrote them. Re-encoding a decoded dictionary usually reproduces those
/// bytes, but a file that is not canonically encoded (keys out of order, a
/// redundant form) would hash differently, so the torrent parser slices the
/// original bytes instead of trusting the re-encode.
+ (nullable NSData *)rawValueForTopLevelKey:(NSString *)key inData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
