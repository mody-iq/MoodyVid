#import "MVTaskCardCell.h"
#import "MVTheme.h"

@implementation MVCardContent
- (instancetype)init {
    if ((self = [super init])) {
        _tint = [MVTheme accent];
        _symbolName = @"arrow.down.circle";
        _actionSymbol = @"pause.fill";
        _actionEnabled = YES;
    }
    return self;
}
@end

#pragma mark - Progress bar

/// A thin rounded track with an accent fill, sized by a multiplier constraint so
/// the fill is cheap to move when progress updates.
@interface MVThinProgressBar : UIView
@property (nonatomic) double progress;
- (void)applyTheme;
@end

@implementation MVThinProgressBar {
    UIView *_fill;
    NSLayoutConstraint *_fillWidth;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 2.0;
        self.clipsToBounds = YES;

        _fill = [UIView new];
        _fill.translatesAutoresizingMaskIntoConstraints = NO;
        _fill.layer.cornerRadius = 2.0;
        [self addSubview:_fill];

        _fillWidth = [_fill.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.0];
        [NSLayoutConstraint activateConstraints:@[
            [_fill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_fill.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_fill.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            _fillWidth,
            [self.heightAnchor constraintEqualToConstant:4],
        ]];
        [self applyTheme];
    }
    return self;
}

- (void)setProgress:(double)progress {
    double clamped = MAX(0.0, MIN(1.0, progress));
    if (fabs(clamped - _progress) < 0.001) return;
    _progress = clamped;
    [_fillWidth setActive:NO];
    _fillWidth = [_fill.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:clamped];
    _fillWidth.active = YES;
}

- (void)applyTheme {
    self.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.22];
    _fill.backgroundColor = [MVTheme accent];
}

@end

#pragma mark - Card cell

@implementation MVTaskCardCell {
    UIView *_card;
    UIView *_iconTile;
    UIImageView *_icon;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UILabel *_errorLabel;
    MVThinProgressBar *_progressBar;
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
    [MVTheme applyIconTileStyle:_iconTile tint:[MVTheme accent]];
    [_card addSubview:_iconTile];

    _icon = [UIImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
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
    _detailLabel.numberOfLines = 1;
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    [_card addSubview:_detailLabel];

    _errorLabel = [UILabel new];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.font = [MVTheme cardDetailFont];
    _errorLabel.textColor = [MVTheme danger];
    _errorLabel.numberOfLines = 2;
    _errorLabel.hidden = YES;
    _errorLabel.adjustsFontForContentSizeCategory = YES;
    [_card addSubview:_errorLabel];

    _progressBar = [[MVThinProgressBar alloc] initWithFrame:CGRectZero];
    _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    _progressBar.hidden = YES;
    [_card addSubview:_progressBar];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.tintColor = [MVTheme secondaryText];
    _actionButton.layer.cornerRadius = 22.0;
    _actionButton.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.10];
    [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_actionButton];

    UILayoutGuide *textGuide = [UILayoutGuide new];
    [_card addLayoutGuide:textGuide];

    CGFloat pad = 14.0;
    [NSLayoutConstraint activateConstraints:@[
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:[MVTheme screenPadding]],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-[MVTheme screenPadding]],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],

        [_iconTile.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:pad],
        [_iconTile.topAnchor constraintEqualToAnchor:_card.topAnchor constant:pad],
        [_iconTile.widthAnchor constraintEqualToConstant:44],
        [_iconTile.heightAnchor constraintEqualToConstant:44],
        [_icon.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
        [_icon.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:24],
        [_icon.heightAnchor constraintEqualToConstant:24],

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

        [_progressBar.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8],
        [_progressBar.leadingAnchor constraintEqualToAnchor:textGuide.leadingAnchor],
        [_progressBar.trailingAnchor constraintEqualToAnchor:textGuide.trailingAnchor],

        [_detailLabel.topAnchor constraintEqualToAnchor:_progressBar.bottomAnchor constant:8],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:textGuide.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:textGuide.trailingAnchor],

        [_errorLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:2],
        [_errorLabel.leadingAnchor constraintEqualToAnchor:textGuide.leadingAnchor],
        [_errorLabel.trailingAnchor constraintEqualToAnchor:textGuide.trailingAnchor],
        [_errorLabel.bottomAnchor constraintLessThanOrEqualToAnchor:textGuide.bottomAnchor],
    ]];
}

- (void)configureWithContent:(MVCardContent *)content {
    _titleLabel.text = content.title;
    _detailLabel.text = content.detail;
    _detailLabel.hidden = content.detail.length == 0;
    _errorLabel.text = content.errorText;
    _errorLabel.hidden = content.errorText.length == 0;

    _icon.image = [UIImage systemImageNamed:content.symbolName];
    _icon.tintColor = content.tint;
    [MVTheme applyIconTileStyle:_iconTile tint:content.tint];

    _progressBar.hidden = !content.showsProgress;
    _progressBar.progress = content.progress;

    [_actionButton setImage:[UIImage systemImageNamed:content.actionSymbol] forState:UIControlStateNormal];
    _actionButton.enabled = content.actionEnabled;
    _actionButton.accessibilityLabel = content.actionSymbol;
}

/// These two are declared as methods rather than only as properties because a
/// cell's block is cleared in -prepareForReuse; a plain property setter there
/// would be overridden by the synthesised ivar access and the block would leak
/// into the next use of the cell.
- (void)setOnAction:(void (^)(void))onAction { _onAction = [onAction copy]; }
- (void)setOnSelect:(void (^)(void))onSelect { _onSelect = [onSelect copy]; }

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [MVTheme applyCardStyle:_card cornerRadius:[MVTheme cardCornerRadius]];
    _titleLabel.textColor = [MVTheme text];
    _detailLabel.textColor = [MVTheme secondaryText];
    _errorLabel.textColor = [MVTheme danger];
    [_progressBar applyTheme];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onAction = nil;
    self.onSelect = nil;
}

+ (NSString *)symbolForKindName:(NSString *)kind {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{@"Video": @"film", @"Audio": @"music.note", @"Image": @"photo",
                  @"Document": @"doc.text", @"Archive": @"archivebox", @"App": @"app.badge",
                  @"HLS": @"dot.radiowaves.left.and.right", @"DASH": @"dot.radiowaves.left.and.right",
                  @"Torrent": @"arrow.up.arrow.down.circle", @"Other": @"doc"};
    });
    return table[kind] ?: @"arrow.down.circle";
}

@end
