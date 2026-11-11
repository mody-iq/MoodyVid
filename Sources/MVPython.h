#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the embedded Python interpreter on its own serial queue.
@interface MVPython : NSObject

+ (instancetype)shared;

/// Starts the interpreter. Safe to call more than once.
- (void)start;

/// Calls module.function(*args), where every argument is a string and the function
/// returns a JSON object as a string. The completion runs on the main queue with the
/// parsed result, or with an error message.
- (void)call:(NSString *)module
    function:(NSString *)function
        args:(NSArray<NSString *> *)args
  completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;

/// Runs `module.function(*args)` on a background thread and returns the parsed
/// JSON result. The engine's own `_task` keyword argument carries `task`, so the
/// Python side can report progress and poll for cancellation while it works.
///
/// `completion` runs on the main queue.
- (void)call:(NSString *)module
    function:(NSString *)function
        args:(NSArray<NSString *> *)args
        task:(nullable NSString *)task
  completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;

/// Engine self-test results (yt-dlp version, JavaScriptCore status, ...). Filled in
/// once the interpreter has started; empty before that.
@property (nonatomic, readonly) NSDictionary *engineInfo;

/// Reports download progress for a task. Read from Python via `mvnative.progress`.
- (void)setProgress:(NSDictionary *)progress forTask:(NSString *)task;

/// Returns the last progress reported for a task (empty dictionary if none).
- (NSDictionary *)progressForTask:(NSString *)task;

/// Asks a task to stop. The Python side polls this and aborts.
- (void)cancelTask:(NSString *)task;
- (BOOL)isTaskCancelled:(NSString *)task;

/// Asks a task to pause. yt-dlp cannot be suspended, so the Python side aborts
/// the download and keeps the .part file; a resume continues from it.
- (void)pauseTask:(NSString *)task;
/// Clears the pause flag so a resumed task can run again.
- (void)resumePausedTask:(NSString *)task;
- (BOOL)isTaskPaused:(NSString *)task;
- (void)forgetTask:(NSString *)task;

@end

NS_ASSUME_NONNULL_END
