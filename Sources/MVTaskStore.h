#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted whenever the task list changes (add, update, remove). The Downloads
/// list listens to this one notification for every engine.
extern NSString *const MVTaskStoreDidChangeNotification;

/// The single source of truth for downloads, whatever engine produced them.
///
/// Persisted as one JSON file in Application Support, written atomically. A
/// corrupt or unreadable file is reset instead of crashing the app: a lost
/// history is annoying, a crash loop is not survivable.
///
/// All access is on the main thread; the file write is marshalled to a serial
/// queue so a large list never blocks the UI.
@interface MVTaskStore : NSObject

+ (instancetype)shared;

/// Newest first, as the Downloads list shows them.
@property (nonatomic, readonly) NSArray<MVDownloadTask *> *tasks;

/// Inserts a task at the top (and persists). Returns the task.
- (MVDownloadTask *)add:(MVDownloadTask *)task;

/// Persists a change and posts the change notification. Called by the engines
/// and the manager after mutating a task.
- (void)update:(MVDownloadTask *)task;

- (void)remove:(MVDownloadTask *)task;

/// The task with this identifier, or nil.
- (nullable MVDownloadTask *)taskWithIdentifier:(NSString *)identifier;

/// The most recent task for a URL, or nil. Used to skip duplicates.
- (nullable MVDownloadTask *)taskWithURL:(NSString *)url;

/// Moves the task to the top of the list (used when a duplicate URL is added).
- (void)moveToTop:(MVDownloadTask *)task;

- (NSArray<MVDownloadTask *> *)activeTasks;
- (NSArray<MVDownloadTask *> *)finishedTasks;

/// Deletes finished records whose file no longer exists, then persists.
- (void)pruneMissingFiles;

/// Removes every finished task (and its file when `deleteFiles`).
- (void)removeFinishedTasksDeletingFiles:(BOOL)deleteFiles;

- (void)save;

@end

NS_ASSUME_NONNULL_END
