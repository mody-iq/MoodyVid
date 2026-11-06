#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the embedded Python interpreter on its own serial queue.
@interface MVPython : NSObject

+ (instancetype)shared;

/// Starts the interpreter. Safe to call more than once.
- (void)start;

/// Calls module.function(*args), where every argument is a string and the function
/// returns a JSON object as a string. The completion runs on the main queue with the
/// parsed result, or with an error message.
- (void)call:(NSString *)module
    function:(NSString *)function
        args:(NSArray<NSString *> *)args
  completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
