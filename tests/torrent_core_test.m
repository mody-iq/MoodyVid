// Offline tests for the torrent core (bencode, SHA-1, magnet, metadata,
// tracker). Build: see scripts/torrent-tests.sh — they run with the system
// clang and Foundation on macOS, so the piece/hash logic is proven before the
// device build without needing a real swarm.
#import <Foundation/Foundation.h>
#import "MVBencode.h"
#import "MVSHA1.h"
#import "MVMagnet.h"
#import "MVTorrentMetadata.h"
#import "MVTorrentImport.h"
#import "MVTorrentPolicy.h"
#import "MVTorrentStorage.h"
#import "MVTorrentTracker.h"
#import "MVPaths.h"
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } } while (0)
static NSData *B(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

static NSDictionary *File(NSArray<NSString *> *names, long long length, BOOL padding) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *name in names) [parts addObject:B(name)];
    NSMutableDictionary *file = [@{@"path": parts, @"length": @(length)} mutableCopy];
    if (padding) file[@"attr"] = B(@"p");
    return file;
}

static MVTorrentMetadata *Metadata(NSArray *files, NSData *contents, NSInteger pieceLength) {
    NSMutableData *hashes = [NSMutableData data];
    for (NSUInteger offset = 0; offset < contents.length; offset += (NSUInteger)pieceLength) {
        NSUInteger size = MIN((NSUInteger)pieceLength, contents.length - offset);
        [hashes appendData:[MVSHA1 digest:[contents subdataWithRange:NSMakeRange(offset, size)]]];
    }
    NSDictionary *info = @{@"name": B(@"root"), @"piece length": @(pieceLength),
                           @"pieces": hashes, @"files": files};
    return [MVTorrentMetadata metadataWithInfoDict:info infoHash:[MVSHA1 digest:B(@"torrent")] trackers:@[] error:nil];
}

static void testTorrentImport(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([fm createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil], "create import fixture directory");
    NSString *source = [temp stringByAppendingPathComponent:@"source.torrent"];
    NSString *cached = [temp stringByAppendingPathComponent:@"imports"];
    MVTorrentImport *store = [[MVTorrentImport alloc] initWithDirectory:cached];
    NSString *info = @"d6:lengthi16384e4:name8:test.bin12:piece lengthi16384e6:pieces20:01234567890123456789e";
    NSData *bytes = B([NSString stringWithFormat:@"d8:announce20:http://tracker.test/4:info%@e", info]);
    CHECK([bytes writeToFile:source atomically:YES], "write selected torrent fixture");
    NSString *error = nil;
    NSString *reference = [store importFileURL:[NSURL fileURLWithPath:source] error:&error];
    CHECK([MVTorrentImport isImportReference:reference], "valid torrent gets an opaque import reference");
    if (!reference) { [fm removeItemAtPath:temp error:nil]; return; }
    CHECK([[store dataForReference:reference] isEqualToData:bytes], "import is copied to private storage");
    CHECK([B(@"changed") writeToFile:source atomically:YES], "change original after import");
    CHECK([[store dataForReference:reference] isEqualToData:bytes], "private copy survives changes to the original");
    CHECK(![store importFileURL:[NSURL fileURLWithPath:source] error:&error], "malformed torrent rejected");
    CHECK(![store dataForReference:@"moodyvid-torrent:../../source"] &&
          ![MVTorrentImport isImportReference:@"moodyvid-torrent:../../source"], "path traversal reference rejected");
    NSString *link = [temp stringByAppendingPathComponent:@"link.torrent"];
    CHECK(symlink(source.fileSystemRepresentation, link.fileSystemRepresentation) == 0, "make selected symlink");
    CHECK(![store importFileURL:[NSURL fileURLWithPath:link] error:&error], "selected symlink is rejected");
    NSString *large = [temp stringByAppendingPathComponent:@"large.torrent"];
    int fd = open(large.fileSystemRepresentation, O_CREAT | O_WRONLY | O_EXCL, 0600);
    CHECK(fd >= 0 && ftruncate(fd, (off_t)(2 * MV_TORRENT_MAX_METADATA_BYTES + 1)) == 0, "create oversized sparse fixture");
    if (fd >= 0) close(fd);
    CHECK(![store importFileURL:[NSURL fileURLWithPath:large] error:&error], "oversized torrent rejected before reading");
    NSString *identifier = [reference substringFromIndex:[@"moodyvid-torrent:" length]];
    NSString *payload = [cached stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"torrent"]];
    NSString *temporary = [cached stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"tmp"]];
    CHECK(link(payload.fileSystemRepresentation, temporary.fileSystemRepresentation) == 0, "simulate interrupted atomic import");
    [store removeReference:reference];
    CHECK(![fm fileExistsAtPath:payload] && ![fm fileExistsAtPath:temporary] &&
          [[NSData dataWithContentsOfFile:source] isEqualToData:B(@"changed")],
          "removing import cleans its interrupted link and leaves original untouched");
    CHECK(symlink(source.fileSystemRepresentation, payload.fileSystemRepresentation) == 0, "replace cached file with symlink");
    CHECK(![store dataForReference:reference], "cached symlink is not followed");
    [store removeReference:reference];
    CHECK([[NSData dataWithContentsOfFile:source] isEqualToData:B(@"changed")], "cleanup never follows cached symlink");
    [fm removeItemAtPath:temp error:nil];
}

static void testStorage(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([fm createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil], "create temporary test folder");
    const unsigned char raw[] = {'a', 'b', 'c', 0, 0, 'd', 'e', 0, 0};
    NSData *bytes = [NSData dataWithBytes:raw length:sizeof(raw)];
    NSArray *files = @[File(@[@"dir", @"a"], 3, NO), File(@[@"pad"], 2, YES),
                       File(@[@"b"], 2, NO), File(@[@"tail"], 2, YES), File(@[@"empty"], 0, NO)];
    MVTorrentMetadata *meta = Metadata(files, bytes, 4);
    CHECK(meta != nil, "storage fixture metadata");
    NSString *root = [temp stringByAppendingPathComponent:@"torrent"];
    MVTorrentStorage *storage = [[MVTorrentStorage alloc] initWithMetadata:meta root:root];
    CHECK([storage prepare:nil], "prepare multi-file storage");
    CHECK([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"empty"]], "zero-length files are created");
    CHECK([storage writeData:bytes atOffset:0 error:nil], "write across files and trailing padding");
    CHECK([[storage readAtOffset:0 length:9 error:nil] isEqualToData:bytes], "read across files and padding");
    CHECK([[storage readAtOffset:3 length:1 error:nil] isEqualToData:[NSData dataWithBytes:raw + 3 length:1]],
          "a read wholly inside padding stops at the requested length");
    CHECK([[storage readAtOffset:7 length:2 error:nil] isEqualToData:[NSData dataWithBytes:raw + 7 length:2]],
          "trailing padding is readable");
    CHECK([storage verifyPiece:0] && [storage verifyPiece:1] && [storage verifyPiece:2], "every written piece verifies");
    CHECK(![storage writeData:B(@"x") atOffset:3 error:nil], "nonzero padding is refused");
    CHECK(![storage writeData:B(@"x") atOffset:9 error:nil] && ![storage readAtOffset:-1 length:1 error:nil] &&
          ![storage readAtOffset:8 length:2 error:nil] && ![storage readPiece:-1 error:nil], "storage rejects invalid ranges");

    NSArray *collision = @[File(@[@".same"], 1, NO), File(@[@"same"], 1, NO)];
    MVTorrentStorage *badLayout = [[MVTorrentStorage alloc] initWithMetadata:Metadata(collision, B(@"ab"), 2)
                                                                       root:[temp stringByAppendingPathComponent:@"collision"]];
    CHECK(![badLayout prepare:nil], "sanitized filename collision is rejected");
    NSArray *parentCollision = @[File(@[@"a"], 1, NO), File(@[@"A", @"b"], 1, NO)];
    badLayout = [[MVTorrentStorage alloc] initWithMetadata:Metadata(parentCollision, B(@"ab"), 2)
                                                      root:[temp stringByAppendingPathComponent:@"parent"]];
    CHECK(![badLayout prepare:nil], "case-folded file and directory collision is rejected");

    NSString *outside = [temp stringByAppendingPathComponent:@"outside"];
    NSString *symlinkRoot = [temp stringByAppendingPathComponent:@"links"];
    [fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:symlinkRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *sentinel = [outside stringByAppendingPathComponent:@"victim"];
    [B(@"keep") writeToFile:sentinel atomically:YES];
    NSString *dirLink = [symlinkRoot stringByAppendingPathComponent:@"dir"];
    CHECK(symlink(outside.fileSystemRepresentation, dirLink.fileSystemRepresentation) == 0, "create directory symlink");
    NSArray *links = @[File(@[@"dir", @"victim"], 1, NO)];
    MVTorrentStorage *unsafe = [[MVTorrentStorage alloc] initWithMetadata:Metadata(links, B(@"x"), 1) root:symlinkRoot];
    CHECK(![unsafe prepare:nil] && [[NSData dataWithContentsOfFile:sentinel] isEqualToData:B(@"keep")],
          "symlinked directory does not redirect torrent writes");
    CHECK([MVPaths path:dirLink overlapsPath:sentinel], "ownership checks resolve symlink descendants");
    CHECK([MVPaths path:outside overlapsPath:sentinel] && [MVPaths path:sentinel overlapsPath:outside],
          "ownership checks protect parent and child in both directions");
    CHECK(![MVPaths path:outside overlapsPath:[temp stringByAppendingPathComponent:@"outside-other"]],
          "ownership uses path boundaries");

    NSString *hardRoot = [temp stringByAppendingPathComponent:@"hard"];
    [fm createDirectoryAtPath:hardRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *hardTarget = [hardRoot stringByAppendingPathComponent:@"victim"];
    CHECK(link(sentinel.fileSystemRepresentation, hardTarget.fileSystemRepresentation) == 0, "create hard link");
    NSArray *hardFiles = @[File(@[@"victim"], 1, NO)];
    unsafe = [[MVTorrentStorage alloc] initWithMetadata:Metadata(hardFiles, B(@"x"), 1) root:hardRoot];
    CHECK(![unsafe prepare:nil] && [[NSData dataWithContentsOfFile:sentinel] isEqualToData:B(@"keep")],
          "hard-linked target is not truncated or overwritten");
    [fm removeItemAtPath:temp error:nil];
}

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
        CHECK([MVTorrentMetadata metadataWithTorrentData:B([torrent stringByAppendingString:@"junk"]) error:&err] == nil,
              "trailing torrent data refused");
        NSData *validHash = [MVSHA1 digest:B(@"hash")];
        NSMutableDictionary *badInfo = [@{@"name": B(@"root"), @"piece length": @4, @"pieces": B(@"01234567890123456789")} mutableCopy];
        badInfo[@"files"] = @[@{@"length": @1, @"path": B(@"not a list")}];
        CHECK(![MVTorrentMetadata metadataWithInfoDict:badInfo infoHash:validHash trackers:@[] error:&err], "non-list path refused");
        badInfo[@"files"] = @[File(@[@"..", @"outside"], 1, NO)];
        CHECK(![MVTorrentMetadata metadataWithInfoDict:badInfo infoHash:validHash trackers:@[] error:&err], "parent traversal refused");
        badInfo[@"files"] = @[File(@[@"a/b"], 1, NO)];
        CHECK(![MVTorrentMetadata metadataWithInfoDict:badInfo infoHash:validHash trackers:@[] error:&err], "embedded slash refused");
        badInfo[@"files"] = @[File(@[@"first"], LLONG_MAX, NO), File(@[@"second"], 1, NO)];
        CHECK(![MVTorrentMetadata metadataWithInfoDict:badInfo infoHash:validHash trackers:@[] error:&err], "file offset overflow refused");
        badInfo[@"files"] = @[File(@[@"a"], -1, NO)];
        CHECK(![MVTorrentMetadata metadataWithInfoDict:badInfo infoHash:validHash trackers:@[] error:&err], "negative file length refused");
        MVTorrentMetadata *empty = Metadata(@[File(@[@"empty"], 0, NO)], [NSData data], 4);
        CHECK(empty && empty.totalLength == 0 && empty.pieceCount == 0, "empty-file torrent geometry retained");

        // --- bencode round-trip and edge cases ---
        CHECK([[MVBencode decode:B(@"i42e") error:&err] longLongValue] == 42, "integer decode");
        CHECK([[MVBencode decode:B(@"4:spam") error:&err] isEqualToData:B(@"spam")], "string decode");
        CHECK([MVBencode decode:B(@"i-7e") error:&err] == nil, "negative integer refused");
        CHECK([MVBencode decode:B(@"i03e") error:&err] == nil, "leading-zero integer refused");
        CHECK([MVBencode decode:B(@"5:ab") error:&err] == nil, "truncated string refused");
        CHECK([MVBencode decode:[NSData data] error:&err] == nil, "empty data refused");
        CHECK(![MVBencode decode:B(@"i9223372036854775808e") error:&err], "integer overflow refused");
        CHECK(![MVBencode decode:B(@"18446744073709551616:") error:&err], "string length overflow refused");
        CHECK([MVBencode byteLengthOfValueIn:B(@"i999999999999999999999999999999999999999e")] == -1,
              "unbounded integer header refused");
        NSMutableString *deep = [NSMutableString stringWithString:@"d4:info"];
        for (NSInteger i = 0; i < 129; i++) [deep appendString:@"l"];
        [deep appendString:@"i0e"];
        for (NSInteger i = 0; i < 130; i++) [deep appendString:@"e"];
        CHECK(![MVBencode decode:B(deep) error:&err] && ![MVBencode rawValueForTopLevelKey:@"info" inData:B(deep)],
              "deeply nested data refused by decoder and raw scanner");
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
        // the normal parser; that must recover the same metadata. The dict is
        // appended raw, so the info-hash survives the wrap.
        NSData *wrapped = [MVBencode torrentDataWithInfoDict:magnetInfoBytes];
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

        testStorage();
        testTorrentImport();
        printf(failures ? "\n%d FAILURE(S)\n" : "ALL TORRENT CORE TESTS PASSED\n", failures);
    }
    return failures ? 1 : 0;
}
