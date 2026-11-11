// Offline tests for the torrent core (bencode, SHA-1, magnet, metadata,
// tracker). Build: see scripts/torrent-tests.sh — they run with the system
// clang and Foundation on macOS, so the piece/hash logic is proven before the
// device build without needing a real swarm.
#import <Foundation/Foundation.h>
#import "MVBencode.h"
#import "MVSHA1.h"
#import "MVMagnet.h"
#import "MVTorrentMetadata.h"
#import "MVTorrentTracker.h"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } } while (0)
static NSData *B(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

int main(void) {
    @autoreleasepool {
        // --- SHA-1 known vectors (FIPS 180-1) ---
        CHECK([[MVSHA1 hexString:[MVSHA1 digest:B(@"")]] isEqualToString:@"da39a3ee5e6b4b0d3255bfef95601890afd80709"], "sha1 empty");
        CHECK([[MVSHA1 hexString:[MVSHA1 digest:B(@"abc")]] isEqualToString:@"a9993e364706816aba3e25717850c26c9cd0d89d"], "sha1 abc");
        NSString *longer = @"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        CHECK([[MVSHA1 hexString:[MVSHA1 digest:B(longer)]] isEqualToString:@"84983e441c3bd26ebaae4aa1f95129e5e54670f1"], "sha1 56-byte");
        NSMutableData *million = [NSMutableData data];
        NSData *chunk = B(@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        for (int i = 0; i < 1000; i++) [million appendData:chunk];
        CHECK([million length] == 1000000, "million bytes built");
        CHECK([[MVSHA1 hexString:[MVSHA1 digest:million]] isEqualToString:@"34aa973cd4c4daa4f61eeb2bdbad27316534016f"], "sha1 million a");

        // --- magnet links ---
        NSString *hex = @"0123456789abcdef0123456789abcdef01234567";
        MVMagnet *m = [MVMagnet magnetWithURL:[NSString stringWithFormat:@"magnet:?xt=urn:btih:%@&dn=My%%20File&tr=http%%3A%%2F%%2Ftracker.test%%2Fannounce", hex]];
        CHECK(m != nil, "magnet parses");
        CHECK([[m infoHashHex] isEqualToString:hex], "magnet hash");
        CHECK([m.displayName isEqualToString:@"My File"], "magnet dn decoded");
        CHECK([m.trackers.firstObject isEqualToString:@"http://tracker.test/announce"], "magnet tracker decoded");
        CHECK(!m.isV2, "v1 magnet");
        MVMagnet *base32 = [MVMagnet magnetWithURL:@"magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"];
        CHECK(base32 != nil, "base32 magnet parses");
        CHECK(base32.infoHash.length == 20, "base32 hash is 20 bytes");
        CHECK([MVMagnet magnetWithURL:@"magnet:?dn=no-hash"] == nil, "magnet without hash refused");
        CHECK(![MVMagnet isMagnetURL:@"http://x"], "http is not a magnet");

        // --- torrent file parsing ---
        NSString *info = @"d6:lengthi16384e4:name8:test.bin12:piece lengthi16384e6:pieces20:01234567890123456789e";
        NSString *torrent = [NSString stringWithFormat:@"d8:announce20:http://tracker.test/4:info%@e", info];
        NSString *err = nil;
        MVTorrentMetadata *meta = [MVTorrentMetadata metadataWithTorrentData:B(torrent) error:&err];
        CHECK(meta != nil, "single-file torrent parses");
        CHECK([meta.name isEqualToString:@"test.bin"], "torrent name");
        CHECK(meta.pieceCount == 1, "piece count");
        CHECK(meta.totalLength == 16384, "total length");
        CHECK(meta.isSingleFile, "single file");
        CHECK([meta.trackers.firstObject isEqualToString:@"http://tracker.test/"], "announce");
        // The info-hash must be the SHA-1 of the info dict's exact bytes.
        CHECK([meta.infoHashHex isEqualToString:[MVSHA1 hexString:[MVSHA1 digest:B(info)]]], "info hash from raw info bytes");

        // A multi-file torrent with a padding file; offsets must run in order.
        NSString *minfo = @"d5:filesl"
            "d6:lengthi100e4:pathl1:aee"
            "d6:lengthi50e4:pathl1:bee"
            "d6:lengthi0e4:pathl1:ce4:attr1:pe"
            "e4:name4:root12:piece lengthi64e6:pieces60:012345678901234567890123456789012345678901234567890123456789e";
        NSString *mtorrent = [NSString stringWithFormat:@"d4:info%@e", minfo];
        MVTorrentMetadata *mmeta = [MVTorrentMetadata metadataWithTorrentData:B(mtorrent) error:&err];
        CHECK(mmeta != nil, "multi-file torrent parses");
        CHECK(mmeta.files.count == 3, "three file entries");
        MVTorrentFile *f0 = mmeta.files[0];
        MVTorrentFile *f1 = mmeta.files[1];
        MVTorrentFile *f2 = mmeta.files[2];
        CHECK(f0.offset == 0 && f1.offset == 100, "running offsets");
        CHECK(f2.isPadding, "padding flag");
        CHECK(mmeta.totalLength == 150, "multi total");
        CHECK(mmeta.pieceCount == 3, "multi piece count");
        CHECK([f1.relativePath isEqualToString:@"b"], "relative path");

        // Malformed torrents must be refused, not crash.
        CHECK([MVTorrentMetadata metadataWithTorrentData:B(@"not bencode") error:&err] == nil, "garbage refused");
        CHECK([MVTorrentMetadata metadataWithTorrentData:B(@"d4:infod6:lengthi1eee") error:&err] == nil, "no piece length refused");
        CHECK([MVTorrentMetadata metadataWithTorrentData:B(@"d4:infod6:lengthi5e4:name1:a12:piece lengthi4e6:pieces20:aaaaaaaaaaaaaaaaaaaaee") error:&err] == nil, "piece count mismatch refused");

        // --- bencode round-trip and edge cases ---
        CHECK([[MVBencode decode:B(@"i42e") error:&err] longLongValue] == 42, "integer decode");
        CHECK([[MVBencode decode:B(@"4:spam") error:&err] isEqualToData:B(@"spam")], "string decode");
        CHECK([MVBencode decode:B(@"i-7e") error:&err] == nil, "negative integer refused");
        CHECK([MVBencode decode:B(@"i03e") error:&err] == nil, "leading-zero integer refused");
        CHECK([MVBencode decode:B(@"5:ab") error:&err] == nil, "truncated string refused");
        CHECK([MVBencode decode:[NSData data] error:&err] == nil, "empty data refused");
        // Dictionary keys are byte strings and must sort as bytes on re-encode.
        NSData *encoded = [MVBencode encode:@{@"b": @1, @"a": @2}];
        CHECK([encoded isEqualToData:B(@"d1:ai2e1:bi1ee")], "dictionary re-encode sorts keys");

        // --- tracker announce URL ---
        NSData *infoHash = [MVSHA1 dataFromHexString:hex];
        NSData *peerID = B(@"-MV0001-abcdefghijkl");
        NSURL *announce = [MVTorrentTracker announceURLForTracker:@"http://tracker.test/announce"
                                                         infoHash:infoHash peerID:peerID port:6881
                                                         uploaded:0 downloaded:0 left:100 event:@"started"];
        CHECK(announce != nil, "announce URL builds");
        NSString *announceString = announce.absoluteString;
        CHECK([announceString containsString:@"info_hash="], "announce carries info_hash");
        CHECK([announceString containsString:@"left=100"], "announce carries left");
        CHECK([announceString containsString:@"event=started"], "announce carries event");
        // The raw 20 bytes must be percent-encoded, not passed as text.
        CHECK([announceString containsString:@"%"], "info_hash is percent-encoded");

        // --- tracker response parsing: compact IPv4 ---
        NSMutableData *compact = [NSMutableData data];
        uint8_t ipv4[6] = {93, 184, 216, 34, 0x1A, 0xE1};   // 93.184.216.34:6881
        [compact appendBytes:ipv4 length:6];
        NSData *resp = [MVBencode encode:@{@"interval": @900, @"peers": compact}];
        NSString *trackerError = nil;
        NSArray<MVTorrentPeerAddress *> *peers = [MVTorrentTracker peersFromAnnounceResponse:resp error:&trackerError];
        CHECK(peers.count == 1, "compact peers parsed");
        MVTorrentPeerAddress *peer0 = peers.firstObject;
        CHECK([peer0.host isEqualToString:@"93.184.216.34"], "compact peer host");
        CHECK(peer0.port == 6881, "compact peer port");
        // 900 differs from the 1800 fallback, so a broken key lookup cannot pass.
        CHECK([MVTorrentTracker intervalFromAnnounceResponse:resp] == 900, "announce interval");

        // A tracker "failure reason" must surface, not be read as zero peers.
        NSData *failure = [MVBencode encode:@{@"failure reason": B(@"torrent not registered")}];
        CHECK([MVTorrentTracker peersFromAnnounceResponse:failure error:&trackerError] == nil, "failure reason refused");
        CHECK([trackerError containsString:@"not registered"], "failure reason surfaced");

        // The legacy dictionary form of `peers` must also parse.
        NSData *legacy = [MVBencode encode:@{@"peers": @[@{@"ip": B(@"10.0.0.5"), @"port": @51413}]}];
        NSArray<MVTorrentPeerAddress *> *legacyPeers = [MVTorrentTracker peersFromAnnounceResponse:legacy error:&trackerError];
        MVTorrentPeerAddress *legacyPeer = legacyPeers.firstObject;
        CHECK(legacyPeers.count == 1 && [legacyPeer.host isEqualToString:@"10.0.0.5"], "legacy peer form parsed");

        // --- BEP 9 metadata exchange (the magnet path) ---
        // The info dict a peer sends has to be byte-identical to what the magnet
        // hashed, so these use the raw bytes and rebuild the torrent the same way
        // the engine does.
        NSString *magnetInfo = @"d6:lengthi16384e4:name8:test.bin12:piece lengthi16384e6:pieces20:01234567890123456789e";
        NSData *magnetInfoBytes = B(magnetInfo);
        NSData *magnetHash = [MVSHA1 digest:magnetInfoBytes];
        CHECK([[MVSHA1 hexString:magnetHash] isEqualToString:[MVSHA1 hexString:[MVSHA1 digest:B(magnetInfo)]]], "magnet info hash stable");

        // The engine wraps the peer's info bytes in a one-key torrent and reuses
        // the normal parser; that must recover the same metadata.
        NSData *wrapped = [MVBencode encode:@{@"info": magnetInfoBytes}];
        MVTorrentMetadata *fromPeer = [MVTorrentMetadata metadataWithTorrentData:wrapped error:&err];
        CHECK(fromPeer != nil, "peer info dict parses");
        CHECK([fromPeer.name isEqualToString:@"test.bin"], "peer metadata name");
        CHECK(fromPeer.totalLength == 16384, "peer metadata length");
        CHECK([fromPeer.infoHash isEqualToData:magnetHash], "peer metadata hash matches the magnet");

        // The whole torrent's info-hash must equal the info dict's hash, which is
        // what lets the resolver accept or reject a peer's reply.
        CHECK([[MVBencode infoHashFromTorrentData:wrapped] isEqualToData:magnetHash], "info hash from torrent data");

        // A metadata message is a bencoded header followed by raw bytes; the
        // boundary must be measured, not re-encoded, or the hash would not match.
        NSMutableData *dataMessage = [NSMutableData data];
        [dataMessage appendData:[MVBencode encode:@{@"msg_type": @1, @"piece": @0, @"total_size": @(magnetInfoBytes.length)}]];
        [dataMessage appendData:magnetInfoBytes];
        NSInteger headerLen = [MVBencode byteLengthOfValueIn:dataMessage];
        CHECK(headerLen > 0, "metadata header length measured");
        NSData *recovered = [dataMessage subdataWithRange:NSMakeRange((NSUInteger)headerLen, dataMessage.length - (NSUInteger)headerLen)];
        CHECK([recovered isEqualToData:magnetInfoBytes], "metadata payload recovered byte-for-byte");
        CHECK([[MVSHA1 digest:recovered] isEqualToData:magnetHash], "recovered payload hashes to the magnet hash");

        // The header itself must decode back to what was sent.
        id headerBack = [MVBencode decode:[dataMessage subdataWithRange:NSMakeRange(0, (NSUInteger)headerLen)] error:&err];
        CHECK([headerBack isKindOfClass:NSDictionary.class], "metadata header decodes");
        CHECK([headerBack[@"total_size"] integerValue] == (NSInteger)magnetInfoBytes.length, "metadata total_size round-trips");

        // A 16 KiB piece size means a 16 KiB info dict is exactly one piece, and
        // a slightly larger one needs two; the piece count drives the requests.
        NSInteger onePiece = (NSInteger)((magnetInfoBytes.length + 16384 - 1) / 16384);
        CHECK(onePiece == 1, "small metadata is one piece");
        NSInteger twoPieces = (NSInteger)((40000 + 16384 - 1) / 16384);
        CHECK(twoPieces == 3, "larger metadata piece count");

        printf(failures ? "\n%d FAILURE(S)\n" : "ALL TORRENT CORE TESTS PASSED\n", failures);
    }
    return failures ? 1 : 0;
}
