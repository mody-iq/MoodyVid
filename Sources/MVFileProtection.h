#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@class MVDownloadTask, MVDownloadRecord;

/// Conservative ownership checks for saved downloads and native partials.
/// Snapshot the stores on the main thread; the returned strings are immutable.
@interface MVFileProtection : NSObject
+ (NSArray<NSString *> *)pathsExcludingTask:(nullable MVDownloadTask *)task
                                   record:(nullable MVDownloadRecord *)record;

/// Includes parent/child and symlink overlap, plus partial-file suffixes such as
/// .part0, .seg1 and .joining-… derived from another saved temp path.
+ (BOOL)path:(nullable NSString *)path conflictsWithPaths:(NSArray<NSString *> *)paths;

/// Part bases are hidden files under the app's downloads directory. A symlinked
/// base or existing derived path is not safe to reuse for writing.
+ (BOOL)isSafePartialBase:(nullable NSString *)base;

/// Reject symlinks, directories and multiply linked files as write targets.
+ (BOOL)isSafePartialItemAtPath:(NSString *)path;

/// Remove just this item when no protected reference overlaps it. Returns YES
/// if it is absent or removed, and NO if protected or deletion failed.
+ (BOOL)removeItemAtPath:(nullable NSString *)path protecting:(NSArray<NSString *> *)paths;
/// As above, but never recursively removes a directory named like a partial.
+ (BOOL)removePartialItemAtPath:(NSString *)path protecting:(NSArray<NSString *> *)paths;
@end
NS_ASSUME_NONNULL_END
