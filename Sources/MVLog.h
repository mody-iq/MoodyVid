#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A rotating on-disk log.
///
/// The owner only has an iPhone, so a device-side log he can export from Settings
/// is the only way to diagnose a failure that only happens on the device. Every
/// line carries the "MoodyVid:" prefix so it can be filtered out of a system
/// crash log too.
///
/// Writes are asynchronous on one serial queue: a log call never blocks the
/// caller and never blocks the main thread. The file is capped and rotated once
/// so it cannot grow without bound.
@interface MVLog : NSObject

+ (instancetype)shared;

/// Appends one line. `level` is a short tag such as I / W / E.
+ (void)log:(NSString *)level format:(NSString *)format, ... NS_FORMAT_FUNCTION(2, 3);

/// Removes URLs and common credential fields from diagnostic text. File names
/// and other contextual details can remain, so the user should still choose
/// whom to share it with.
+ (NSString *)redactedText:(NSString *)text;

/// Makes redacted temporary copies of the current and rotated logs. Work is
/// serialized behind log writes; completion runs on the main queue. An empty
/// array with no error means no log exists. The caller removes the temporary
/// directory when the share sheet finishes.
+ (void)prepareRedactedLogsWithCompletion:(void (^)(NSArray<NSURL *> *files, NSError *_Nullable error))completion;

/// Absolute path of the live log file.
+ (NSString *)logFilePath;

/// Truncates the live log and deletes the rotated one.
+ (void)clear;

@end

/// Informational line: normal flow, useful when reading a report back.
#define MVLogInfo(fmt, ...)  [MVLog log:@"I" format:(fmt), ##__VA_ARGS__]
/// Warning: something recoverable happened, the user may notice.
#define MVLogWarn(fmt, ...)  [MVLog log:@"W" format:(fmt), ##__VA_ARGS__]
/// Error: a path failed. Always paired with a user-visible message somewhere.
#define MVLogError(fmt, ...) [MVLog log:@"E" format:(fmt), ##__VA_ARGS__]

NS_ASSUME_NONNULL_END
