#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The card that stands for one download in the Downloads, Home and Files lists.
///
/// It is a self-contained view (icon tile, title, progress bar, detail line and
/// a trailing action button) so the three screens render a download identically.
/// The cell does not know about any engine; the controller hands it a plain
/// `MVCardContent` and decides what the action button means.
@interface MVCardContent : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail;
/// Shown in red under the title when set (a failure reason).
@property (nonatomic, copy, nullable) NSString *errorText;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong) UIColor *tint;
/// 0…1. Clamped; ignored when `showsProgress` is NO.
@property (nonatomic) double progress;
/// YES to show the progress bar (a running or paused row).
@property (nonatomic) BOOL showsProgress;
/// The trailing button's glyph.
@property (nonatomic, copy) NSString *actionSymbol;
@property (nonatomic) BOOL actionEnabled;
@end

@interface MVTaskCardCell : UITableViewCell

/// The trailing button's action.
@property (nonatomic, copy, nullable) void (^onAction)(void);
/// A tap anywhere else on the card (opens the detail sheet).
@property (nonatomic, copy, nullable) void (^onSelect)(void);

- (void)configureWithContent:(MVCardContent *)content;

/// A ready-made icon tile + tint for a download kind.
+ (NSString *)symbolForKindName:(NSString *)kind;

@end

NS_ASSUME_NONNULL_END
