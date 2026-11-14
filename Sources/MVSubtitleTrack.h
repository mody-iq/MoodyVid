#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Local SRT/WebVTT captions, without network access or HTML execution.
@interface MVSubtitleTrack : NSObject
- (nullable instancetype)initWithData:(NSData *)data error:(NSString *_Nullable *_Nullable)error;
/// Text for the current position; empty between cues. Overlapping cues are
/// combined, with a small display limit to bound work on malformed inputs.
- (NSString *)textAtSeconds:(double)seconds;
@property (nonatomic, readonly) NSUInteger count;
@end

NS_ASSUME_NONNULL_END
