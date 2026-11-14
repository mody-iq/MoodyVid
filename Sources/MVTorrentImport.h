#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Private copies of user-selected .torrent metadata. A reference is an opaque
/// UUID, never a file:// path supplied by a document provider. Each copy is
/// owned by one task, so that task can resume after the picker URL expires.
@interface MVTorrentImport : NSObject
+ (instancetype)shared;
- (instancetype)initWithDirectory:(NSString *)directory;
+ (BOOL)isImportReference:(nullable NSString *)reference;
/// Reads at most 32 MiB and validates the torrent before persisting it.
/// Call off the main thread while a security-scoped file URL is accessible.
- (nullable NSString *)importFileURL:(NSURL *)url error:(NSString *_Nullable *_Nullable)error;
/// Returns the persisted bytes or nil if the reference/file is invalid.
- (nullable NSData *)dataForReference:(NSString *)reference;
/// Removes only a private import created by this store. Never deletes the
/// original file or the downloaded contents.
- (void)removeReference:(NSString *)reference;
@end

NS_ASSUME_NONNULL_END
