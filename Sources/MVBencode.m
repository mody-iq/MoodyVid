#import "MVBencode.h"

/// Walks a byte buffer, decoding one value at a time. A class rather than a
/// pile of functions so the cursor and the error live in one place.
@interface MVBencodeReader : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic) NSUInteger pos;
@property (nonatomic, copy, nullable) NSString *error;
@end

@implementation MVBencodeReader

- (BOOL)hasBytes:(NSUInteger)count {
    return _pos + count <= _data.length;
}

- (uint8_t)peek {
    if (_pos >= _data.length) return 0;
    return ((const uint8_t *)_data.bytes)[_pos];
}

- (BOOL)expect:(uint8_t)byte {
    if (![self hasBytes:1] || [self peek] != byte) {
        self.error = [NSString stringWithFormat:@"expected '%c' at %lu", byte, (unsigned long)_pos];
        return NO;
    }
    _pos += 1;
    return YES;
}

/// Reads `len` raw bytes as NSData, without copying the whole buffer.
- (nullable NSData *)readBytes:(NSUInteger)len {
    if (![self hasBytes:len]) {
        self.error = @"truncated value";
        return nil;
    }
    NSData *slice = [_data subdataWithRange:NSMakeRange(_pos, len)];
    _pos += len;
    return slice;
}

/// Reads a decimal integer up to the next 'e'. No leading zeros (except "0"),
/// no sign, as the spec requires.
- (nullable NSNumber *)readInteger {
    if (![self expect:'i']) return nil;
    NSMutableString *digits = [NSMutableString string];
    while ([self hasBytes:1] && [self peek] != 'e') {
        uint8_t c = [self peek];
        if (c < '0' || c > '9') {
            self.error = @"bad character in integer";
            return nil;
        }
        [digits appendFormat:@"%c", c];
        _pos += 1;
    }
    if (![self expect:'e']) return nil;
    if (!digits.length) {
        self.error = @"empty integer";
        return nil;
    }
    if (digits.length > 1 && [digits characterAtIndex:0] == '0') {
        self.error = @"integer has a leading zero";
        return nil;
    }
    // A 64-bit counter (a large piece length, a file offset) needs long long.
    unsigned long long value = strtoull(digits.UTF8String, NULL, 10);
    return @((long long)value);
}

/// A byte string: "<length>:<bytes>".
- (nullable NSData *)readString {
    NSMutableString *digits = [NSMutableString string];
    while ([self hasBytes:1] && [self peek] != ':') {
        uint8_t c = [self peek];
        if (c < '0' || c > '9') {
            self.error = @"bad length in string";
            return nil;
        }
        [digits appendFormat:@"%c", c];
        _pos += 1;
    }
    if (![self expect:':']) return nil;
    if (!digits.length) {
        self.error = @"empty string length";
        return nil;
    }
    unsigned long long len = strtoull(digits.UTF8String, NULL, 10);
    if (len > _data.length) {
        self.error = @"string length exceeds the data";
        return nil;
    }
    return [self readBytes:(NSUInteger)len];
}

- (nullable NSArray *)readList {
    if (![self expect:'l']) return nil;
    NSMutableArray *list = [NSMutableArray array];
    while ([self hasBytes:1] && [self peek] != 'e') {
        id item = [self readValue];
        if (!item) return nil;
        [list addObject:item];
    }
    if (![self expect:'e']) return nil;
    return list;
}

- (nullable NSDictionary *)readDictionary {
    if (![self expect:'d']) return nil;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    while ([self hasBytes:1] && [self peek] != 'e') {
        NSData *key = [self readString];
        if (!key) return nil;
        id value = [self readValue];
        if (!value) return nil;
        dict[key] = value;
    }
    if (![self expect:'e']) return nil;
    return dict;
}

- (nullable id)readValue {
    if (![self hasBytes:1]) {
        self.error = @"unexpected end of data";
        return nil;
    }
    uint8_t c = [self peek];
    if (c == 'i') return [self readInteger];
    if (c == 'l') return [self readList];
    if (c == 'd') return [self readDictionary];
    if (c >= '0' && c <= '9') return [self readString];
    self.error = [NSString stringWithFormat:@"unknown type '%c' at %lu", c, (unsigned long)_pos];
    return nil;
}

/// Skips one value without building it, advancing past it. Used to find where a
/// top-level value ends so its raw bytes can be sliced out.
- (BOOL)skipValue {
    if (![self hasBytes:1]) { self.error = @"unexpected end of data"; return NO; }
    uint8_t c = [self peek];
    if (c == 'i') {
        while ([self hasBytes:1] && [self peek] != 'e') _pos += 1;
        return [self expect:'e'];
    }
    if (c == 'l' || c == 'd') {
        _pos += 1;
        while ([self hasBytes:1] && [self peek] != 'e') {
            if (c == 'd') {
                if (![self skipValue]) return NO;   // the key
            }
            if (![self skipValue]) return NO;       // the value
        }
        return [self expect:'e'];
    }
    if (c >= '0' && c <= '9') {
        NSMutableString *digits = [NSMutableString string];
        while ([self hasBytes:1] && [self peek] != ':') {
            uint8_t d = [self peek];
            if (d < '0' || d > '9') { self.error = @"bad length in string"; return NO; }
            [digits appendFormat:@"%c", d];
            _pos += 1;
        }
        if (![self expect:':']) return NO;
        unsigned long long len = strtoull(digits.UTF8String, NULL, 10);
        if (len > _data.length - _pos) { self.error = @"string length exceeds the data"; return NO; }
        _pos += (NSUInteger)len;
        return YES;
    }
    self.error = [NSString stringWithFormat:@"unknown type '%c' at %lu", c, (unsigned long)_pos];
    return NO;
}

@end

@implementation MVBencode

+ (id)decode:(NSData *)data error:(NSString **)error {
    if (!data.length) {
        if (error) *error = @"empty data";
        return nil;
    }
    MVBencodeReader *reader = [MVBencodeReader new];
    reader.data = data;
    id value = [reader readValue];
    if (!value && error) *error = reader.error ?: @"malformed bencode";
    return value;
}

+ (NSData *)rawValueForTopLevelKey:(NSString *)key inData:(NSData *)data {
    MVBencodeReader *reader = [MVBencodeReader new];
    reader.data = data;
    if (![reader expect:'d']) return nil;
    NSData *wanted = [key dataUsingEncoding:NSUTF8StringEncoding];
    while ([reader hasBytes:1] && [reader peek] != 'e') {
        NSData *found = [reader readString];
        if (!found) return nil;
        NSUInteger start = reader.pos;
        if (![reader skipValue]) return nil;
        if ([found isEqualToData:wanted]) {
            return [data subdataWithRange:NSMakeRange(start, reader.pos - start)];
        }
    }
    return nil;
}

/// The one place a string-ish object becomes bytes, so encode and decode agree.
static NSData *MVBencodeBytes(id object) {
    if ([object isKindOfClass:NSData.class]) return object;
    if ([object isKindOfClass:NSString.class]) return [(NSString *)object dataUsingEncoding:NSUTF8StringEncoding];
    if ([object isKindOfClass:NSNumber.class]) return [[(NSNumber *)object stringValue] dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}

/// Orders two byte strings the way bencode wants dictionary keys ordered: as
/// raw bytes (memcmp), so a shorter string that is a prefix of a longer one
/// sorts first. `NSData` has no public `compare:` on Apple's Foundation, so the
/// bytes are compared here.
static NSComparisonResult MVBencodeCompareBytes(NSData *a, NSData *b) {
    NSUInteger common = MIN(a.length, b.length);
    const uint8_t *pa = a.bytes;
    const uint8_t *pb = b.bytes;
    for (NSUInteger i = 0; i < common; i++) {
        if (pa[i] != pb[i]) return pa[i] < pb[i] ? NSOrderedAscending : NSOrderedDescending;
    }
    if (a.length == b.length) return NSOrderedSame;
    return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
}

+ (NSData *)encode:(id)object {
    NSMutableData *out = [NSMutableData data];
    if (![self append:object to:out]) return nil;
    return out;
}

+ (BOOL)append:(id)object to:(NSMutableData *)out {
    if ([object isKindOfClass:NSNumber.class]) {
        NSString *text = [NSString stringWithFormat:@"i%llde", [(NSNumber *)object longLongValue]];
        [out appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        return YES;
    }
    if ([object isKindOfClass:NSData.class] || [object isKindOfClass:NSString.class]) {
        NSData *bytes = MVBencodeBytes(object);
        if (!bytes) return NO;
        NSString *header = [NSString stringWithFormat:@"%lu:", (unsigned long)bytes.length];
        [out appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        [out appendData:bytes];
        return YES;
    }
    if ([object isKindOfClass:NSArray.class]) {
        [out appendBytes:"l" length:1];
        for (id item in (NSArray *)object) {
            if (![self append:item to:out]) return NO;
        }
        [out appendBytes:"e" length:1];
        return YES;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = object;
        [out appendBytes:"d" length:1];
        // The spec wants keys sorted as raw byte strings. Sorting the byte form
        // (not the text form) is what makes the info-hash match a real client.
        NSArray *keys = [dict.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSData *da = MVBencodeBytes(a);
            NSData *db = MVBencodeBytes(b);
            return MVBencodeCompareBytes(da, db);
        }];
        for (id key in keys) {
            if (![self append:key to:out]) return NO;
            if (![self append:dict[key] to:out]) return NO;
        }
        [out appendBytes:"e" length:1];
        return YES;
    }
    return NO;
}

@end
