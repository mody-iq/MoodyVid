#import "MVDownloadEngine.h"
#import "MVPython.h"
#import <Photos/Photos.h>

@implementation MVDownloadEngine

+ (instancetype)shared {
    static MVDownloadEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadEngine new]; });
    return instance;
}

- (void)downloadURL:(NSString *)url
            quality:(NSString *)quality
         completion:(void (^)(NSString *filePath, NSString *error))completion {
    NSArray *args = @[url, quality ?: @"best"];
    [[MVPython shared] call:@"downloader" function:@"download" args:args completion:^(NSDictionary *result, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSString *path = result[@"path"];
        if (!path) {
            completion(nil, result[@"error"] ?: @"فشل التحميل");
            return;
        }
        [self saveToPhotos:path completion:completion];
    }];
}

- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion {
    if (![PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite] == PHAuthorizationStatusAuthorized &&
        ![PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite] == PHAuthorizationStatusLimited) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                [self saveToPhotos:filePath completion:completion];
            } else {
                completion(filePath, @"تم التحميل but not saved to Photos (permission denied)");
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
            completion(filePath, err.localizedDescription ?: @"فشل الحفظ في الصور");
        }
    }];
}

@end
