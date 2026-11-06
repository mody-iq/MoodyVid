#import "MVDownloadEngine.h"
#import "MVPython.h"
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

@implementation MVDownloadEngine

+ (instancetype)shared {
    static MVDownloadEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [MVDownloadEngine new];
    });
    return instance;
}

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *filePath, NSString *error))completion {
    if (url.length == 0) {
        completion(nil, @"الرابط فارغ");
        return;
    }

    NSArray *args = @[url, quality ?: @"best"];
    [[MVPython shared] call:@"downloader" function:@"download" args:args completion:^(NSDictionary *result, NSString *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSString *path = result[@"path"];
        if (path.length == 0) {
            completion(nil, @"فشل التحميل");
            return;
        }

        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus newStatus) {
                if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                    [self saveToPhotos:path completion:completion];
                } else {
                    completion(path, nil);
                }
            }];
        } else {
            [self saveToPhotos:path completion:completion];
        }
    }];
}

- (void)saveToPhotos:(NSString *)filePath completion:(void (^)(NSString *filePath, NSString *error))completion {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completionHandler:^(BOOL success, NSError *error) {
        if (success) {
            completion(filePath, nil);
        } else {
            completion(filePath, nil);
        }
    }];
}

@end
