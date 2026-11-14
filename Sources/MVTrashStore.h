#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const MVTrashDidChangeNotification;

/// Recoverable, opt-in file removal. Only regular single-link files beneath the
/// downloads root can be moved; directories, links and protected paths cannot.
/// Trash has no expiry and is never emptied automatically.
@interface MVTrashStore : NSObject
+ (instancetype)shared;
- (instancetype)initWithRoot:(NSString *)root trash:(NSString *)trash;
- (NSArray<NSDictionary *> *)entries;
- (BOOL)moveToTrash:(NSString *)path protecting:(NSArray<NSString *> *)protectedPaths error:(NSString *_Nullable *_Nullable)error;
/// Never overwrites an existing destination. Returns the restored path.
- (nullable NSString *)restore:(NSString *)identifier protecting:(NSArray<NSString *> *)protectedPaths error:(NSString *_Nullable *_Nullable)error;
/// Permanent deletion, for an explicit user confirmation only.
- (BOOL)deletePermanently:(NSString *)identifier error:(NSString *_Nullable *_Nullable)error;
@end

/// Snapshot on the main thread: all resumable partials and any unfinished
/// output are protected, including private workspaces used by Python.
@interface MVStorageProtection : NSObject
+ (NSArray<NSString *> *)protectedPaths;
/// After a successful move, remove completed history rows for this exact path.
/// Restoring a file returns the file itself, not the removed history rows.
/// Call on the main thread, just like the download stores.
+ (void)forgetCompletedRecordsAtPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
