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
/// Only HTTP(S) trackers are used; UDP trackers and the DHT are not spoken, and
/// a magnet link (which needs the BEP 9 metadata exchange) is reported as a
/// later phase rather than pretended to work.
@interface MVTorrentDownloader : NSObject

+ (instancetype)shared;

/// Global speed cap in bytes/second; 0 is unlimited. Kept for parity with the
/// other engines so the manager's setting applies everywhere.
@property (nonatomic) long long speedLimit;

- (BOOL)isRunningTask:(MVDownloadTask *)task;

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^)(MVDownloadTask *task))progress
         finished:(void (^)(MVDownloadTask *task))finished
           failed:(void (^)(MVDownloadTask *task, NSString *message))failed;

- (void)pauseTask:(MVDownloadTask *)task;
- (void)cancelTask:(MVDownloadTask *)task;

/// Deletes the files a torrent wrote (the folder it owns).
+ (void)removePartFilesForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
