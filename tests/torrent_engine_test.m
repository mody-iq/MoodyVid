// Deterministic tests for BEP 9 peer selection and block request ownership.
#import <Foundation/Foundation.h>
#import "MVTorrentDownloader.h"
#import "MVTorrentMetadata.h"
#import "MVTorrentPeer.h"
#import "MVTorrentPolicy.h"
#import "MVBencode.h"
#import "MVSHA1.h"
#import "MVPaths.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#import <objc/runtime.h>
#include <stdio.h>

@interface MVTaskStore (TestFixtures)
+ (void)setTestTasks:(NSArray *)tasks;
@end
@interface MVDownloadStore (TestFixtures)
+ (void)setTestRecords:(NSArray *)records;
@end

static NSString *fixtureTorrentDirectory;
@interface MVPaths (TorrentTestDirectory)
+ (NSString *)test_torrentDirectoryForCategory:(NSString *)category;
@end
@implementation MVPaths (TorrentTestDirectory)
+ (NSString *)test_torrentDirectoryForCategory:(NSString *)category { (void)category; return fixtureTorrentDirectory; }
@end

static int failures = 0;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

// These objects are private to the engine; expose only the seams exercised here.
@interface MVTorrentJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) MVTorrentMetadata *metadata;
@property (nonatomic, strong) NSMutableArray *peers;
@property (nonatomic, strong) NSMutableArray *pieces;
@property (nonatomic, strong) NSMutableIndexSet *openPieces;
@property (nonatomic, strong) NSMutableDictionary *inFlightBlocks;
@property (nonatomic, strong) NSMutableDictionary *metadataPieces;
@property (nonatomic, weak) MVTorrentPeer *metadataPeer;
@property (nonatomic) NSInteger metadataSize;
- (void)markBlockInFlight:(MVTorrentBlock *)block onPeer:(MVTorrentPeer *)peer;
@end

@interface MVTorrentDownloader (Tests)
- (void)requestMetadataFromPeerForJob:(MVTorrentJob *)job;
- (MVTorrentBlock *)nextBlockForPeer:(MVTorrentPeer *)peer inJob:(MVTorrentJob *)job;
- (void)peer:(MVTorrentPeer *)peer didReceiveExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload;
- (void)peer:(MVTorrentPeer *)peer didReceiveBlock:(MVTorrentBlock *)block data:(NSData *)data;
- (void)peer:(MVTorrentPeer *)peer didLoseBlock:(MVTorrentBlock *)block;
@end

@interface TestTorrentDownloader : MVTorrentDownloader
@property (nonatomic, strong) MVTorrentMetadata *resolved;
@end
@implementation TestTorrentDownloader
- (void)prepareJob:(MVTorrentJob *)job metadata:(MVTorrentMetadata *)metadata { (void)job; self.resolved = metadata; }
@end

@interface FakePeer : MVTorrentPeer
@property (nonatomic, strong) NSMutableArray<NSNumber *> *requests;
@property (nonatomic, strong) NSIndexSet *testAvailability;
@property (nonatomic) BOOL testUnchoked;
@property (nonatomic) BOOL stopped;
@end
@implementation FakePeer
- (instancetype)init {
    NSData *bytes = [NSData dataWithBytes:"01234567890123456789" length:20];
    id<MVTorrentPeerDelegate> unusedDelegate = (id<MVTorrentPeerDelegate>)[NSObject new];
    if ((self = [super initWithHost:@"test" port:1 infoHash:bytes peerID:bytes pieceCount:1 delegate:unusedDelegate])) {
        _requests = [NSMutableArray array];
    }
    return self;
}
- (BOOL)connected { return !self.stopped; }
- (BOOL)unchoked { return self.testUnchoked; }
- (NSIndexSet *)availablePieces { return self.testAvailability ?: [NSIndexSet indexSet]; }
- (BOOL)extendedHandshakeReceived { return YES; }
- (NSDictionary *)extendedHandshake { return @{@"m": @{@"ut_metadata": @1}}; }
- (void)sendMetadataRequestForPiece:(NSInteger)piece { [self.requests addObject:@(piece)]; }
- (void)stop { self.stopped = YES; }
@end

static NSData *Message(NSDictionary *header, NSData *body) {
    NSMutableData *data = [[MVBencode encode:header] mutableCopy];
    if (body) [data appendData:body];
    return data;
}

static MVTorrentJob *Job(TestTorrentDownloader *engine, NSString *identifier, NSData *hash) {
    MVTorrentJob *job = [NSClassFromString(@"MVTorrentJob") new];
    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = identifier;
    task.url = @"magnet:?test";
    job.task = task;
    MVTorrentMetadata *placeholder = [MVTorrentMetadata new];
    placeholder.infoHash = hash;
    placeholder.trackers = @[];
    placeholder.files = @[];
    placeholder.pieceHashes = [NSData data];
    job.metadata = placeholder;
    job.metadataPieces = [NSMutableDictionary dictionary];
    NSMutableDictionary *jobs = [engine valueForKey:@"jobs"];
    jobs[identifier] = job;
    return job;
}

static void AddPeer(MVTorrentJob *job, FakePeer *peer) {
    peer.jobIdentifier = job.task.identifier;
    [job.peers addObject:peer];
}

static void DrainMainQueue(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
    CHECK(done, "main queue drained");
}

static void TestTorrentCleanup(TestTorrentDownloader *engine) {
    fixtureTorrentDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:fixtureTorrentDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    Method actual = class_getClassMethod(MVPaths.class, @selector(directoryForCategory:));
    Method fake = class_getClassMethod(MVPaths.class, @selector(test_torrentDirectoryForCategory:));
    method_exchangeImplementations(actual, fake);
    dispatch_queue_t engineQueue = [engine valueForKey:@"queue"];
    [MVDownloadStore setTestRecords:@[]];
    for (NSInteger mode = 0; mode < 4; mode++) {
        NSString *folder = [fixtureTorrentDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"folder%ld", (long)mode]];
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *file = [folder stringByAppendingPathComponent:@"file"];
        [@"data" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        MVDownloadTask *task = [MVDownloadTask new];
        task.identifier = [NSString stringWithFormat:@"cleanup-%ld", (long)mode];
        task.path = file;
        task.state = MVTaskStateCancelled;
        [MVTaskStore setTestTasks:@[task]];
        [engine cancelTask:task deletingFiles:mode != 3];
        // Ensure peer teardown finished while main-queue cleanup remains pending.
        dispatch_sync(engineQueue, ^{});
        if (mode == 0) {
            MVDownloadTask *other = [MVDownloadTask new];
            other.identifier = @"later-reference";
            other.path = file;
            [MVTaskStore setTestTasks:@[task, other]];
        } else if (mode == 2) {
            task.state = MVTaskStateRunning; // the same row was restarted
        }
        DrainMainQueue();
        BOOL exists = [fm fileExistsAtPath:file];
        CHECK(exists == (mode != 1), "torrent deletion rechecks late references, restarts and history-only removal");
    }
    [MVTaskStore setTestTasks:@[]];
    method_exchangeImplementations(actual, fake);
    [fm removeItemAtPath:fixtureTorrentDirectory error:nil];
}

int main(void) {
    @autoreleasepool {
        TestTorrentDownloader *engine = [TestTorrentDownloader new];
        NSData *zeroHash = [NSMutableData dataWithLength:20];
        MVTorrentJob *job = Job(engine, @"reject", zeroHash);
        FakePeer *first = [FakePeer new], *second = [FakePeer new];
        AddPeer(job, first); AddPeer(job, second);
        [engine requestMetadataFromPeerForJob:job];
        CHECK(first.requests.count == 1 && job.metadataPeer == first, "first metadata request sent");
        NSData *reject = Message(@{@"msg_type": @2, @"piece": @0}, nil);
        [engine peer:second didReceiveExtendedMessage:1 payload:reject];
        CHECK(job.metadataPeer == first && second.requests.count == 0, "unsolicited rejection cannot cancel another peer");
        [engine peer:first didReceiveExtendedMessage:2 payload:reject];
        CHECK(job.metadataPeer == first, "unadvertised extension id is ignored");
        [engine peer:first didReceiveExtendedMessage:1 payload:reject];
        CHECK(first.stopped && second.requests.count == 1 && job.metadataPeer == second,
              "rejection retires the peer and tries the next one");
        NSData *oversized = Message(@{@"msg_type": @1, @"piece": @0,
                                       @"total_size": @(MV_TORRENT_MAX_METADATA_BYTES + 1)},
                                     [NSData dataWithBytes:"x" length:1]);
        [engine peer:second didReceiveExtendedMessage:1 payload:oversized];
        CHECK(second.stopped && job.metadataSize == 0 && job.metadataPieces.count == 0,
              "oversized peer metadata is rejected before assembly");

        NSData *body = [NSData dataWithBytes:"z" length:1];
        NSData *info = [MVBencode encode:@{@"name": @"blob", @"length": @1, @"piece length": @1,
                                          @"pieces": [MVSHA1 digest:body]}];
        job = Job(engine, @"valid", [MVSHA1 digest:info]);
        FakePeer *validPeer = [FakePeer new];
        AddPeer(job, validPeer);
        [engine requestMetadataFromPeerForJob:job];
        NSData *message = Message(@{@"msg_type": @1, @"piece": @0, @"total_size": @(info.length)}, info);
        [engine peer:validPeer didReceiveExtendedMessage:1 payload:message];
        CHECK(engine.resolved && [engine.resolved.infoHash isEqualToData:[MVSHA1 digest:info]] &&
              engine.resolved.totalLength == 1, "valid metadata is hash checked and handed to the engine");

        job = Job(engine, @"blocks", zeroHash);
        job.metadataPieces = nil;
        FakePeer *owner = [FakePeer new];
        AddPeer(job, owner);
        id piece = [NSClassFromString(@"MVTorrentPiece") new];
        [piece setValue:@0 forKey:@"index"];
        [piece setValue:@3 forKey:@"length"];
        [piece setValue:[NSMutableData dataWithLength:3] forKey:@"buffer"];
        [job.pieces addObject:piece];
        MVTorrentBlock *old = [MVTorrentBlock blockWithIndex:0 begin:0 length:3];
        MVTorrentBlock *replacement = [MVTorrentBlock blockWithIndex:0 begin:0 length:3];
        [job markBlockInFlight:replacement onPeer:owner];
        [engine peer:owner didLoseBlock:old];
        [engine peer:owner didReceiveBlock:old data:[NSData dataWithBytes:"abc" length:3]];
        id current = job.inFlightBlocks[@"0:0"];
        CHECK(current && [current valueForKey:@"block"] == replacement &&
              [[piece valueForKey:@"receivedBegins"] count] == 0,
              "late same-peer callbacks cannot release or fill a replacement request");

        // A full bounded window containing partial pieces from a departed peer
        // must not prevent a different peer from opening its available piece.
        job = Job(engine, @"window", zeroHash);
        job.metadataPieces = nil;
        job.metadata.pieceLength = 64LL * 1024 * 1024; // one open slot
        id stranded = [NSClassFromString(@"MVTorrentPiece") new];
        [stranded setValue:@0 forKey:@"index"];
        [stranded setValue:@32768 forKey:@"length"];
        [stranded setValue:[NSMutableData dataWithLength:32768] forKey:@"buffer"];
        [[stranded valueForKey:@"receivedBegins"] addObject:@0];
        [job.pieces addObject:stranded];
        [job.openPieces addIndex:0];
        id available = [NSClassFromString(@"MVTorrentPiece") new];
        [available setValue:@1 forKey:@"index"];
        [available setValue:@32768 forKey:@"length"];
        [job.pieces addObject:available];
        FakePeer *oldOwner = [FakePeer new], *newOwner = [FakePeer new];
        oldOwner.testUnchoked = YES;
        oldOwner.testAvailability = [NSIndexSet indexSetWithIndex:0];
        newOwner.testUnchoked = YES;
        newOwner.testAvailability = [NSIndexSet indexSetWithIndex:1];
        AddPeer(job, oldOwner); AddPeer(job, newOwner);
        CHECK(![engine nextBlockForPeer:newOwner inJob:job] &&
              [[stranded valueForKey:@"receivedBegins"] count] == 1,
              "a partial piece is retained while a usable peer can continue it");
        oldOwner.stopped = YES;
        MVTorrentBlock *next = [engine nextBlockForPeer:newOwner inJob:job];
        CHECK(next.index == 1 && [[stranded valueForKey:@"receivedBegins"] count] == 0 &&
              ![stranded valueForKey:@"buffer"] && [job.openPieces containsIndex:1],
              "stranded partial data is discarded to make forward progress");
        TestTorrentCleanup(engine);
        if (!failures) puts("torrent metadata, scheduling and cleanup ownership: OK");
    }
    return failures ? 1 : 0;
}
