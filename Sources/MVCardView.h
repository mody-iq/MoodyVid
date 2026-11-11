#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A rounded, translucent surface that holds one piece of content.
///
/// Wraps `+[MVTheme applyCardStyle:]` so every card in the app shares the same
/// corner radius, border and frosted backing, and so a card can expose a
/// `contentView` to lay its children out in without repeating the blur setup.
@interface MVCardView : UIView

/// The view to add children to. Pinned to the card's edges with `insets`.
@property (nonatomic, readonly) UIView *contentView;
/// Padding between `contentView` and the card's edge. Default 14.
@property (nonatomic) UIEdgeInsets insets;

@end

NS_ASSUME_NONNULL_END
