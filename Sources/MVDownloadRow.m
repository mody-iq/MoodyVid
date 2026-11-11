#import "MVDownloadRow.h"
#import "MVPaths.h"
#import "MVLang.h"

@implementation MVDownloadRow

+ (instancetype)rowWithRecord:(MVDownloadRecord *)record {
    MVDownloadRow *row = [MVDownloadRow new];
    row.kind = MVRowKindRecord;
    row.record = record;
    return row;
}

+ (instancetype)rowWithTask:(MVDownloadTask *)task {
    MVDownloadRow *row = [MVDownloadRow new];
    row.kind = MVRowKindTask;
    row.task = task;
    return row;
}

- (NSString *)identifier {
    return self.kind == MVRowKindRecord ? self.record.identifier : self.task.identifier;
}

- (BOOL)isActive {
    return self.kind == MVRowKindRecord ? self.record.isActive : self.task.isActive;
}

- (BOOL)isFinished {
    return self.kind == MVRowKindRecord ? self.record.isFinished : self.task.isFinished;
}

- (BOOL)isPaused {
    return self.kind == MVRowKindRecord ? self.record.state == MVDownloadStatePaused
                                        : self.task.state == MVTaskStatePaused;
}

- (BOOL)isFailed {
    return self.kind == MVRowKindRecord ? self.record.state == MVDownloadStateFailed
                                        : self.task.state == MVTaskStateFailed;
}

- (NSTimeInterval)createdAt {
    return self.kind == MVRowKindRecord ? self.record.createdAt : self.task.createdAt;
}

- (NSString *)title {
    NSString *value = self.kind == MVRowKindRecord ? self.record.title : self.task.title;
    return value.length ? value : self.url;
}

- (NSString *)url {
    return self.kind == MVRowKindRecord ? self.record.url : self.task.url;
}

- (NSString *)path {
    return self.kind == MVRowKindRecord ? self.record.path : self.task.path;
}

- (double)progress {
    return self.kind == MVRowKindRecord ? self.record.progress : self.task.progress;
}

- (double)speed {
    return self.kind == MVRowKindRecord ? self.record.speed : self.task.speed;
}

- (double)eta {
    return self.kind == MVRowKindRecord ? self.record.eta : self.task.eta;
}

- (long long)totalBytes {
    return self.kind == MVRowKindRecord ? self.record.totalBytes : self.task.totalBytes;
}

- (long long)doneBytes {
    if (self.kind == MVRowKindRecord) {
        return (long long)llround(self.record.progress * (double)self.record.totalBytes);
    }
    return self.task.doneBytes;
}

- (NSString *)statusText {
    if (self.kind == MVRowKindRecord) return self.record.error;
    return self.task.error ?: self.task.phase;
}

- (NSString *)category {
    if (self.kind == MVRowKindTask) return self.task.category;
    NSString *path = self.record.path;
    if (path.length) return [MVPaths categoryForFilename:path];
    return @"Other";
}

- (NSString *)typeName {
    if (self.kind == MVRowKindTask) {
        switch (self.task.source) {
            case MVTaskSourceHLS:
            case MVTaskSourceDASH:    return @"Video";
            case MVTaskSourceTorrent: return @"Torrent";
            default:                  return self.category;
        }
    }
    return self.category;
}

- (NSString *)errorText {
    if (self.kind == MVRowKindRecord) {
        // The engine stores a transient phase ("Merging…") in `error` while a
        // post-download step runs; that is not a failure, so it is not shown red.
        if (self.record.state != MVDownloadStateFailed) return nil;
        return self.record.error;
    }
    if (self.task.state != MVTaskStateFailed) return nil;
    return self.task.error;
}

/// A small glyph that says which engine produced the row, so a torrent or a
/// stream is recognisable at a glance.
- (NSString *)sourceSymbol {
    if (self.kind == MVRowKindRecord) return nil;
    switch (self.task.source) {
        case MVTaskSourceHLS:     return @"dot.radiowaves.left.and.right";
        case MVTaskSourceDASH:    return @"dot.radiowaves.left.and.right";
        case MVTaskSourceTorrent: return @"arrow.up.arrow.down.circle";
        default:                  return nil;
    }
}

/// "MP4 · 12.3 MB · 6 connections · 3.1 MB/s" for a task's detail sheet.
+ (NSString *)detailMessageForTask:(MVDownloadTask *)task {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    switch (task.source) {
        case MVTaskSourceDirect:  [parts addObject:[MVLang t:@"Direct file"]]; break;
        case MVTaskSourceHLS:     [parts addObject:[MVLang t:@"Stream (HLS)"]]; break;
        case MVTaskSourceDASH:    [parts addObject:[MVLang t:@"Stream (DASH)"]]; break;
        case MVTaskSourceTorrent: [parts addObject:[MVLang t:@"Torrent"]]; break;
        case MVTaskSourceYtDlp:   [parts addObject:@"yt-dlp"]; break;
    }
    if (task.totalBytes > 0) [parts addObject:[MVPaths formatBytes:task.totalBytes]];
    if (task.state == MVTaskStateRunning) {
        // A torrent's peer count is not the same as an HTTP connection count,
        // so the connection figure is only meaningful for the direct engines.
        if (task.source != MVTaskSourceTorrent) {
            [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)task.connections,
                              [MVLang t:@"Connections"]]];
        }
        if (task.speed > 0) [parts addObject:[MVPaths formatSpeed:task.speed]];
        if (task.eta > 0) [parts addObject:[MVPaths formatDuration:task.eta]];
    }
    if (task.error.length) [parts addObject:task.error];
    return [parts componentsJoinedByString:@" · "];
}

@end
