#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The card that stands for one entry in the Files browser: a folder or a file.
///
/// Mirrors `MVTaskCardCell` so the two lists look like one design. The tile shows
/// a thumbnail when one is known and an SF Symbol otherwise; folders get a
/// chevron, files an ellipsis button.
@interface MVFileCardCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onAction)(void);

- (void)configureWithName:(NSString *)name
                   detail:(NSString *)detail
               symbolName:(NSString *)symbolName
                thumbnail:(nullable UIImage *)thumbnail
                 isFolder:(BOOL)isFolder;

/// The glyph for a file extension, matching the Files browser's own mapping.
+ (NSString *)symbolForExtension:(NSString *)ext;

/// Briefly tints the card, so a row reached from elsewhere (a finished download)
/// is visibly singled out even though it was already on screen.
- (void)flashHighlight;

@end

NS_ASSUME_NONNULL_END
