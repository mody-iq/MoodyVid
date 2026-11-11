#import "MVEmptyStateView.h"
#import "MVTheme.h"

@implementation MVEmptyStateView {
    UIImageView *_icon;
    UILabel *_titleLabel;
    UILabel *_messageLabel;
    UIButton *_actionButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.tintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.7];
        [self addSubview:_icon];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_titleLabel];

        _messageLabel = [UILabel new];
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _messageLabel.font = [UIFont systemFontOfSize:14];
        _messageLabel.textColor = [MVTheme secondaryText];
        _messageLabel.textAlignment = NSTextAlignmentCenter;
        _messageLabel.numberOfLines = 0;
        _messageLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_messageLabel];

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
        [MVTheme applyPrimaryButtonStyle:_actionButton];
        _actionButton.contentEdgeInsets = UIEdgeInsetsMake(10, 22, 10, 22);
        [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_actionButton];

        UILayoutGuide *center = [UILayoutGuide new];
        [self addLayoutGuide:center];
        [NSLayoutConstraint activateConstraints:@[
            [_icon.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_icon.widthAnchor constraintEqualToConstant:52],
            [_icon.heightAnchor constraintEqualToConstant:52],
            [_icon.topAnchor constraintEqualToAnchor:center.topAnchor],
            [_titleLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:14],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],
            [_messageLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
            [_messageLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_messageLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_actionButton.topAnchor constraintEqualToAnchor:_messageLabel.bottomAnchor constant:18],
            [_actionButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [center.bottomAnchor constraintEqualToAnchor:_actionButton.bottomAnchor],
            [center.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [center.heightAnchor constraintLessThanOrEqualToAnchor:self.heightAnchor],
        ]];
    }
    return self;
}

- (void)setSymbolName:(NSString *)symbolName {
    _symbolName = [symbolName copy];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:46 weight:UIImageSymbolWeightRegular];
    _icon.image = [UIImage systemImageNamed:symbolName withConfiguration:config];
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    _titleLabel.text = title;
}

- (void)setMessage:(NSString *)message {
    _message = [message copy];
    _messageLabel.text = message;
    _messageLabel.hidden = message.length == 0;
}

- (void)setActionTitle:(NSString *)actionTitle {
    _actionTitle = [actionTitle copy];
    [_actionButton setTitle:actionTitle forState:UIControlStateNormal];
    _actionButton.hidden = actionTitle.length == 0;
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)refresh {
    _icon.tintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.7];
    _titleLabel.textColor = [MVTheme text];
    _messageLabel.textColor = [MVTheme secondaryText];
    [MVTheme applyPrimaryButtonStyle:_actionButton];
    _actionButton.contentEdgeInsets = UIEdgeInsetsMake(10, 22, 10, 22);
}

@end
