#include <string.h>

#import "MVSHA1.h"

@implementation MVSHA1

+ (NSData *)digest:(NSData *)data {
    uint32_t h[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u};
    const uint8_t *bytes = data.bytes;
    uint64_t totalBits = (uint64_t)data.length * 8;
    NSUInteger full = data.length / 64;

    uint8_t block[64];
    for (NSUInteger b = 0; b <= full; b++) {
        NSUInteger offset = b * 64;
        NSUInteger remaining = data.length - offset;
        BOOL last = (b == full);
        if (!last) {
            memcpy(block, bytes + offset, 64);
        } else {
            // The final block(s): the data, a 0x80 byte, zero padding, then the
            // 64-bit big-endian bit length. It may need a second block.
            NSUInteger tail = remaining;
            memset(block, 0, 64);
            memcpy(block, bytes + offset, tail);
            block[tail] = 0x80;
            if (tail >= 56) {
                [self processBlock:block into:h];
                memset(block, 0, 64);
            }
            for (int i = 0; i < 8; i++) {
                block[63 - i] = (uint8_t)(totalBits >> (8 * i));
            }
        }
        [self processBlock:block into:h];
    }

    uint8_t out[20];
    for (int i = 0; i < 5; i++) {
        out[i * 4 + 0] = (uint8_t)(h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(h[i]);
    }
    return [NSData dataWithBytes:out length:20];
}

+ (void)processBlock:(const uint8_t *)block into:(uint32_t *)h {
    uint32_t w[80];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    }
    for (int i = 16; i < 80; i++) {
        uint32_t v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
        w[i] = (v << 1) | (v >> 31);
    }

    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20)      { f = (b & c) | ((~b) & d);            k = 0x5A827999u; }
        else if (i < 40) { f = b ^ c ^ d;                       k = 0x6ED9EBA1u; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d);     k = 0x8F1BBCDCu; }
        else             { f = b ^ c ^ d;                       k = 0xCA62C1D6u; }
        uint32_t temp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
        e = d;
        d = c;
        c = (b << 30) | (b >> 2);
        b = a;
        a = temp;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

+ (BOOL)data:(NSData *)data matchesDigest:(NSData *)expected {
    if (expected.length != 20) return NO;
    return [[self digest:data] isEqualToData:expected];
}

+ (NSString *)hexString:(NSData *)data {
    static const char *digits = "0123456789abcdef";
    const uint8_t *bytes = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [out appendFormat:@"%c%c", digits[bytes[i] >> 4], digits[bytes[i] & 0xF]];
    }
    return out;
}

+ (NSData *)dataFromHexString:(NSString *)hex {
    if (hex.length % 2 != 0) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        unichar hi = [hex characterAtIndex:i];
        unichar lo = [hex characterAtIndex:i + 1];
        int h = [self valueOf:hi];
        int l = [self valueOf:lo];
        if (h < 0 || l < 0) return nil;
        uint8_t byte = (uint8_t)((h << 4) | l);
        [out appendBytes:&byte length:1];
    }
    return out;
}

+ (int)valueOf:(unichar)c {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

@end
