#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A small uppercase caption that introduces a group of cards, with an optional
/// trailing accessory (a count, a button) on the far side.
@interface MVSectionHeader : UIView

@property (nonatomic, copy) NSString *title;
/// A short right-aligned line, e.g. a count or the current speed.
@property (nonatomic, copy, nullable) NSString *trailingText;
/// An optional trailing view (a button). Takes the place of `trailingText`.
@property (nonatomic, strong, nullable) UIView *trailingView;

@end

NS_ASSUME_NONNULL_END
