#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The friendly "nothing here" placeholder: a large glyph, a short title, an
/// optional line of guidance and an optional action button.
@interface MVEmptyStateView : UIView

@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *message;
/// The action button's title; hidden when empty.
@property (nonatomic, copy, nullable) NSString *actionTitle;
@property (nonatomic, copy, nullable) void (^onAction)(void);

/// Rebuilds the labels after a language or theme change.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
