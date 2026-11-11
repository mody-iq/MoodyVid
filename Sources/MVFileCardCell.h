#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The card that stands for one entry in the Files browser: a folder or a file.
///
/// Mirrors `MVTaskCardCell` so the two lists look like one design. The tile shows
/// a thumbnail when one is known and an SF Symbol otherwise; folders get a
/// chevron, files an ellipsis button.
@interface MVFileCardCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onAction)(void);

/// The file path this cell currently shows, so a thumbnail generated in the
/// background can be dropped if the cell was reused for another file meanwhile.
@property (nonatomic, copy, nullable) NSString *representedPath;

- (void)configureWithName:(NSString *)name
                   detail:(NSString *)detail
               symbolName:(NSString *)symbolName
                thumbnail:(nullable UIImage *)thumbnail
                 isFolder:(BOOL)isFolder;

/// Swaps in a thumbnail once it has been generated, keeping the current glyph
/// until then. A no-op if the cell no longer represents that file.
- (void)setThumbnailImage:(nullable UIImage *)image forPath:(NSString *)path;

/// The glyph for a file extension, matching the Files browser's own mapping.
+ (NSString *)symbolForExtension:(NSString *)ext;

/// Briefly tints the card, so a row reached from elsewhere (a finished download)
/// is visibly singled out even though it was already on screen.
- (void)flashHighlight;

@end

NS_ASSUME_NONNULL_END
