#import <Foundation/Foundation.h>
#import "MVDownloadStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Runs downloads through the embedded Python engine and keeps the shared
/// download store up to date while they run.
@interface MVDownloadEngine : NSObject

+ (instancetype)shared;

/// Starts a download and records it in the store. `quality` is one of
/// best / 720p / 480p / audio. `completion` runs on the main queue.
- (void)downloadURL:(NSString *)url
            quality:(NSString *)quality
         completion:(void (^)(NSString *_Nullable filePath, NSString *_Nullable error))completion;

/// Stops an in-progress download; its record is marked cancelled.
- (void)cancelDownload:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
