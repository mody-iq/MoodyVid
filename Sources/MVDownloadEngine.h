#import <Foundation/Foundation.h>
#import "MVDownloadStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Runs downloads through the embedded Python engine and keeps the shared
/// download store up to date while they run.
///
/// Downloads go through a small queue (two at a time) and each one holds a
/// background task assertion, so leaving the app or opening another screen does
/// not stop it. iOS still suspends us eventually, so the assertion is only extra
/// time, not a promise of unlimited background downloading.
@interface MVDownloadEngine : NSObject

+ (instancetype)shared;

/// Queues a download and records it in the store. `quality` is one of
/// best / 720p / 480p / audio. `completion` runs on the main queue.
- (void)downloadURL:(NSString *)url
            quality:(NSString *)quality
         completion:(void (^)(NSString *_Nullable filePath, NSString *_Nullable error))completion;

/// Stops a queued or running download; its record is marked cancelled.
- (void)cancelDownload:(NSString *)identifier;

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

@end

NS_ASSUME_NONNULL_END
