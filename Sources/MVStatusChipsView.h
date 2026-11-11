#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One chip in an `MVStatusChipsView`.
@interface MVStatusChip : NSObject
@property (nonatomic, copy) NSString *title;
/// Shown in a small badge after the title; hidden when <= 0.
@property (nonatomic) NSInteger count;
/// An opaque tag the caller uses to tell the chips apart.
@property (nonatomic) NSInteger tag;
+ (instancetype)chipWithTitle:(NSString *)title tag:(NSInteger)tag;
@end

/// A horizontally scrolling row of selectable pills with count badges.
///
/// The selected chip is filled in the accent colour; the rest sit on a subtle
/// translucent fill. Used for the Downloads status filter and the Files type
/// filter, so both screens share one look.
@interface MVStatusChipsView : UIView

/// The chips to show, in order. Setting this rebuilds the row.
@property (nonatomic, copy) NSArray<MVStatusChip *> *chips;
/// The tag of the selected chip.
@property (nonatomic) NSInteger selectedTag;
/// Called when the user taps a chip, with its tag.
@property (nonatomic, copy, nullable) void (^onSelect)(NSInteger tag);

@end

NS_ASSUME_NONNULL_END
