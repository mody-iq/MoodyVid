#import <UIKit/UIKit.h>
#import "MVPython.h"
#import <Photos/Photos.h>

NS_ASSUME_NONNULL_BEGIN

@interface MVDownloadEngine : NSObject
+ (instancetype)shared;
- (void)downloadURL:(NSString *)url
         quality:(NSString *)quality
    completion:(void (^)(NSString *filePath, NSString *error))completion;
- (void)saveToPhotos:(NSString *)filePath
   presentingViewController:(UIViewController *)vc
              completion:(void (^)(BOOL success, NSString *error))completion;
@end

@implementation MVDownloadEngine
+ (instancetype)shared {
    static MVDownloadEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MVDownloadEngine alloc] init]; });
    return s;
}

- (void)downloadURL:(NSString *)url quality:(NSString *)quality completion:(void (^)(NSString *, NSString *))completion {
    NSMutableArray *args = [NSMutableArray arrayWithObjects:url, quality, nil];
    [[MVPython shared] call:@"downloader" function:@"download" args:args completion:^(NSDictionary *result, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSString *path = result[@"filepath"];
        NSString *err = result[@"error"];
        if (path && ![path isEqualToString:@""]) {
            completion(path, nil);
        } else {
            completion(nil, err ?: @"فشل التحميل");
        }
    }];
}

- (void)saveToPhotos:(NSString *)filePath presentingViewController:(UIViewController *)vc completion:(void (^)(BOOL, NSString *))completion {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status != PHAuthorizationStatusAuthorized) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
            if (newStatus != PHAuthorizationStatusAuthorized) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, @"مطلوب إذن الوصول إلى الصور");
                });
                return;
            }
            [self performSave:filePath completion:completion];
        }];
    } else {
        [self performSave:filePath completion:completion];
    }
}

- (void)performSave:(NSString *)filePath completion:(void (^)(BOOL, NSString *))completion {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
    } completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, error ? error.localizedDescription : nil);
        });
    }];
}

@end

NS_ASSUME_NONNULL_END
