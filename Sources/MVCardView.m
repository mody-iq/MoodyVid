#import "MVCardView.h"
#import "MVTheme.h"

@implementation MVCardView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        [self setup];
    }
    return self;
}

- (void)setup {
    _insets = UIEdgeInsetsMake(14, 14, 14, 14);
    [MVTheme applyCardStyle:self cornerRadius:[MVTheme cardCornerRadius]];

    _contentView = [UIView new];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.backgroundColor = UIColor.clearColor;
    [self addSubview:_contentView];
    [self updateContentInsets];
}

- (void)setInsets:(UIEdgeInsets)insets {
    _insets = insets;
    [self updateContentInsets];
}

- (void)updateContentInsets {
    for (NSLayoutConstraint *c in self.constraints) {
        if (c.firstItem == self.contentView || c.secondItem == self.contentView) {
            [self removeConstraint:c];
        }
    }
    UIView *content = self.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:self.topAnchor constant:self.insets.top],
        [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:self.insets.left],
        [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-self.insets.right],
        [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-self.insets.bottom],
    ]];
}

@end
