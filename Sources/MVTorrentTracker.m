#import "MVTorrentTracker.h"
#import "MVBencode.h"

#include <arpa/inet.h>

@implementation MVTorrentPeerAddress

+ (instancetype)addressWithHost:(NSString *)host port:(NSInteger)port {
    if (!host.length || port <= 0 || port > 65535) return nil;
    MVTorrentPeerAddress *address = [MVTorrentPeerAddress new];
    address.host = host;
    address.port = port;
    return address;
}

- (NSString *)key {
    return [NSString stringWithFormat:@"%@:%ld", _host, (long)_port];
}

@end

@implementation MVTorrentTracker

/// Percent-encodes raw bytes. The info-hash and peer-id are binary, not text,
/// so every byte outside the unreserved set is escaped — exactly what the
/// tracker expects, and what a text-based encoder would get wrong.
static NSString *MVPercentEncodeBytes(NSData *data) {
    static const char *hex = "0123456789ABCDEF";
    const uint8_t *bytes = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger i = 0; i < data.length; i++) {
        uint8_t c = bytes[i];
        BOOL unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
        if (unreserved) {
            [out appendFormat:@"%c", c];
        } else {
            [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 0xF]];
        }
    }
    return out;
}

+ (NSURL *)announceURLForTracker:(NSString *)tracker
                        infoHash:(NSData *)infoHash
                          peerID:(NSData *)peerID
                            port:(NSInteger)port
                        uploaded:(long long)uploaded
                      downloaded:(long long)downloaded
                            left:(long long)left
                           event:(NSString *)event {
    if (!tracker.length || infoHash.length != 20 || peerID.length != 20) return nil;
    NSString *separator = [tracker containsString:@"?"] ? @"&" : @"?";
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@%@info_hash=%@&peer_id=%@&port=%ld",
                            tracker, separator,
                            MVPercentEncodeBytes(infoHash),
                            MVPercentEncodeBytes(peerID),
                            (long)port];
    [url appendFormat:@"&uploaded=%lld&downloaded=%lld&left=%lld&compact=1",
                      uploaded, downloaded, left];
    if (event.length) [url appendFormat:@"&event=%@", event];
    return [NSURL URLWithString:url];
}

+ (NSArray<MVTorrentPeerAddress *> *)peersFromAnnounceResponse:(NSData *)response error:(NSString **)error {
    if (!response.length) {
        if (error) *error = @"empty tracker response";
        return nil;
    }
    id decoded = [MVBencode decode:response error:NULL];
    if (![decoded isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"tracker response is not bencoded";
        return nil;
    }
    NSDictionary *dict = decoded;

    NSData *failure = dict[@"failure reason"];
    if ([failure isKindOfClass:NSData.class]) {
        NSString *reason = [[NSString alloc] initWithData:failure encoding:NSUTF8StringEncoding];
        if (error) *error = reason.length ? reason : @"tracker refused the announce";
        return nil;
    }

    NSMutableArray<MVTorrentPeerAddress *> *peers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    // Compact IPv4: 6 bytes per peer (4 address + 2 port, big endian).
    NSData *compact = dict[@"peers"];
    if ([compact isKindOfClass:NSData.class]) {
        [self appendCompactIPv4:compact to:peers seen:seen];
    } else if ([compact isKindOfClass:NSArray.class]) {
        // The original dictionary form: a list of {ip, port}.
        for (id entry in (NSArray *)compact) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *peer = entry;
            NSData *ip = peer[@"ip"];
            NSNumber *peerPort = peer[@"port"];
            NSString *host = [ip isKindOfClass:NSData.class]
                ? [[NSString alloc] initWithData:ip encoding:NSUTF8StringEncoding] : nil;
            if (!host.length || ![peerPort isKindOfClass:NSNumber.class]) continue;
            [self addHost:host port:peerPort.integerValue to:peers seen:seen];
        }
    }

    // Compact IPv6: 18 bytes per peer (16 address + 2 port).
    NSData *compact6 = dict[@"peers6"];
    if ([compact6 isKindOfClass:NSData.class]) {
        [self appendCompactIPv6:compact6 to:peers seen:seen];
    }

    return peers;
}

+ (void)appendCompactIPv4:(NSData *)data to:(NSMutableArray *)peers seen:(NSMutableSet *)seen {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i + 6 <= data.length; i += 6) {
        char text[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, bytes + i, text, sizeof(text))) continue;
        NSInteger port = (NSInteger)((bytes[i + 4] << 8) | bytes[i + 5]);
        [self addHost:[NSString stringWithUTF8String:text] port:port to:peers seen:seen];
    }
}

+ (void)appendCompactIPv6:(NSData *)data to:(NSMutableArray *)peers seen:(NSMutableSet *)seen {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i + 18 <= data.length; i += 18) {
        char text[INET6_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET6, bytes + i, text, sizeof(text))) continue;
        NSInteger port = (NSInteger)((bytes[i + 16] << 8) | bytes[i + 17]);
        [self addHost:[NSString stringWithUTF8String:text] port:port to:peers seen:seen];
    }
}

+ (void)addHost:(NSString *)host port:(NSInteger)port to:(NSMutableArray *)peers seen:(NSMutableSet *)seen {
    MVTorrentPeerAddress *address = [MVTorrentPeerAddress addressWithHost:host port:port];
    if (!address || [seen containsObject:address.key]) return;
    [seen addObject:address.key];
    [peers addObject:address];
}

+ (NSTimeInterval)intervalFromAnnounceResponse:(NSData *)response {
    id decoded = [MVBencode decode:response error:NULL];
    if (![decoded isKindOfClass:NSDictionary.class]) return 1800;
    NSNumber *interval = ((NSDictionary *)decoded)[@"interval"];
    if (![interval isKindOfClass:NSNumber.class]) return 1800;
    // Clamp: a tracker that asks for a very short or absurd interval is
    // overridden so a loop cannot hammer it or stall for a day.
    return MIN(3600, MAX(60, interval.doubleValue));
}

@end
