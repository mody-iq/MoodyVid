#import "MVDownloadEngine.h"
#import "MVPython.h"
#import <Photos/Photos.h>

@interface MVDownloadEngine ()
- (BOOL)isVideoFile:(NSString *)path;
- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion;
@end

@implementation MVDownloadEngine

+ (instancetype)shared {
    static MVDownloadEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadEngine new]; });
    return instance;
}

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *filePath, NSString *error))completion {
    NSArray *args = @[url, quality ?: @"best"];
    [[MVPython shared] call:@"downloader" function:@"download" args:args completion:^(NSDictionary *result, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSString *path = result[@"path"];
        if (!path.length) {
            completion(nil, @"فشل التحميل");
            return;
        }
        // Audio-only downloads are not videos, so Photos cannot store them.
        if ([self isVideoFile:path]) {
            [self saveToPhotos:path completion:completion];
        } else {
            completion(path, nil);
        }
    }];
}

- (BOOL)isVideoFile:(NSString *)path {
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"webm", @"mkv", @"avi", @"3gp"]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                [self saveToPhotos:filePath completion:completion];
            } else {
                // The file is on disk, so the download itself succeeded.
                completion(filePath, @"تم التحميل لكن لم يتم حفظه في الصور: الإذن مرفوض");
            }
        }];
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completionHandler:^(BOOL success, NSError *err) {
        if (success) {
            completion(filePath, nil);
        } else {
            completion(filePath, [NSString stringWithFormat:@"تم التحميل لكن فشل الحفظ في الصور: %@",
                                  err.localizedDescription ?: @"خطأ غير معروف"]);
        }
    }];
}

@end
