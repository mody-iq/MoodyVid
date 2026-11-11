#import "MVTorrentDownloader.h"
#import "MVTaskStore.h"
#import "MVTorrentMetadata.h"
#import "MVTorrentStorage.h"
#import "MVTorrentPeer.h"
#import "MVTorrentTracker.h"
#import "MVMagnet.h"
#import "MVSHA1.h"
#import "MVBencode.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"

#include <stdlib.h>

/// The peer-wire block size (BEP 3): 16 KiB.
static const NSInteger kBlockSize = 16384;
/// How many peers to keep connected at once. More helps on a thin swarm, but
/// every peer is a socket and a thread, so it is capped.
static const NSInteger kMaxPeers = 40;
/// Blocks this client may ask one peer for before it must answer.
static const NSInteger kBlocksInFlightPerPeer = 16;
/// How long a single torrent/tracker request may take.
static const NSTimeInterval kRequestTimeout = 30;
/// A hard cap on how many peer addresses the engine remembers.
static const NSUInteger kMaxKnownPeers = 400;
/// How many pieces may hold a buffer at once. Blocks are handed out only for
/// pieces already open, plus this many new ones, so a multi-gigabyte torrent
/// does not reserve its whole size in memory while it downloads.
static const NSInteger kMaxOpenPieces = 96;
/// The size of one BEP 9 metadata piece. The spec fixes it at 16 KiB.
static const NSInteger kMetadataPieceSize = 16384;
/// How long to wait for a peer to answer a metadata request before trying
/// another one. A magnet has no other peer source when it has no trackers, so
/// giving up on the first silent peer would strand the download.
static const NSTimeInterval kMetadataTimeout = 20;

#pragma mark - Piece

typedef NS_ENUM(NSInteger, MVPieceState) {
    MVPieceStateMissing = 0,
    MVPieceStateComplete,
};

/// One piece, its buffer, and which of its blocks have arrived. Held only on the
/// engine queue, so it needs no locking.
@interface MVTorrentPiece : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) long long length;
@property (nonatomic) MVPieceState state;
/// Allocated on the first block that arrives, released once the piece is
/// written, so a large torrent does not reserve its whole size in memory.
@property (nonatomic, strong, nullable) NSMutableData *buffer;
/// The `begin` offsets of the blocks that have landed.
@property (nonatomic, strong) NSMutableSet<NSNumber *> *receivedBegins;
@property (nonatomic) NSInteger totalBlocks;
@end
@implementation MVTorrentPiece
- (instancetype)init {
    if ((self = [super init])) _receivedBegins = [NSMutableSet set];
    return self;
}
@end

#pragma mark - Job

/// One running torrent. All fields are touched only on the engine's serial
/// queue, so no locking is needed here.
@interface MVTorrentJob : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (nonatomic, strong) MVTorrentMetadata *metadata;
@property (nonatomic, strong) MVTorrentStorage *storage;
@property (nonatomic, strong) NSMutableArray<MVTorrentPiece *> *pieces;
/// Pieces whose buffer is allocated (being filled). Blocks are only handed out
/// for these, plus a bounded number of new ones, which keeps memory flat.
@property (nonatomic, strong) NSMutableIndexSet *openPieces;
/// The next piece index to open. Monotonic, so the window slides forward in one
/// pass instead of rescanning the whole piece table for every block.
@property (nonatomic) NSInteger nextPieceToOpen;
@property (nonatomic, strong) NSMutableArray<MVTorrentPeer *> *peers;
@property (nonatomic, strong) NSMutableArray<MVTorrentPeerAddress *> *knownPeers;
@property (nonatomic, strong) NSMutableSet<NSString *> *connectedKeys;
/// Blocks requested but not yet received, keyed "index:begin", mapped to the
/// peer that owes them.
@property (nonatomic, strong) NSMutableDictionary<NSString *, MVTorrentPeer *> *inFlightBlocks;
@property (nonatomic) long long doneBytes;
/// YES once the tracker has ever given us a peer, so a temporary empty swarm
/// does not fail a download that was working.
@property (nonatomic) BOOL hadPeers;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finishing;
@property (nonatomic, strong) NSData *peerID;
/// BEP 9: the metadata pieces a peer has sent while a magnet link is being
/// resolved, keyed by piece number. nil once the metadata is known.
@property (nonatomic, strong, nullable) NSMutableDictionary<NSNumber *, NSData *> *metadataPieces;
/// The metadata's total length, learned from the piece 0 reply. 0 until then.
@property (nonatomic) NSInteger metadataSize;
/// The peer currently serving the metadata, so a silent one can be replaced.
@property (nonatomic, weak, nullable) MVTorrentPeer *metadataPeer;
/// YES once a tracker announce has been sent for this job, so resolving a magnet
/// (which announces to find a metadata peer) is not announced again by
/// `prepareJob` once the real metadata arrives.
@property (nonatomic) BOOL hasAnnounced;
/// Bumped on every metadata request. A late timeout only fires when it is still
/// the current attempt, so a peer that answered is not then dropped.
@property (nonatomic) NSInteger metadataAttempt;
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@end
@implementation MVTorrentJob
- (instancetype)init {
    if ((self = [super init])) {
        _pieces = [NSMutableArray array];
        _openPieces = [NSMutableIndexSet indexSet];
        _peers = [NSMutableArray array];
        _knownPeers = [NSMutableArray array];
        _connectedKeys = [NSMutableSet set];
        _inFlightBlocks = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

/// The in-flight bookkeeping, all on the engine queue.
@implementation MVTorrentJob (Blocks)

- (NSString *)keyForBlock:(MVTorrentBlock *)block {
    return [NSString stringWithFormat:@"%ld:%ld", (long)block.index, (long)block.begin];
}

- (BOOL)isBlockInFlight:(MVTorrentBlock *)block {
    return self.inFlightBlocks[[self keyForBlock:block]] != nil;
}

- (void)markBlockInFlight:(MVTorrentBlock *)block onPeer:(MVTorrentPeer *)peer {
    self.inFlightBlocks[[self keyForBlock:block]] = peer;
}

- (void)clearBlockInFlight:(MVTorrentBlock *)block {
    [self.inFlightBlocks removeObjectForKey:[self keyForBlock:block]];
}

/// Drops every block a peer owed, so a peer that vanished frees its work.
- (void)releaseBlocksForPeer:(MVTorrentPeer *)peer {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSString *key in self.inFlightBlocks) {
        if (self.inFlightBlocks[key] == peer) [keys addObject:key];
    }
    [self.inFlightBlocks removeObjectsForKeys:keys];
}

/// Drops every in-flight block of a piece, used when it fails its hash.
- (void)releaseBlocksForPiece:(MVTorrentPiece *)piece {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSString *prefix = [NSString stringWithFormat:@"%ld:", (long)piece.index];
    for (NSString *key in self.inFlightBlocks) {
        if ([key hasPrefix:prefix]) [keys addObject:key];
    }
    [self.inFlightBlocks removeObjectsForKeys:keys];
}

@end

#pragma mark - Engine

@interface MVTorrentDownloader () <MVTorrentPeerDelegate>
@end

@implementation MVTorrentDownloader {
    NSMutableDictionary<NSString *, MVTorrentJob *> *_jobs;
    dispatch_queue_t _queue;
    dispatch_queue_t _networkQueue;
}

+ (instancetype)shared {
    static MVTorrentDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVTorrentDownloader new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableDictionary dictionary];
        // One serial queue owns every job's state; peers deliver their callbacks
        // here, so piece bookkeeping is never touched from two threads.
        _queue = dispatch_queue_create("com.mody.moodyvid.torrent", DISPATCH_QUEUE_SERIAL);
        _networkQueue = dispatch_queue_create("com.mody.moodyvid.torrent.net", DISPATCH_QUEUE_CONCURRENT);
        _speedLimit = 0;
    }
    return self;
}

- (BOOL)isRunningTask:(MVDownloadTask *)task {
    if (!task.identifier.length) return NO;
    __block BOOL running = NO;
    dispatch_sync(_queue, ^{
        MVTorrentJob *job = self->_jobs[task.identifier];
        running = job != nil && !job.paused;
    });
    return running;
}

#pragma mark - Start / pause / cancel

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^)(MVDownloadTask *))progress
         finished:(void (^)(MVDownloadTask *))finished
           failed:(void (^)(MVDownloadTask *, NSString *))failed {
    MVTorrentJob *job = [MVTorrentJob new];
    job.task = task;
    job.progressBlock = progress;
    job.finishedBlock = finished;
    job.failedBlock = failed;
    job.peerID = [self generatePeerID];
    dispatch_async(_queue, ^{
        self->_jobs[task.identifier] = job;
        [self loadTorrentForJob:job];
    });
}

- (void)pauseTask:(MVDownloadTask *)task {
    dispatch_async(_queue, ^{
        MVTorrentJob *job = self->_jobs[task.identifier];
        if (!job) return;
        job.paused = YES;
        [self stopAllPeersForJob:job];
        [self->_jobs removeObjectForKey:task.identifier];
        MVLogInfo(@"torrent: paused %@ at %lld bytes", task.title, job.doneBytes);
    });
}

- (void)cancelTask:(MVDownloadTask *)task {
    dispatch_async(_queue, ^{
        MVTorrentJob *job = self->_jobs[task.identifier];
        if (!job) return;
        job.cancelled = YES;
        [self stopAllPeersForJob:job];
        [self->_jobs removeObjectForKey:task.identifier];
    });
}

/// A random 20-byte peer id with the conventional client prefix.
- (NSData *)generatePeerID {
    NSMutableData *peerID = [NSMutableData dataWithData:[@"-MV0001-" dataUsingEncoding:NSUTF8StringEncoding]];
    uint8_t random[12];
    for (int i = 0; i < 12; i++) random[i] = (uint8_t)(arc4random_uniform(256));
    [peerID appendBytes:random length:12];
    return peerID;
}

#pragma mark - Metadata (BEP 9)

/// Starts resolving a magnet link.
///
/// A magnet carries only the info-hash, so the piece table has to be fetched
/// from a peer (BEP 9). The job gets a placeholder metadata (name and trackers,
/// no pieces) and the normal announce path is reused: the peers it finds are the
/// ones that can serve the metadata. `metadataPieces` marks the job as still
/// resolving, which is what makes the delegate route the reply to the assembler.
- (void)resolveMagnetForJob:(MVTorrentJob *)job {
    MVMagnet *magnet = [MVMagnet magnetWithURL:job.task.url];
    if (!magnet) {
        [self failJob:job message:[MVLang t:@"This magnet link has no usable info-hash"]];
        return;
    }
    if (magnet.isV2) {
        // A v2 (BEP 52) hash names a different metadata format that this engine
        // does not speak; say so instead of resolving to a torrent we cannot use.
        [self failJob:job message:[MVLang t:@"This magnet uses a v2 hash, which is not supported yet"]];
        return;
    }

    job.metadata = [MVTorrentMetadata metadataWithMagnet:magnet];
    job.metadataPieces = [NSMutableDictionary dictionary];
    job.metadataSize = 0;
    job.task.title = magnet.displayName.length ? magnet.displayName : magnet.infoHashHex;
    [self reportProgressForJob:job];

    NSArray<NSString *> *trackers = magnet.trackers;
    if (!trackers.count) {
        [self failJob:job message:[MVLang t:@"This magnet has no tracker, so no peer can be found"]];
        return;
    }
    [self announceForJob:job event:@"started"];
}

/// Asks a peer for the metadata, once its extended handshake says it can serve
/// it. Picks the peer the engine is not already waiting on.
- (void)requestMetadataFromPeerForJob:(MVTorrentJob *)job {
    if (!job.metadataPieces) return;             // already resolved
    if (job.metadataPeer) return;                // a request is outstanding
    NSInteger piece = [self firstMissingMetadataPieceForJob:job];
    if (piece < 0) return;
    for (MVTorrentPeer *peer in job.peers) {
        if (!peer.connected) continue;
        if (!peer.extendedHandshakeReceived) continue;
        NSDictionary *m = peer.extendedHandshake[@"m"];
        if (![m isKindOfClass:NSDictionary.class]) continue;
        NSNumber *metadataID = m[@"ut_metadata"];
        if (![metadataID isKindOfClass:NSNumber.class]) continue;
        [self askPeer:peer forMetadataPiece:piece inJob:job];
        return;
    }
}

/// The lowest metadata piece still missing, or -1 when they are all in. Piece 0
/// is special: it carries the total size, so it must be asked for first and its
/// absence means the size is not yet known.
- (NSInteger)firstMissingMetadataPieceForJob:(MVTorrentJob *)job {
    if (!job.metadataPieces[@(0)]) return 0;
    if (!job.metadataSize) return -1;
    NSInteger count = (job.metadataSize + kMetadataPieceSize - 1) / kMetadataPieceSize;
    for (NSInteger i = 1; i < count; i++) {
        if (!job.metadataPieces[@(i)]) return i;
    }
    return -1;
}

/// Sends one metadata request and arms its deadline. The attempt counter makes
/// the deadline a no-op once this peer has answered or another peer was tried,
/// so a peer that is serving pieces is never dropped by a stale timer.
- (void)askPeer:(MVTorrentPeer *)peer forMetadataPiece:(NSInteger)piece inJob:(MVTorrentJob *)job {
    job.metadataPeer = peer;
    job.metadataAttempt += 1;
    NSInteger attempt = job.metadataAttempt;
    MVLogInfo(@"torrent: asking %@:%ld for metadata piece %ld", peer.host, (long)peer.port, (long)piece);
    [peer sendMetadataRequestForPiece:piece];

    __weak typeof(self) weakSelf = self;
    __weak MVTorrentPeer *weakPeer = peer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMetadataTimeout * NSEC_PER_SEC)),
                   _queue, ^{
        typeof(self) self_ = weakSelf;
        if (!self_ || !job.metadataPieces) return;
        if (job.metadataAttempt != attempt) return;
        if (job.metadataPeer != weakPeer) return;
        // The peer accepted the request but went quiet; try someone else.
        job.metadataPeer = nil;
        [self_ requestMetadataFromPeerForJob:job];
    });
}

/// A `ut_metadata` reply. Piece 0 carries the total size; pieces are collected
/// until they are all in, then the metadata is rebuilt and handed to the normal
/// torrent path.
- (void)handleMetadataMessage:(NSData *)payload forPeer:(MVTorrentPeer *)peer {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job || job.cancelled || job.paused || job.finishing) return;
    if (!job.metadataPieces) return;

    // The message is a bencoded header followed by the raw metadata bytes; the
    // header's own length says where the payload starts.
    NSInteger headerLength = [MVBencode byteLengthOfValueIn:payload];
    if (headerLength <= 0 || (NSUInteger)headerLength > payload.length) return;
    NSString *error = nil;
    id header = [MVBencode decode:[payload subdataWithRange:NSMakeRange(0, (NSUInteger)headerLength)]
                            error:&error];
    if (![header isKindOfClass:NSDictionary.class]) return;
    NSNumber *msgType = header[@"msg_type"];
    NSNumber *pieceNumber = header[@"piece"];
    if (![pieceNumber isKindOfClass:NSNumber.class]) return;
    if (![msgType isKindOfClass:NSNumber.class]) return;

    if (msgType.integerValue == 2) {
        // "reject": this peer will not serve the metadata; try another.
        job.metadataAttempt += 1;
        job.metadataPeer = nil;
        [self requestMetadataFromPeerForJob:job];
        return;
    }
    if (msgType.integerValue != 1) return;       // only "data" carries the info dict

    NSData *body = [payload subdataWithRange:NSMakeRange((NSUInteger)headerLength,
                                                         payload.length - (NSUInteger)headerLength)];
    NSNumber *totalSize = header[@"total_size"];
    if ([totalSize isKindOfClass:NSNumber.class] && totalSize.integerValue > 0) {
        job.metadataSize = totalSize.integerValue;
    }
    if (!job.metadataSize) return;               // a piece before the size is useless
    // Ignore a piece that would extend past the announced size, so a peer cannot
    // make the assembler allocate a huge buffer.
    if (pieceNumber.integerValue < 0) return;
    if ((long long)pieceNumber.integerValue * kMetadataPieceSize + body.length > job.metadataSize) return;
    job.metadataPieces[pieceNumber] = body;

    NSInteger next = [self firstMissingMetadataPieceForJob:job];
    if (next < 0) {
        [self finishMetadataForJob:job];
        return;
    }
    // The peer that just answered is still serving us, so ask it for the next
    // piece rather than starting over with a new peer.
    MVTorrentPeer *current = job.metadataPeer;
    if (current) {
        [self askPeer:current forMetadataPiece:next inJob:job];
    } else {
        [self requestMetadataFromPeerForJob:job];
    }
}

/// Assembles the pieces, checks them against the magnet's info-hash, and turns
/// them into the piece table the rest of the engine already understands.
- (void)finishMetadataForJob:(MVTorrentJob *)job {
    NSInteger pieceCount = (job.metadataSize + kMetadataPieceSize - 1) / kMetadataPieceSize;
    NSMutableData *infoBytes = [NSMutableData dataWithCapacity:(NSUInteger)job.metadataSize];
    for (NSInteger i = 0; i < pieceCount; i++) {
        NSData *piece = job.metadataPieces[@(i)];
        if (!piece) return;
        [infoBytes appendData:piece];
    }
    job.metadataPieces = nil;
    job.metadataPeer = nil;
    job.metadataAttempt += 1;

    // The hash is the only proof that this is the torrent the link named; a peer
    // could otherwise hand us anything, and the row would happily download
    // unrelated content under the name from the link.
    NSData *expected = job.metadata.infoHash;
    NSData *actual = [MVSHA1 digest:infoBytes];
    if (![actual isEqualToData:expected]) {
        MVLogWarn(@"torrent: magnet metadata hash mismatch (%@ != %@)",
                  [MVSHA1 hexString:actual], [MVSHA1 hexString:expected]);
        [self failJob:job message:[MVLang t:@"A peer sent metadata that does not match this magnet"]];
        return;
    }

    NSData *torrentBytes = [MVBencode torrentDataWithInfoDict:infoBytes];
    NSString *decodeError = nil;
    MVTorrentMetadata *metadata = [MVTorrentMetadata metadataWithTorrentData:torrentBytes
                                                                       error:&decodeError];
    if (!metadata) {
        [self failJob:job message:decodeError ?: [MVLang t:@"This torrent file could not be read"]];
        return;
    }
    // A magnet's own trackers must survive the swap: the peer-supplied info dict
    // usually has none, and they are the only way to find more peers.
    metadata.trackers = job.metadata.trackers;
    MVLogInfo(@"torrent: magnet resolved to \"%@\" (%lld bytes)", metadata.name, metadata.totalLength);
    [self prepareJob:job metadata:metadata];
}

#pragma mark - Metadata

- (void)loadTorrentForJob:(MVTorrentJob *)job {
    NSString *url = job.task.url;
    if ([MVMagnet isMagnetURL:url]) {
        [self resolveMagnetForJob:job];
        return;
    }

    dispatch_async(_networkQueue, ^{
        NSDictionary *headers = [MVMediaProbe headersForURL:url referer:job.task.referer];
        NSError *error = nil;
        NSData *data = [self syncGet:url headers:headers error:&error];
        if (!data.length) {
            NSString *message = error.localizedDescription ?: [MVLang t:@"Could not open the torrent"];
            dispatch_async(self->_queue, ^{ [self failJob:job message:message]; });
            return;
        }
        NSString *decodeError = nil;
        MVTorrentMetadata *metadata = [MVTorrentMetadata metadataWithTorrentData:data error:&decodeError];
        if (!metadata) {
            dispatch_async(self->_queue, ^{
                [self failJob:job message:[MVLang t:@"This torrent file could not be read"]];
            });
            return;
        }
        dispatch_async(self->_queue, ^{ [self prepareJob:job metadata:metadata]; });
    });
}

/// Lays out the files and the piece table once the metadata is known.
- (void)prepareJob:(MVTorrentJob *)job metadata:(MVTorrentMetadata *)metadata {
    if (job.cancelled || job.paused) return;
    job.metadata = metadata;

    // Peers found while resolving a magnet were built when the piece count was
    // still unknown, so they cannot report or serve pieces. Their addresses stay
    // in knownPeers, so dropping them loses nothing: they are reconnected below
    // with the real geometry.
    if (job.peers.count) [self stopAllPeersForJob:job];

    // Each torrent owns a folder named after it, so two torrents never collide
    // and a cancel can delete exactly what it wrote.
    NSString *base = [MVPaths directoryForCategory:@"Torrents"];
    NSString *folder = [MVPaths sanitizeFilename:metadata.name.length ? metadata.name : metadata.infoHashHex];
    NSString *root = [base stringByAppendingPathComponent:folder];
    job.storage = [[MVTorrentStorage alloc] initWithMetadata:metadata root:root];

    NSString *prepareError = nil;
    if (![job.storage prepare:&prepareError]) {
        [self failJob:job message:prepareError ?: [MVLang t:@"Could not create the torrent files"]];
        return;
    }
    job.task.path = job.storage.outputPath;
    job.task.totalBytes = metadata.totalLength;

    // The row title comes from the page title (the .torrent link's page), so
    // every torrent from one page shares it. The torrent's own name is what
    // identifies it, so use that instead.
    if (metadata.name.length) job.task.title = metadata.name;
    dispatch_async(dispatch_get_main_queue(), ^{ [MVTaskStore.shared update:job.task]; });

    // The piece table. The last piece is shorter than the piece length.
    long long total = metadata.totalLength;
    for (NSInteger i = 0; i < metadata.pieceCount; i++) {
        long long offset = (long long)i * metadata.pieceLength;
        long long length = MIN(metadata.pieceLength, total - offset);
        MVTorrentPiece *piece = [MVTorrentPiece new];
        piece.index = i;
        piece.length = length;
        piece.state = MVPieceStateMissing;
        piece.totalBlocks = (NSInteger)((length + kBlockSize - 1) / kBlockSize);
        // The buffer is allocated on the first block that arrives and released
        // once the piece is written, so memory stays bounded by the pieces
        // actually in flight — not by the size of the whole torrent.
        [job.pieces addObject:piece];
    }

    // Pieces already on disk (a resumed download) are verified and skipped, so
    // pausing and resuming does not re-fetch what was already written.
    for (MVTorrentPiece *piece in job.pieces) {
        if (![job.storage verifyPiece:piece.index]) continue;
        piece.state = MVPieceStateComplete;
        job.doneBytes += piece.length;
    }
    job.task.doneBytes = job.doneBytes;
    if (job.doneBytes >= metadata.totalLength) {
        [self finishJob:job];
        return;
    }

    job.task.phase = [MVLang t:@"Finding peers"];
    [self reportProgressForJob:job];

    // Reconnect the addresses already known (a resolved magnet keeps them), then
    // announce. A magnet has already announced by now, so it is not announced
    // twice.
    [self connectMorePeersForJob:job];
    [self fillPipelinesForJob:job];
    if (!job.hasAnnounced) [self announceForJob:job event:@"started"];
}

#pragma mark - Trackers

/// A short, human-readable reason naming the tracker host and what went wrong,
/// so a failed row says why (unreachable vs. returned no peers) instead of the
/// generic "no peers" for every case.
- (NSString *)trackerFailureFor:(NSString *)tracker reason:(NSString *)reason {
    NSString *host = [NSURL URLWithString:tracker].host;
    if (!host.length) host = tracker;
    return [NSString stringWithFormat:@"%@: %@", host, reason];
}

- (void)announceForJob:(MVTorrentJob *)job event:(NSString *)event {
    job.hasAnnounced = YES;
    NSArray<NSString *> *trackers = job.metadata.trackers;
    if (!trackers.count) {
        [self failJob:job message:[MVLang t:@"This torrent has no HTTP tracker to find peers"]];
        return;
    }
    MVTorrentJob *currentJob = job;
    dispatch_async(_networkQueue, ^{
        BOOL gotAny = NO;
        NSTimeInterval interval = 0;
        NSString *lastFailure = nil;
        for (NSString *tracker in trackers) {
            if (currentJob.cancelled || currentJob.paused) return;
            NSURL *announce = [MVTorrentTracker announceURLForTracker:tracker
                                                             infoHash:currentJob.metadata.infoHash
                                                               peerID:currentJob.peerID
                                                                 port:6881
                                                             uploaded:0
                                                           downloaded:currentJob.doneBytes
                                                                 left:MAX(0, currentJob.metadata.totalLength - currentJob.doneBytes)
                                                                event:event];
            if (!announce) continue;
            NSError *error = nil;
            NSData *response = [self syncGet:announce.absoluteString headers:nil error:&error];
            if (!response.length) {
                lastFailure = [self trackerFailureFor:tracker reason:[MVLang t:@"Could not be reached"]];
                MVLogWarn(@"torrent: tracker %@ failed: %@", tracker, error.localizedDescription ?: @"no response");
                continue;
            }
            NSString *trackerError = nil;
            NSArray<MVTorrentPeerAddress *> *peers = [MVTorrentTracker peersFromAnnounceResponse:response error:&trackerError];
            if (!peers.count) {
                // A tracker that answered but returned no peers is a different
                // situation from one that could not be reached; report which.
                lastFailure = [self trackerFailureFor:tracker
                                               reason:trackerError.length ? trackerError : [MVLang t:@"Returned no peers"]];
                MVLogWarn(@"torrent: tracker %@ returned no peers (%@)", tracker, trackerError ?: @"none");
                continue;
            }
            gotAny = YES;
            currentJob.hadPeers = YES;
            if (interval <= 0) interval = [MVTorrentTracker intervalFromAnnounceResponse:response];
            dispatch_async(self->_queue, ^{ [self addPeers:peers toJob:currentJob]; });
        }
        if (!gotAny && !currentJob.hadPeers) {
            NSString *reason = lastFailure ?: [MVLang t:@"No peers were found for this torrent"];
            dispatch_async(self->_queue, ^{
                if (currentJob.peers.count == 0 && !currentJob.finishing && !currentJob.cancelled) {
                    [self failJob:currentJob message:reason];
                }
            });
        } else {
            // Re-announce on the tracker's interval so a swarm that was empty or
            // whose peers died is re-queried, instead of the download sitting at
            // 0% forever.
            [self scheduleNextAnnounceForJob:currentJob interval:interval];
        }
    });
}

/// Queues the next announce. The delay keeps the tracker from being hammered,
/// and the job is re-checked on the engine queue so a paused, cancelled or
/// finished torrent is not announced. The job is held weakly so a cancelled
/// torrent is not kept alive until the timer fires.
- (void)scheduleNextAnnounceForJob:(MVTorrentJob *)job interval:(NSTimeInterval)interval {
    if (interval <= 0) interval = 1800;
    NSString *identifier = job.task.identifier;
    __weak MVTorrentJob *weakJob = job;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), _queue, ^{
        MVTorrentJob *current = weakJob;
        if (!current || self->_jobs[identifier] != current) return;
        if (current.finishing || current.cancelled || current.paused) return;
        [self announceForJob:current event:nil];
    });
}

#pragma mark - Peers

- (void)addPeers:(NSArray<MVTorrentPeerAddress *> *)addresses toJob:(MVTorrentJob *)job {
    if (job.cancelled || job.paused || job.finishing) return;
    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (MVTorrentPeerAddress *address in job.knownPeers) [known addObject:address.key];
    for (MVTorrentPeerAddress *address in addresses) {
        if (job.knownPeers.count >= kMaxKnownPeers) break;
        if ([known containsObject:address.key]) continue;
        [known addObject:address.key];
        [job.knownPeers addObject:address];
    }
    [self connectMorePeersForJob:job];
}

- (void)connectMorePeersForJob:(MVTorrentJob *)job {
    if (job.cancelled || job.paused || job.finishing) return;
    for (MVTorrentPeerAddress *address in job.knownPeers) {
        if (job.peers.count >= (NSUInteger)kMaxPeers) break;
        if ([job.connectedKeys containsObject:address.key]) continue;
        [job.connectedKeys addObject:address.key];
        MVTorrentPeer *peer = [[MVTorrentPeer alloc] initWithHost:address.host
                                                            port:address.port
                                                        infoHash:job.metadata.infoHash
                                                         peerID:job.peerID
                                                      pieceCount:job.metadata.pieceCount
                                                        delegate:self];
        peer.maxInFlight = kBlocksInFlightPerPeer;
        // Deliver callbacks here, on the engine queue, so all piece state is
        // touched from one thread.
        [peer setCallbackQueue:_queue];
        peer.jobIdentifier = job.task.identifier;
        [job.peers addObject:peer];
        [peer start];
    }
}

- (void)stopAllPeersForJob:(MVTorrentJob *)job {
    for (MVTorrentPeer *peer in job.peers) [peer stop];
    [job.peers removeAllObjects];
    [job.connectedKeys removeAllObjects];
    [job.inFlightBlocks removeAllObjects];
}

#pragma mark - Piece scheduling

/// Opens one more piece for filling, choosing the next piece the peer actually
/// holds so a window is never wasted on pieces it cannot serve. The cursor is a
/// hint; when it runs out the scan restarts from the beginning, so a piece only
/// a later peer has is still found.
- (nullable MVTorrentPiece *)openNextPieceForJob:(MVTorrentJob *)job available:(NSIndexSet *)available {
    if ((NSInteger)job.openPieces.count >= kMaxOpenPieces) return nil;
    NSInteger count = (NSInteger)job.pieces.count;
    for (NSInteger pass = 0; pass < 2; pass++) {
        NSInteger start = (pass == 0) ? job.nextPieceToOpen : 0;
        NSInteger end = (pass == 0) ? count : MIN(job.nextPieceToOpen, count);
        for (NSInteger i = start; i < end; i++) {
            MVTorrentPiece *piece = job.pieces[i];
            if (piece.state == MVPieceStateComplete || piece.buffer) continue;
            if (![available containsIndex:(NSUInteger)i]) continue;
            piece.buffer = [NSMutableData dataWithLength:(NSUInteger)piece.length];
            [job.openPieces addIndex:(NSUInteger)i];
            if (pass == 0) job.nextPieceToOpen = i + 1;
            return piece;
        }
    }
    return nil;
}

/// Frees the buffer of an open piece that has nothing to lose (no block has
/// arrived and none is in flight), so its slot can be reused. A piece with
/// partial data keeps its buffer — that work is worth keeping.
- (void)reapOpenPiecesForJob:(MVTorrentJob *)job {
    if (!job.openPieces.count) return;
    // Pieces with an outstanding block, gathered in one pass over the in-flight
    // map, so this stays linear instead of scanning it once per open piece.
    NSMutableIndexSet *busy = [NSMutableIndexSet indexSet];
    for (NSString *key in job.inFlightBlocks) {
        NSInteger index = key.integerValue;   // keys are "index:begin"
        if (index >= 0) [busy addIndex:(NSUInteger)index];
    }
    NSMutableArray<NSNumber *> *idle = [NSMutableArray array];
    for (NSUInteger index = [job.openPieces firstIndex];
         index != NSNotFound;
         index = [job.openPieces indexGreaterThanIndex:index]) {
        MVTorrentPiece *piece = job.pieces[index];
        if (piece.state == MVPieceStateComplete) continue;
        if (piece.receivedBegins.count) continue;
        if ([busy containsIndex:index]) continue;
        [idle addObject:@(index)];
    }
    for (NSNumber *index in idle) {
        job.pieces[index.unsignedIntegerValue].buffer = nil;
        [job.openPieces removeIndex:index.unsignedIntegerValue];
    }
}

/// The first missing block of an open piece the peer holds, or nil.
- (nullable MVTorrentBlock *)blockFromOpenPiecesForJob:(MVTorrentJob *)job available:(NSIndexSet *)available {
    // Walk only the open window (bounded), not every piece of the torrent.
    // Iterated with the index-set cursor so this stays cheap on GNUstep too.
    for (NSUInteger index = [job.openPieces firstIndex];
         index != NSNotFound;
         index = [job.openPieces indexGreaterThanIndex:index]) {
        if (![available containsIndex:index]) continue;
        MVTorrentPiece *piece = job.pieces[index];
        if (piece.state == MVPieceStateComplete || !piece.buffer) continue;
        for (NSInteger begin = 0; begin < piece.length; begin += kBlockSize) {
            NSNumber *beginKey = @(begin);
            if ([piece.receivedBegins containsObject:beginKey]) continue;
            NSInteger length = (NSInteger)MIN((long long)kBlockSize, piece.length - begin);
            MVTorrentBlock *block = [MVTorrentBlock blockWithIndex:piece.index begin:begin length:length];
            if ([job isBlockInFlight:block]) continue;
            return block;
        }
    }
    return nil;
}

/// The next block this peer should fetch. Availability-aware: a peer is only
/// asked for a piece it holds, and never for a block already in flight
/// elsewhere, so no request is wasted.
- (nullable MVTorrentBlock *)nextBlockForPeer:(MVTorrentPeer *)peer inJob:(MVTorrentJob *)job {
    if (!peer.unchoked || job.finishing) return nil;
    NSIndexSet *available = peer.availablePieces;
    if (!available.count) return nil;

    MVTorrentBlock *block = [self blockFromOpenPiecesForJob:job available:available];
    while (!block) {
        if ((NSInteger)job.openPieces.count >= kMaxOpenPieces) {
            // The window is full; reuse a slot only if some open piece has
            // nothing in flight and no data yet.
            [self reapOpenPiecesForJob:job];
            if ((NSInteger)job.openPieces.count >= kMaxOpenPieces) break;
        }
        MVTorrentPiece *opened = [self openNextPieceForJob:job available:available];
        if (!opened) break;
        block = [self blockFromOpenPiecesForJob:job available:available];
    }
    return block;
}

/// Gives every connected, unchoked peer another block to fetch.
- (void)fillPipelinesForJob:(MVTorrentJob *)job {
    if (job.cancelled || job.paused || job.finishing) return;
    for (MVTorrentPeer *peer in job.peers) {
        while (peer.unchoked && peer.blocksInFlight < peer.maxInFlight) {
            MVTorrentBlock *block = [self nextBlockForPeer:peer inJob:job];
            if (!block) break;
            [job markBlockInFlight:block onPeer:peer];
            [peer requestBlock:block];
        }
    }
}

#pragma mark - Delegate (called on the engine queue)

- (void)peerDidConnect:(MVTorrentPeer *)peer {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job || job.cancelled || job.paused) return;
    MVLogInfo(@"torrent: peer %@:%ld connected", peer.host, (long)peer.port);
    // Report now so a connected swarm clears the "Finding peers" phase at once
    // instead of waiting for the first piece to finish.
    [self reportProgressForJob:job];
    // A magnet has no piece table yet, so there is nothing to fetch until the
    // metadata arrives; the handshake that follows this callback starts that.
    if (job.metadataPieces) return;
    [self fillPipelinesForJob:job];
}

- (void)peerDidChangeAvailability:(MVTorrentPeer *)peer {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job || job.cancelled || job.paused) return;
    // A choked peer will not answer, so hand back whatever it still owes.
    if (!peer.unchoked) [job releaseBlocksForPeer:peer];
    [self fillPipelinesForJob:job];
}

- (void)peer:(MVTorrentPeer *)peer didReceiveBlock:(MVTorrentBlock *)block data:(NSData *)data {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job || job.cancelled || job.paused) return;
    if (block.index < 0 || block.index >= (NSInteger)job.pieces.count) return;

    MVTorrentPiece *piece = job.pieces[block.index];
    [job clearBlockInFlight:block];
    if (piece.state == MVPieceStateComplete) {
        [self fillPipelinesForJob:job];
        return;
    }
    if (block.begin < 0 || block.begin + (NSInteger)data.length > piece.length) return;
    // A block can only arrive for a piece we opened, but allocate defensively so
    // a stray message cannot write into a nil buffer.
    if (!piece.buffer) {
        piece.buffer = [NSMutableData dataWithLength:(NSUInteger)piece.length];
        [job.openPieces addIndex:(NSUInteger)piece.index];
    }

    [piece.buffer replaceBytesInRange:NSMakeRange((NSUInteger)block.begin, data.length) withBytes:data.bytes];
    [piece.receivedBegins addObject:@(block.begin)];

    if ((NSInteger)piece.receivedBegins.count >= piece.totalBlocks) {
        [self completePiece:piece inJob:job];
    } else {
        [self fillPipelinesForJob:job];
    }
}

- (void)peer:(MVTorrentPeer *)peer didLoseBlock:(MVTorrentBlock *)block {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job) return;
    [job clearBlockInFlight:block];
    [self fillPipelinesForJob:job];
}

- (void)peer:(MVTorrentPeer *)peer didReceiveExtendedMessage:(NSInteger)extendedID payload:(NSData *)payload {
    if (extendedID == 0) {
        // The peer's extended handshake just arrived, so this peer can now be
        // asked for a magnet's metadata.
        [self requestMetadataFromPeerForJob:_jobs[peer.jobIdentifier]];
        return;
    }
    [self handleMetadataMessage:payload forPeer:peer];
}

- (void)peerDidDisconnect:(MVTorrentPeer *)peer reason:(NSString *)reason {
    MVTorrentJob *job = _jobs[peer.jobIdentifier];
    if (!job) return;
    MVLogInfo(@"torrent: peer %@:%ld left: %@", peer.host, (long)peer.port, reason ?: @"closed");
    [job.peers removeObjectIdenticalTo:peer];
    if (job.cancelled || job.paused) return;

    // The peer's in-flight blocks are lost; free them so another peer can take
    // them, and connect a replacement if one is known.
    [job releaseBlocksForPeer:peer];
    [self connectMorePeersForJob:job];
    [self fillPipelinesForJob:job];
}

/// Verifies a finished piece and, when it is correct, writes it to disk and
/// tells the swarm. A bad piece is thrown away and retried from another peer.
- (void)completePiece:(MVTorrentPiece *)piece inJob:(MVTorrentJob *)job {
    NSData *expected = [job.metadata hashForPiece:piece.index];
    if (![MVSHA1 data:piece.buffer matchesDigest:expected]) {
        MVLogWarn(@"torrent: piece %ld failed its hash, retrying", (long)piece.index);
        [piece.receivedBegins removeAllObjects];
        [piece.buffer resetBytesInRange:NSMakeRange(0, piece.buffer.length)];
        [job releaseBlocksForPiece:piece];
        [self fillPipelinesForJob:job];
        return;
    }

    NSString *writeError = nil;
    long long offset = (long long)piece.index * job.metadata.pieceLength;
    if (![job.storage writeData:piece.buffer atOffset:offset error:&writeError]) {
        [self failJob:job message:writeError ?: [MVLang t:@"Could not write the torrent to disk"]];
        return;
    }
    piece.state = MVPieceStateComplete;
    // The bytes are on disk and verified, so the buffer is no longer needed.
    piece.buffer = nil;
    [job.openPieces removeIndex:(NSUInteger)piece.index];
    job.doneBytes += piece.length;
    job.task.doneBytes = job.doneBytes;

    for (MVTorrentPeer *peer in job.peers) [peer sendHave:piece.index];
    [self reportProgressForJob:job];

    if (job.doneBytes >= job.metadata.totalLength) {
        [self finishJob:job];
        return;
    }
    [self fillPipelinesForJob:job];
}

#pragma mark - Progress / completion

- (void)reportProgressForJob:(MVTorrentJob *)job {
    MVDownloadTask *task = job.task;
    // "Finding peers" is only true until the swarm actually connects. Deriving
    // the phase from the live peer count clears it the moment peers arrive, so
    // the row stops showing a stale "Finding peers" over a download that is
    // clearly moving bytes.
    if (job.peers.count == 0) {
        task.phase = [MVLang t:@"Finding peers"];
    } else {
        task.phase = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.progressBlock) job.progressBlock(task);
    });
}

- (void)finishJob:(MVTorrentJob *)job {
    if (job.finishing) return;
    job.finishing = YES;
    [self stopAllPeersForJob:job];

    MVDownloadTask *task = job.task;
    task.doneBytes = job.metadata.totalLength;
    task.totalBytes = job.metadata.totalLength;
    task.path = job.storage.outputPath;
    task.phase = nil;
    MVLogInfo(@"torrent: finished %@", task.title);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.finishedBlock) job.finishedBlock(task);
    });
    [_jobs removeObjectForKey:task.identifier];
}

- (void)failJob:(MVTorrentJob *)job message:(NSString *)message {
    if (job.finishing) return;
    job.finishing = YES;
    [self stopAllPeersForJob:job];

    MVDownloadTask *task = job.task;
    MVLogError(@"torrent: failed %@: %@", task.title, message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.failedBlock) job.failedBlock(task, message);
    });
    [_jobs removeObjectForKey:task.identifier];
}

#pragma mark - Networking

/// A blocking GET, matching the other engines: the work already runs on the
/// network queue, and the torrent/tracker requests are few and one-shot.
- (nullable NSData *)syncGet:(NSString *)url headers:(NSDictionary<NSString *, NSString *> *)headers error:(NSError **)error {
    NSURL *target = [NSURL URLWithString:url];
    if (!target) {
        if (error) *error = [NSError errorWithDomain:@"MVTorrent" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Could not open the torrent"]}];
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:30];
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (err) resultError = err;
        else if (http && http.statusCode >= 400) resultError = [NSError errorWithDomain:@"MVTorrent"
                                                                                  code:http.statusCode
                                                                              userInfo:@{NSLocalizedDescriptionKey:
                                                                                             [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}];
        else result = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRequestTimeout * NSEC_PER_SEC)));
    if (!result && !resultError) {
        resultError = [NSError errorWithDomain:@"MVTorrent" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [MVLang t:@"Connection timed out"]}];
    }
    if (error) *error = resultError;
    return result;
}

#pragma mark - Cleanup

+ (void)removePartFilesForTask:(MVDownloadTask *)task {
    // The torrent owns exactly one folder under the Torrents category; the task's
    // path is either that folder (multi-file) or a file inside it (single file),
    // possibly nested in subfolders. Delete the first component under Torrents,
    // so everything the torrent wrote goes and nothing else does.
    if (!task.path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [MVPaths directoryForCategory:@"Torrents"];
    NSString *path = task.path;
    if (root.length && [path hasPrefix:root]) {
        NSString *rest = [path substringFromIndex:root.length];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            NSUInteger start = slash.location + 1;
            NSRange next = [rest rangeOfString:@"/" options:0 range:NSMakeRange(start, rest.length - start)];
            NSUInteger end = (next.location == NSNotFound) ? rest.length : next.location;
            path = [root stringByAppendingPathComponent:[rest substringWithRange:NSMakeRange(start, end - start)]];
        }
    }
    [fm removeItemAtPath:path error:nil];
}

@end
