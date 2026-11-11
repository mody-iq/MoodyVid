#import "MVFileCardCell.h"
#import "MVTheme.h"

@implementation MVFileCardCell {
    UIView *_card;
    UIView *_iconTile;
    UIImageView *_icon;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIButton *_actionButton;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self build];
    }
    return self;
}

- (void)build {
    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:_card cornerRadius:[MVTheme cardCornerRadius]];
    [self.contentView addSubview:_card];

    _iconTile = [UIView new];
    _iconTile.translatesAutoresizingMaskIntoConstraints = NO;
    _iconTile.clipsToBounds = YES;
    [MVTheme applyIconTileStyle:_iconTile tint:[MVTheme accent]];
    [_card addSubview:_iconTile];

    _icon = [UIImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentMode = UIViewContentModeScaleAspectFill;
    _icon.clipsToBounds = YES;
    [_iconTile addSubview:_icon];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [MVTheme cardTitleFont];
    _titleLabel.textColor = [MVTheme text];
    _titleLabel.numberOfLines = 2;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    [_card addSubview:_titleLabel];

    _detailLabel = [UILabel new];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [MVTheme cardDetailFont];
    _detailLabel.textColor = [MVTheme secondaryText];
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    [_card addSubview:_detailLabel];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.tintColor = [MVTheme secondaryText];
    [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_actionButton];

    UILayoutGuide *textGuide = [UILayoutGuide new];
    [_card addLayoutGuide:textGuide];

    CGFloat pad = 12.0;
    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:[MVTheme screenPadding]],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-[MVTheme screenPadding]],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],

        [_iconTile.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:pad],
        [_iconTile.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconTile.widthAnchor constraintEqualToConstant:48],
        [_iconTile.heightAnchor constraintEqualToConstant:48],
        [_icon.topAnchor constraintEqualToAnchor:_iconTile.topAnchor],
        [_icon.bottomAnchor constraintEqualToAnchor:_iconTile.bottomAnchor],
        [_icon.leadingAnchor constraintEqualToAnchor:_iconTile.leadingAnchor],
        [_icon.trailingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor],

        [_actionButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-pad],
        [_actionButton.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_actionButton.widthAnchor constraintEqualToConstant:44],
        [_actionButton.heightAnchor constraintEqualToConstant:44],

        [textGuide.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:12],
        [textGuide.trailingAnchor constraintEqualToAnchor:_actionButton.leadingAnchor constant:-12],
        [textGuide.topAnchor constraintEqualToAnchor:_card.topAnchor constant:pad],
        [textGuide.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-pad],

        [_titleLabel.topAnchor constraintEqualToAnchor:textGuide.topAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:textGuide.leadingAnchor],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:textGuide.trailingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:textGuide.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:textGuide.trailingAnchor],
        [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:textGuide.bottomAnchor],
    ]];
}

- (void)configureWithName:(NSString *)name
                   detail:(NSString *)detail
               symbolName:(NSString *)symbolName
                thumbnail:(UIImage *)thumbnail
                 isFolder:(BOOL)isFolder {
    _titleLabel.text = name;
    _detailLabel.text = detail;
    _detailLabel.hidden = detail.length == 0;

    // A thumbnail fills the tile edge to edge; a glyph is drawn smaller inside
    // it. Both are handled by one set of edge-pinned constraints, so switching
    // between them on cell reuse never has to add or drop constraints.
    if (thumbnail) {
        _icon.image = thumbnail;
        _icon.contentMode = UIViewContentModeScaleAspectFill;
        _icon.tintColor = nil;
        _iconTile.backgroundColor = [MVTheme separator];
        _iconTile.layer.borderWidth = 0;
    } else {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
        _icon.image = [UIImage systemImageNamed:symbolName withConfiguration:config];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.tintColor = isFolder ? [MVTheme accent] : [MVTheme text];
        [MVTheme applyIconTileStyle:_iconTile tint:isFolder ? [MVTheme accent] : [MVTheme secondaryText]];
    }

    [_actionButton setImage:[UIImage systemImageNamed:isFolder ? @"chevron.forward" : @"ellipsis"]
                   forState:UIControlStateNormal];
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onAction = nil;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [MVTheme applyCardStyle:_card cornerRadius:[MVTheme cardCornerRadius]];
    _titleLabel.textColor = [MVTheme text];
    _detailLabel.textColor = [MVTheme secondaryText];
}

+ (NSString *)symbolForExtension:(NSString *)ext {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{@"mp4": @"play.rectangle.fill", @"mov": @"play.rectangle.fill",
                  @"m4v": @"play.rectangle.fill", @"mkv": @"play.rectangle.fill",
                  @"webm": @"play.rectangle.fill",
                  @"m4a": @"waveform", @"mp3": @"waveform", @"aac": @"waveform",
                  @"opus": @"waveform", @"wav": @"waveform",
                  @"pdf": @"doc.richtext",
                  @"zip": @"doc.zipper", @"rar": @"doc.zipper", @"7z": @"doc.zipper"};
    });
    return table[ext] ?: @"doc";
}

@end
