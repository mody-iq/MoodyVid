#import <Foundation/Foundation.h>
#import "MVDownloadRow.h"

NS_ASSUME_NONNULL_BEGIN

/// The verbs the UI offers on a download, in one place.
///
/// A row can belong to either engine (the yt-dlp records or the manager's
/// tasks), so every caller would otherwise repeat the same `if (kind == ...)`
/// branch. Routing it through here keeps the card list, the Home strip and the
/// details sheet consistent and means a new engine only touches this file.
@interface MVDownloadActions : NSObject

+ (void)pauseRow:(MVDownloadRow *)row;
+ (void)resumeRow:(MVDownloadRow *)row;
/// Stops the row. `deleteFile` also removes the partial/finished file.
+ (void)cancelRow:(MVDownloadRow *)row deleteFile:(BOOL)deleteFile;
/// Removes a finished row from the list, optionally deleting its file.
+ (void)removeRow:(MVDownloadRow *)row deleteFile:(BOOL)deleteFile;
/// Re-queues a failed row.
+ (void)retryRow:(MVDownloadRow *)row;

@end

NS_ASSUME_NONNULL_END
