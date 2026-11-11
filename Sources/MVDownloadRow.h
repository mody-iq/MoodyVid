#import <Foundation/Foundation.h>
#import "MVDownloadStore.h"
#import "MVDownloadTask.h"

NS_ASSUME_NONNULL_BEGIN

/// One row in the Downloads list, wrapping either a yt-dlp record or a manager
/// task so one list can render both without either engine knowing about the
/// other. Also the model behind the details sheet.
@interface MVDownloadRow : NSObject

typedef NS_ENUM(NSInteger, MVRowKind) { MVRowKindRecord = 0, MVRowKindTask };

@property (nonatomic) MVRowKind kind;
@property (nonatomic, strong, nullable) MVDownloadRecord *record;
@property (nonatomic, strong, nullable) MVDownloadTask *task;

@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) BOOL isFinished;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL isFailed;
@property (nonatomic, readonly) NSTimeInterval createdAt;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *url;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) double speed;
@property (nonatomic, readonly) double eta;
@property (nonatomic, readonly) long long totalBytes;
@property (nonatomic, readonly) long long doneBytes;
/// "Video", "Audio", "Torrent", … — the type filter and the icon both use it.
@property (nonatomic, readonly) NSString *typeName;
@property (nonatomic, readonly) NSString *category;
@property (nonatomic, readonly) NSString *sourceSymbol;
/// The error text to show under the title, if any.
@property (nonatomic, readonly, nullable) NSString *errorText;

+ (instancetype)rowWithRecord:(MVDownloadRecord *)record;
+ (instancetype)rowWithTask:(MVDownloadTask *)task;

/// The status line shown under a task's title in its detail sheet.
+ (NSString *)detailMessageForTask:(MVDownloadTask *)task;

@end

NS_ASSUME_NONNULL_END
