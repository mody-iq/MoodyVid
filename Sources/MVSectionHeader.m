#import "MVSectionHeader.h"
#import "MVTheme.h"

@implementation MVSectionHeader {
    UILabel *_titleLabel;
    UILabel *_trailingLabel;
    UIView *_trailingView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [MVTheme sectionHeaderFont];
        _titleLabel.textColor = [MVTheme secondaryText];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_titleLabel];

        _trailingLabel = [UILabel new];
        _trailingLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _trailingLabel.font = [MVTheme cardDetailFont];
        _trailingLabel.textColor = [MVTheme secondaryText];
        _trailingLabel.textAlignment = NSTextAlignmentNatural;
        [self addSubview:_trailingLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_titleLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
            [_titleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
            [_trailingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:8],
            [_trailingLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_trailingLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setTitle:(NSString *)title {
    _titleLabel.text = title.uppercaseString;
}

- (NSString *)title { return _titleLabel.text ?: @""; }

- (void)setTrailingText:(NSString *)trailingText {
    _trailingLabel.text = trailingText;
    _trailingLabel.hidden = trailingText.length == 0;
}

- (NSString *)trailingText { return _trailingLabel.text; }

- (void)setTrailingView:(UIView *)trailingView {
    UIView *old = _trailingView;
    _trailingView = trailingView;
    [old removeFromSuperview];
    if (!trailingView) return;
    _trailingLabel.hidden = YES;
    trailingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:trailingView];
    [NSLayoutConstraint activateConstraints:@[
        [trailingView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [trailingView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

- (UIView *)trailingView { return _trailingView; }

@end
