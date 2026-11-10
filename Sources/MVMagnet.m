#import "MVMagnet.h"
#import "MVSHA1.h"

@implementation MVMagnet

+ (BOOL)isMagnetURL:(NSString *)url {
    if (![url isKindOfClass:NSString.class]) return NO;
    return [url.lowercaseString hasPrefix:@"magnet:"];
}

+ (instancetype)magnetWithURL:(NSString *)url {
    if (![self isMagnetURL:url]) return nil;
    MVMagnet *magnet = [MVMagnet new];

    NSString *query = url;
    NSRange question = [url rangeOfString:@"?"];
    if (question.location != NSNotFound) query = [url substringFromIndex:question.location + 1];

    NSMutableArray<NSString *> *trackers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [pair substringToIndex:equals.location];
        NSString *value = [pair substringFromIndex:equals.location + 1];
        // The values are percent-encoded, and a tracker URL can contain & that
        // was escaped; decode after splitting on the raw &.
        value = [value stringByRemovingPercentEncoding] ?: value;

        if ([key isEqualToString:@"xt"]) {
            // "urn:btih:<40 hex | 32 base32>" or "urn:btmh:<multihash>" (v2).
            if ([value hasPrefix:@"urn:btih:"]) {
                NSString *hash = [value substringFromIndex:9];
                NSData *bytes = [self bytesFromInfoHash:hash];
                if (bytes) magnet.infoHash = bytes;
            } else if ([value hasPrefix:@"urn:btmh:"]) {
                // A v2 hash is a multihash: 0x12 0x20 then 32 bytes of sha256.
                NSString *hash = [value substringFromIndex:9];
                if ([hash hasPrefix:@"1220"]) hash = [hash substringFromIndex:4];
                NSData *bytes = [MVSHA1 dataFromHexString:hash];
                if (bytes) magnet.infoHash = bytes;
            }
        } else if ([key isEqualToString:@"dn"]) {
            if (value.length) magnet.displayName = value;
        } else if ([key isEqualToString:@"tr"]) {
            if (value.length && ![seen containsObject:value]) {
                [seen addObject:value];
                [trackers addObject:value];
            }
        }
    }
    magnet.trackers = trackers;
    if (!magnet.infoHash.length) return nil;
    return magnet;
}

/// A 40-character hex hash, or a 32-character base32 one (RFC 4648 alphabet).
+ (nullable NSData *)bytesFromInfoHash:(NSString *)hash {
    if (hash.length == 40) return [MVSHA1 dataFromHexString:hash];
    if (hash.length == 32) return [self bytesFromBase32:hash];
    return nil;
}

+ (nullable NSData *)bytesFromBase32:(NSString *)text {
    static const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    uint32_t buffer = 0;
    int bits = 0;
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [[text uppercaseString] characterAtIndex:i];
        if (c == 0 || c > 127) return nil;
        const char *found = strchr(alphabet, (char)c);
        if (!found) return nil;
        int value = (int)(found - alphabet);
        buffer = (buffer << 5) | (uint32_t)value;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            uint8_t byte = (uint8_t)((buffer >> bits) & 0xFF);
            [out appendBytes:&byte length:1];
        }
    }
    return out.length == 20 ? out : nil;
}

- (BOOL)isV2 {
    return self.infoHash.length == 32;
}

- (NSString *)infoHashHex {
    return self.infoHash.length ? [MVSHA1 hexString:self.infoHash] : nil;
}

@end
