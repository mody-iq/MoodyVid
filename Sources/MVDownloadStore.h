#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted whenever the list of records changes (added, updated, removed).
extern NSString *const MVDownloadStoreDidChangeNotification;

typedef NS_ENUM(NSInteger, MVDownloadState) {
    MVDownloadStateWaiting = 0,
    MVDownloadStateActive = 1,
    MVDownloadStateCompleted = 2,
    MVDownloadStateFailed = 3,
    MVDownloadStateCancelled = 4,
};

/// One download, as shown in the Downloads and Files screens.
@interface MVDownloadRecord : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy) NSString *quality;
@property (nonatomic, copy, nullable) NSString *error;
/// Local path of the cached video thumbnail, if we have one.
@property (nonatomic, copy, nullable) NSString *thumbnail;
@property (nonatomic) MVDownloadState state;
@property (nonatomic) double progress;      // 0.0 - 1.0
@property (nonatomic) double speed;         // bytes per second, 0 when unknown
@property (nonatomic) double eta;           // seconds, 0 when unknown
@property (nonatomic) long long totalBytes;
@property (nonatomic) NSTimeInterval createdAt;

@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) BOOL isFinished;

+ (instancetype)fromDictionary:(NSDictionary *)dict;
- (NSDictionary *)dictionary;

@end

/// The download history, shared by the Downloads, Files and Settings screens.
///
/// Persisted as JSON inside the documents folder so the list survives a restart.
/// Only finished records carry a path; an interrupted one keeps its title so the
/// row still makes sense after the app is relaunched.
@interface MVDownloadStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<MVDownloadRecord *> *records;

- (MVDownloadRecord *)addURL:(NSString *)url quality:(NSString *)quality;
- (void)update:(MVDownloadRecord *)record;
- (void)remove:(MVDownloadRecord *)record;

- (NSArray<MVDownloadRecord *> *)activeRecords;
- (NSArray<MVDownloadRecord *> *)finishedRecords;

/// Writes the list to disk. Called automatically on every change.
- (void)save;

@end

NS_ASSUME_NONNULL_END
