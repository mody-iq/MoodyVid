#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Read-only analysis of the downloads root. Duplicates are confirmed by
/// SHA-256, never guessed from a filename or size. Work and result counts are
/// bounded; an incomplete scan is marked `limited`.
@interface MVStorageScanner : NSObject
- (instancetype)initWithRoot:(NSString *)root maximumFiles:(NSUInteger)maximumFiles hashBudget:(unsigned long long)hashBudget;
/// Run off the main thread with an immutable protected-path snapshot. `cancel`
/// may be called during long hashes. Returns large, duplicates, partials arrays.
- (NSDictionary *)scanProtecting:(NSArray<NSString *> *)protectedPaths cancelled:(BOOL (^_Nullable)(void))cancel;
@end

NS_ASSUME_NONNULL_END
