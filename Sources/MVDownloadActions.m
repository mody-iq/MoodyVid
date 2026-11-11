#import "MVDownloadActions.h"
#import "MVDownloadEngine.h"
#import "MVDownloadManager.h"
#import "MVDownloadStore.h"

@implementation MVDownloadActions

+ (void)pauseRow:(MVDownloadRow *)row {
    if (row.kind == MVRowKindTask) {
        [[MVDownloadManager shared] pauseTask:row.task];
    } else {
        [[MVDownloadEngine shared] pauseDownload:row.record.identifier];
    }
}

+ (void)resumeRow:(MVDownloadRow *)row {
    if (row.kind == MVRowKindTask) {
        [[MVDownloadManager shared] resumeTask:row.task];
    } else {
        [[MVDownloadEngine shared] resumeDownload:row.record.identifier];
    }
}

+ (void)cancelRow:(MVDownloadRow *)row deleteFile:(BOOL)deleteFile {
    if (row.kind == MVRowKindTask) {
        [[MVDownloadManager shared] cancelTask:row.task deleteFile:deleteFile];
    } else {
        [[MVDownloadEngine shared] cancelDownload:row.record.identifier];
    }
}

+ (void)removeRow:(MVDownloadRow *)row deleteFile:(BOOL)deleteFile {
    if (row.kind == MVRowKindTask) {
        [[MVDownloadManager shared] removeTask:row.task deleteFile:deleteFile];
        return;
    }
    if (deleteFile && row.path.length) {
        [[NSFileManager defaultManager] removeItemAtPath:row.path error:nil];
    }
    [MVDownloadStore.shared remove:row.record];
}

+ (void)retryRow:(MVDownloadRow *)row {
    if (row.kind == MVRowKindTask) {
        [[MVDownloadManager shared] resumeTask:row.task];
    } else {
        [[MVDownloadEngine shared] resumeDownload:row.record.identifier];
    }
}

@end
