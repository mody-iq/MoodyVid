#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// The BitTorrent engine (BEP 3, BEP 23).
///
/// It takes a task whose source is `MVTaskSourceTorrent` and whose URL is a
/// `.torrent` file, announces to the torrent's HTTP trackers, connects to the
/// peers it learns about, and downloads the file piece by piece — verifying each
/// piece's SHA-1 before it is written to disk, so a corrupt or hostile peer
/// cannot poison the file.
///
/// Only HTTP(S) trackers are used; UDP trackers and the DHT are not spoken.
/// Version 1 magnet links can fetch metadata from a peer via BEP 9; version 2
/// magnets and magnets without usable trackers are not supported.
@interface MVTorrentDownloader : NSObject

+ (instancetype)shared;

/// Reserved for a future torrent throttle; currently not enforced by peers.
@property (nonatomic) long long speedLimit;

- (BOOL)isRunningTask:(MVDownloadTask *)task;

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^)(MVDownloadTask *task))progress
         finished:(void (^)(MVDownloadTask *task))finished
           failed:(void (^)(MVDownloadTask *task, NSString *message))failed;

- (void)pauseTask:(MVDownloadTask *)task;
- (void)cancelTask:(MVDownloadTask *)task;
/// Call on the main thread. Deletion waits for peer writes to stop, then checks
/// current saved references and skips a task that has already been restarted.
- (void)cancelTask:(MVDownloadTask *)task deletingFiles:(BOOL)deleteFiles;

@end

NS_ASSUME_NONNULL_END
