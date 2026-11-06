#import <Foundation/Foundation.h>

@interface MVDownloadEngine : NSObject

+ (instancetype)shared;
- (void)downloadURL:(NSString *)url
            quality:(NSString *)quality
         completion:(void (^)(NSString *filePath, NSString *error))completion;

@end
