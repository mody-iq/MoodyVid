#import <Foundation/Foundation.h>
#import "MVDownloadStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Runs downloads through the embedded Python engine and keeps the shared
/// download store up to date while they run.
///
/// Downloads go through a small queue (two at a time). While work is running,
/// the engine requests a silent-audio keep-alive and a background task assertion.
/// iOS may still suspend or terminate the app; on the next launch it resumes the
/// queue and yt-dlp may continue compatible task-owned .part files.
@interface MVDownloadEngine : NSObject

+ (instancetype)shared;

/// Queues a download and records it in the store. `quality` is one of
/// best / 720p / 480p / audio. `completion` runs on the main queue.
- (void)downloadURL:(NSString *)url
            quality:(NSString *)quality
         completion:(void (^_Nullable)(NSString *_Nullable filePath, NSString *_Nullable error))completion;

/// Stops a queued or running download; its record is marked cancelled.
- (void)cancelDownload:(NSString *)identifier;

/// Removes a record, first signalling any active Python call to stop. If a
/// result arrives after deletion, discard it only when deletion was requested.
- (void)removeDownload:(NSString *)identifier deleteFile:(BOOL)deleteFile;

/// Stops a running download but keeps its .part file, marking the record Paused
/// so it can be resumed later instead of restarting from zero.
- (void)pauseDownload:(NSString *)identifier;

/// Re-queues a paused record; yt-dlp may continue its compatible .part file.
- (void)resumeDownload:(NSString *)identifier;

/// Fetches the video's thumbnail and caches it as JPEG under the thumbs
/// folder; the store record is updated on success. Fails silently: a missing
/// thumbnail must never break a download.
- (void)setThumbnail:(NSString *)thumbURL forURL:(NSString *)url;

/// How many downloads are running right now.
- (NSUInteger)runningCount;

/// Copies a finished file into the Photos library. This is now an explicit
/// action from the video's menu: a download stays inside the app by default.
- (void)saveToPhotos:(NSString *)filePath
          completion:(void (^_Nullable)(NSString *_Nullable filePath, NSString *_Nullable error))completion;

/// Re-queues records that were still waiting or downloading when the app was
/// killed, so an interrupted download can resume where the source allows.
- (void)resumeInterrupted;

@end

NS_ASSUME_NONNULL_END
