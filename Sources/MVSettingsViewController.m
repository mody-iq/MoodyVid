#import "MVSettingsViewController.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVPython.h"
#import "MVAdBlocker.h"
#import "MVLog.h"
#import "MVDownloadManager.h"
#import "MVMediaProbe.h"
#import "MVBrowserHistory.h"
#import "MVSnifferStore.h"
#import "MVSectionHeader.h"
#import <WebKit/WebKit.h>

static NSString *const kCell = @"MVCell";
static CGFloat const kCorner = 18;

@interface MVSettingsCell : UITableViewCell
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIImageView *leadingIcon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *iconBack;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UIView *rightView;    // custom trailing accessory (swatch/mode)
@property (nonatomic) UIRectCorner maskedCorners;
@end

/// A settings row: tinted icon chip + title + subtitle + chevron, sitting on a
/// rounded inset card so each section reads as one modern panel.
@implementation MVSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundView = [UIView new];
        self.backgroundView.backgroundColor = UIColor.clearColor;

        _cardView = [UIView new];
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.backgroundColor = [MVTheme glassCard];
        _cardView.layer.cornerCurve = kCACornerCurveContinuous;
        _cardView.layer.borderWidth = 0.5;
        _cardView.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.35].CGColor;
        [self.contentView addSubview:_cardView];

        _iconBack = [UIView new];
        _iconBack.translatesAutoresizingMaskIntoConstraints = NO;
        _iconBack.layer.cornerRadius = 10;
        _iconBack.layer.masksToBounds = YES;
        [_cardView addSubview:_iconBack];

        _leadingIcon = [UIImageView new];
        _leadingIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _leadingIcon.contentMode = UIViewContentModeScaleAspectFit;
        _leadingIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIFontWeightSemibold];
        [_cardView addSubview:_leadingIcon];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.numberOfLines = 1;
        [_cardView addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [MVTheme secondaryText];
        _subtitleLabel.numberOfLines = 1;
        [_cardView addSubview:_subtitleLabel];

        // Container for a trailing accessory (wallpaper swatch or mode label).
        // It lives inside the card so it can sit before the chevron.
        _rightView = [UIView new];
        _rightView.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_rightView];

        [NSLayoutConstraint activateConstraints:@[
            [_cardView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_cardView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_cardView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:2],
            [_cardView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-2],

            [_iconBack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:12],
            [_iconBack.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_iconBack.widthAnchor constraintEqualToConstant:38],
            [_iconBack.heightAnchor constraintEqualToConstant:38],

            [_leadingIcon.centerXAnchor constraintEqualToAnchor:_iconBack.centerXAnchor],
            [_leadingIcon.centerYAnchor constraintEqualToAnchor:_iconBack.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBack.trailingAnchor constant:14],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_rightView.leadingAnchor constant:-10],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_cardView.trailingAnchor constant:-58],

            [_rightView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-42],
            [_rightView.centerYAnchor constraintEqualToAnchor:_cardView.centerYAnchor],
            [_rightView.widthAnchor constraintGreaterThanOrEqualToConstant:34],
        ]];
    }
    return self;
}

- (void)setMaskedCorners:(UIRectCorner)maskedCorners {
    _maskedCorners = maskedCorners;
    [self applyMask];
}

- (void)applyMask {
    UIRectCorner corners = _maskedCorners;
    if (corners == 0) {
        _cardView.layer.cornerRadius = kCorner;
        _cardView.layer.mask = nil;
        return;
    }
    _cardView.layer.cornerRadius = 0;
    CGRect b = _cardView.bounds;
    if (CGRectIsEmpty(b)) b = CGRectMake(0, 0, 320, 60);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:b
                                               byRoundingCorners:corners
                                                     cornerRadii:CGSizeMake(kCorner, kCorner)];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = path.CGPath;
    mask.frame = b;
    _cardView.layer.mask = mask;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyMask];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _maskedCorners = 0;
    _cardView.layer.mask = nil;
    _cardView.layer.cornerRadius = kCorner;
    [_chevronView removeFromSuperview];
    _chevronView = nil;
    for (UIView *v in _rightView.subviews) [v removeFromSuperview];
}

- (void)setHasChevron:(BOOL)has {
    if (!has) return;
    if (!_chevronView) {
        _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        _chevronView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightSemibold];
        _chevronView.tintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.6];
        _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.cardView addSubview:_chevronView];
        [NSLayoutConstraint activateConstraints:@[
            [_chevronView.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],
            [_chevronView.centerYAnchor constraintEqualToAnchor:self.cardView.centerYAnchor],
        ]];
    }
}

- (void)configureIcon:(NSString *)symbol tint:(UIColor *)tint {
    self.leadingIcon.image = [UIImage systemImageNamed:symbol];
    self.leadingIcon.tintColor = tint;
    self.iconBack.backgroundColor = [tint colorWithAlphaComponent:0.16];
}

@end

#pragma mark - Contact sheet

/// The social accounts offered in the Contact sheet. Add or edit a row here and
/// both the sheet and its links follow: `url` opens the profile and the app
/// scheme lets iOS jump into the app when it is installed. `avatar` names a PNG
/// in Resources/avatars (without the extension); when it is missing or cannot be
/// loaded, the `icon` SF Symbol is shown instead.
static NSArray<NSDictionary *> *MVContactAccounts(void) {
    return @[
        @{ @"name": @"Instagram", @"handle": @"1mody_11",
           @"icon": @"camera.fill", @"avatar": @"instagram",
           @"url": @"https://instagram.com/1mody_11",
           @"scheme": @"instagram://user?username=1mody_11",
           @"r": @0.93, @"g": @0.36, @"b": @0.55 },
        @{ @"name": @"Facebook", @"handle": @"حمودي الجبوري",
           @"icon": @"f.circle.fill", @"avatar": @"facebook",
           @"url": @"https://www.facebook.com/Mohammed.K.Mutar",
           @"scheme": @"fb://profile/Mohammed.K.Mutar",
           @"r": @0.23, @"g": @0.46, @"b": @0.90 },
    ];
}

/// A quiet rounded row used inside the Contact sheet: a soft tinted icon chip,
/// the account name and handle, and a small chevron.
@interface MVContactRow : UIControl
@property (nonatomic, strong) NSDictionary *account;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconBack;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UIImageView *avatarView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *chevron;
@end

@implementation MVContactRow

- (instancetype)initWithAccount:(NSDictionary *)account {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _account = account;

        UIColor *brand = [UIColor colorWithRed:[account[@"r"] doubleValue]
                                        green:[account[@"g"] doubleValue]
                                         blue:[account[@"b"] doubleValue]
                                        alpha:1.0];

        _card = [UIView new];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        _card.userInteractionEnabled = NO;
        _card.backgroundColor = [[MVTheme card] colorWithAlphaComponent:0.55];
        _card.layer.cornerRadius = 16;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.layer.borderWidth = 0.5;
        _card.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.22].CGColor;
        [self addSubview:_card];

        _iconBack = [UIView new];
        _iconBack.translatesAutoresizingMaskIntoConstraints = NO;
        _iconBack.backgroundColor = [brand colorWithAlphaComponent:0.16];
        _iconBack.layer.cornerRadius = 20;   // half of 40, so the chip is a circle
        _iconBack.layer.masksToBounds = YES;
        [_card addSubview:_iconBack];

        // The profile picture, when the account ships one; otherwise the tinted
        // SF Symbol sits in the same circle. The avatar is pre-rounded in the
        // PNG, so it needs no clipping of its own.
        _avatarView = [UIImageView new];
        _avatarView.translatesAutoresizingMaskIntoConstraints = NO;
        _avatarView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarView.hidden = YES;
        [_iconBack addSubview:_avatarView];

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.image = [UIImage systemImageNamed:account[@"icon"]];
        _icon.tintColor = brand;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIFontWeightSemibold];
        [_iconBack addSubview:_icon];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = account[@"name"];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        [_card addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.text = account[@"handle"];
        _subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [MVTheme secondaryText];
        [_card addSubview:_subtitleLabel];

        _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right"]];
        _chevron.translatesAutoresizingMaskIntoConstraints = NO;
        _chevron.tintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.5];
        _chevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIFontWeightSemibold];
        [_card addSubview:_chevron];

        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_card.heightAnchor constraintEqualToConstant:64],

            [_iconBack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_iconBack.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_iconBack.widthAnchor constraintEqualToConstant:40],
            [_iconBack.heightAnchor constraintEqualToConstant:40],

            [_avatarView.leadingAnchor constraintEqualToAnchor:_iconBack.leadingAnchor],
            [_avatarView.trailingAnchor constraintEqualToAnchor:_iconBack.trailingAnchor],
            [_avatarView.topAnchor constraintEqualToAnchor:_iconBack.topAnchor],
            [_avatarView.bottomAnchor constraintEqualToAnchor:_iconBack.bottomAnchor],

            [_icon.centerXAnchor constraintEqualToAnchor:_iconBack.centerXAnchor],
            [_icon.centerYAnchor constraintEqualToAnchor:_iconBack.centerYAnchor],

            [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
            [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBack.trailingAnchor constant:13],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor constant:-10],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:_card.centerYAnchor constant:-1],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor constant:-10],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_card.centerYAnchor constant:1],
        ]];

        // Arabic reads right to left, so mirror the whole row: avatar on the
        // right and chevron on the left.
        if (MVLang.shared.isRTL) {
            self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
            for (UIView *v in @[_card, _iconBack, _avatarView, _icon, _titleLabel, _subtitleLabel, _chevron]) {
                v.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
            }
        }
        [self applyAvatar];
    }
    return self;
}

/// Loads the account's bundled profile picture into the icon chip, falling back
/// to the SF Symbol when no image ships with the app.
- (void)applyAvatar {
    NSString *name = self.account[@"avatar"];
    UIImage *image = nil;
    if (name.length) {
        NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"avatars"];
        if (!path) path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
        if (path) image = [UIImage imageWithContentsOfFile:path];
    }
    if (image) {
        self.avatarView.image = image;
        self.avatarView.hidden = NO;
        self.icon.hidden = YES;
    } else {
        self.avatarView.hidden = YES;
        self.icon.hidden = NO;
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.card.backgroundColor = [[MVTheme card] colorWithAlphaComponent:highlighted ? 0.85 : 0.55];
    }];
}

@end

/// The small pop-up shown by the Contact row: a flat sheet listing the social
/// accounts, each row opening the profile in its app (or the browser).
@interface MVContactSheetViewController : UIViewController
@end

@implementation MVContactSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // A flat, quiet sheet: a solid panel behind a small stack of accounts, no
    // material to composite and no loud colours.
    self.view.backgroundColor = UIColor.clearColor;
    UIView *backdrop = [UIView new];
    backdrop.backgroundColor = [MVTheme card];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:backdrop];

    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = UIColor.clearColor;
    [self.view addSubview:panel];

    // Grabber, so the sheet reads as something you can pull down to dismiss.
    UIView *grabber = [UIView new];
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    grabber.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.35];
    grabber.layer.cornerRadius = 2.5;
    [panel addSubview:grabber];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = [MVLang t:@"Contact"];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [MVTheme text];
    title.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = [MVLang t:@"Follow me on social media"];
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subtitle.textColor = [MVTheme secondaryText];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    [panel addSubview:subtitle];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [panel addSubview:stack];

    for (NSDictionary *account in MVContactAccounts()) {
        MVContactRow *row = [[MVContactRow alloc] initWithAccount:account];
        [row addTarget:self action:@selector(accountTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:row];
    }

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [grabber.topAnchor constraintEqualToAnchor:panel.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:38],
        [grabber.heightAnchor constraintEqualToConstant:5],

        [title.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-24],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24],
        [subtitle.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-24],

        [stack.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20],
    ]];
}

- (void)accountTapped:(MVContactRow *)row {
    if (row.account) [self openAccount:row.account];
}

- (void)openAccount:(NSDictionary *)account {
    UIApplication *app = UIApplication.sharedApplication;
    NSURL *web = [NSURL URLWithString:account[@"url"]];
    NSURL *scheme = [NSURL URLWithString:account[@"scheme"]];
    // Prefer the app (a direct jump to the profile), but never dead-end: if the
    // app is not installed, open the web profile instead.
    if (scheme && [app canOpenURL:scheme]) {
        [app openURL:scheme options:@{} completionHandler:nil];
    } else if (web) {
        [app openURL:web options:@{} completionHandler:nil];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end



@interface MVSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *footerBar;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic) BOOL clearingBrowserData;
@property (nonatomic) BOOL preparingLogs;
@end

@implementation MVSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"More"];
    // Each section is a separate rounded card, so the plain list is just the
    // scrolling surface; the cells carry their own inset, rounded cards.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 62;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 64, 0);
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:MVSettingsCell.class forCellReuseIdentifier:kCell];
    [self.view addSubview:self.tableView];

    // A credit line anchored to the bottom of the screen. It lives in its own
    // bar (with a background) outside the table, so it never scrolls and never
    // looks like stray text floating over the rows.
    self.footerBar = [UIView new];
    self.footerBar.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:self.footerBar cornerRadius:0];
    self.footerBar.layer.borderWidth = 0;
    [self.view addSubview:self.footerBar];

    self.footerLabel = [UILabel new];
    self.footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerLabel.text = [MVLang t:@"Made with love"];
    self.footerLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.footerLabel.textColor = [MVTheme secondaryText];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    [self.footerBar addSubview:self.footerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.footerBar.topAnchor],

        [self.footerBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.footerBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.footerBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.footerBar.heightAnchor constraintEqualToConstant:44],

        [self.footerLabel.leadingAnchor constraintEqualToAnchor:self.footerBar.leadingAnchor constant:20],
        [self.footerLabel.trailingAnchor constraintEqualToAnchor:self.footerBar.trailingAnchor constant:-20],
        [self.footerLabel.centerYAnchor constraintEqualToAnchor:self.footerBar.centerYAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:MVLangDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:MVThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    // The very first appearance lays the table out at zero width; reload once
    // the frame is real so the rounded cards render correctly.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        [self_.tableView setNeedsLayout];
        [self_.tableView layoutIfNeeded];
        [self_.tableView reloadData];
    });
}

- (void)refresh {
    self.title = [MVLang t:@"More"];
    [MVTheme applyWallpaperTo:self.view];
    self.footerLabel.text = [MVLang t:@"Made with love"];
    self.footerLabel.textColor = [MVTheme secondaryText];
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) layer.frame = self.view.bounds;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [MVTheme refreshWallpaperIfPattern:self.view];
        [self.tableView reloadData];
    }
}

#pragma mark - Table

typedef NS_ENUM(NSInteger, MVMoreSection) {
    MVMoreSectionGeneral = 0,   // language, appearance, wallpaper
    MVMoreSectionBrowser,
    MVMoreSectionDownloads,
    MVMoreSectionStorage,       // free space + clear cache
    MVMoreSectionAbout,
};

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionGeneral:   return 3;
        case MVMoreSectionBrowser:   return 3;
        case MVMoreSectionDownloads: return 3;
        case MVMoreSectionStorage:   return 2;
        case MVMoreSectionAbout:     return 4;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionGeneral:   return [MVLang t:@"General"];
        case MVMoreSectionBrowser:   return [MVLang t:@"Browser"];
        case MVMoreSectionDownloads: return [MVLang t:@"Download engine"];
        case MVMoreSectionStorage:   return [MVLang t:@"Storage"];
        case MVMoreSectionAbout:     return [MVLang t:@"About"];
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return title.length ? 44 : 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    UIView *box = [UIView new];
    box.backgroundColor = UIColor.clearColor;
    if (!title.length) return box;

    MVSectionHeader *header = [MVSectionHeader new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.title = title;
    [box addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:30],
        [header.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-30],
        [header.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
    ]];
    return box;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 2;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [UIView new];
}

/// The mask bits a row needs so all cells of one section merge into a single
/// card: the first row rounds the top corners, the last rounds the bottom.
- (void)applyCardStyleToCell:(MVSettingsCell *)cell section:(NSInteger)section row:(NSInteger)row {
    NSInteger rows = [self tableView:self.tableView numberOfRowsInSection:section];
    UIRectCorner corners = 0;
    if (row == 0)            corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
    if (row == rows - 1)     corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
    cell.maskedCorners = corners;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCell forIndexPath:indexPath];
    [cell setHasChevron:NO];

    switch (indexPath.section) {
        case MVMoreSectionGeneral: {
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Language"];
                cell.subtitleLabel.text = [MVLang displayNameForCode:MVLang.shared.code];
                [cell configureIcon:@"globe" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else if (indexPath.row == 1) {
                cell.titleLabel.text = [MVLang t:@"Appearance"];
                cell.subtitleLabel.text = [self modeName];
                [self attachToRight:cell view:[self modeBadge]];
                [cell configureIcon:@"paintpalette.fill" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else {
                cell.titleLabel.text = [MVLang t:@"Wallpaper"];
                cell.subtitleLabel.text = [MVLang t:[self wallpaperLabelForKey:MVTheme.wallpaperName]];
                [self attachToRight:cell view:[self wallpaperSwatchViewForName:MVTheme.wallpaperName]];
                [cell configureIcon:@"photo.on.rectangle.angled" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            }
            break;
        }
        case MVMoreSectionBrowser: {
            MVDownloadManager *manager = MVDownloadManager.shared;
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Ad and popup blocking"];
                cell.subtitleLabel.text = MVAdBlocker.shared.enabled ? [MVLang t:@"On"] : [MVLang t:@"Off"];
                [cell configureIcon:@"shield.lefthalf.filled" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else if (indexPath.row == 1) {
                cell.titleLabel.text = [MVLang t:@"Clear browser data"];
                cell.subtitleLabel.text = self.clearingBrowserData ? [MVLang t:@"Clearing…"] : [MVLang t:@"Tap to clear"];
                [cell configureIcon:@"safari.fill" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else {
                cell.titleLabel.text = [MVLang t:@"Wi-Fi only"];
                cell.subtitleLabel.text = manager.wifiOnly ? [MVLang t:@"On · Wait for Wi-Fi"] : [MVLang t:@"Off"];
                [cell configureIcon:@"wifi" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            }
            break;
        }
        case MVMoreSectionDownloads: {
            MVDownloadManager *manager = MVDownloadManager.shared;
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Connections per download"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)manager.maxConnections];
                [cell configureIcon:@"arrow.triangle.branch" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else if (indexPath.row == 1) {
                cell.titleLabel.text = [MVLang t:@"Concurrent downloads"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)manager.maxConcurrentTasks];
                [cell configureIcon:@"square.stack.3d.up.fill" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else {
                cell.titleLabel.text = [MVLang t:@"Speed limit"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%@ · %@", [self speedLimitLabel], [MVLang t:@"Direct files only"]];
                [cell configureIcon:@"speedometer" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            }
            break;
        }
        case MVMoreSectionStorage: {
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Storage"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%@ %@ · %@ %@",
                                           [MVPaths formatBytes:[MVPaths freeSpace]], [MVLang t:@"available"],
                                           [MVPaths formatBytes:[MVPaths totalSpace]], [MVLang t:@"total"]];
                [cell configureIcon:@"internaldrive.fill" tint:[MVTheme iconTint]];
            } else {
                cell.titleLabel.text = [MVLang t:@"Clear cache"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%@ — %@", [MVPaths formatBytes:[self cacheSize]], [MVLang t:@"Tap to clear"]];
                [cell configureIcon:@"trash.fill" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            }
            break;
        }
        case MVMoreSectionAbout: {
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Version"];
                cell.subtitleLabel.text = [self engineVersion];
                [cell configureIcon:@"info.circle.fill" tint:[MVTheme iconTint]];
            } else if (indexPath.row == 1) {
                cell.titleLabel.text = [MVLang t:@"Developer"];
                cell.subtitleLabel.text = @"Mohammed-Mutar 🇮🇶";
                [cell configureIcon:@"person.crop.circle.fill" tint:[MVTheme iconTint]];
            } else if (indexPath.row == 2) {
                cell.titleLabel.text = [MVLang t:@"Share logs"];
                cell.subtitleLabel.text = [MVLang t:@"Send the log to the developer"];
                [cell configureIcon:@"doc.text.magnifyingglass" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            } else {
                cell.titleLabel.text = [MVLang t:@"Contact"];
                cell.subtitleLabel.text = [MVLang t:@"Follow me on social media"];
                [cell configureIcon:@"at" tint:[MVTheme iconTint]];
                [cell setHasChevron:YES];
            }
            break;
        }
    }
    [self applyCardStyleToCell:cell section:indexPath.section row:indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case MVMoreSectionGeneral:
            if (indexPath.row == 0) [self showLanguageMenu];
            else if (indexPath.row == 1) [self showAppearanceMenu];
            else [self showWallpaperMenu];
            break;
        case MVMoreSectionBrowser:
            if (indexPath.row == 0) [self toggleAdBlock];
            else if (indexPath.row == 1) [self confirmClearBrowserData];
            else [self toggleWifiOnly];
            break;
        case MVMoreSectionDownloads:
            if (indexPath.row == 0) [self showConnectionsMenu];
            else if (indexPath.row == 1) [self showConcurrentMenu];
            else [self showSpeedLimitMenu];
            break;
        case MVMoreSectionStorage:
            if (indexPath.row == 1) [self clearCache];
            break;
        case MVMoreSectionAbout:
            if (indexPath.row == 2) [self shareLogs];
            else if (indexPath.row == 3) [self showContactSheet];
            break;
        default:
            break;
    }
}

#pragma mark - Browser & download settings

- (NSString *)speedLimitLabel {
    long long limit = MVDownloadManager.shared.speedLimit;
    if (limit <= 0) return [MVLang t:@"Unlimited"];
    return [NSString stringWithFormat:@"%@/s", [MVPaths formatBytes:limit]];
}

- (void)toggleAdBlock {
    MVAdBlocker.shared.enabled = !MVAdBlocker.shared.enabled;
    [self.tableView reloadData];
}

- (void)toggleWifiOnly {
    BOOL enabled = MVDownloadManager.shared.wifiOnly;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Wi-Fi only"]
        message:[MVLang t:@"Downloads wait for Wi-Fi and active transfers are stopped when the connection changes. Python downloads stop cooperatively, so some data may still transfer before they pause. Browsing and other requests are not restricted."]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:(enabled ? @"Turn off" : @"Turn on")]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            MVDownloadManager.shared.wifiOnly = !enabled;
            [self.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showConnectionsMenu {
    NSArray<NSNumber *> *options = @[@1, @2, @4, @6, @8, @12, @16];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Connections per download"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%@%@", value, (value.integerValue == (NSInteger)MVDownloadManager.shared.maxConnections) ? @" ✓" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            MVDownloadManager.shared.maxConnections = value.unsignedIntegerValue;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)showConcurrentMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Concurrent downloads"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *value in @[@1, @2, @3, @4, @5]) {
        NSString *title = [NSString stringWithFormat:@"%@%@", value, (value.integerValue == (NSInteger)MVDownloadManager.shared.maxConcurrentTasks) ? @" ✓" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            MVDownloadManager.shared.maxConcurrentTasks = value.unsignedIntegerValue;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)showSpeedLimitMenu {
    NSArray<NSArray *> *options = @[
        @[[MVLang t:@"Unlimited"], @0],
        [@[[NSString stringWithFormat:@"256 KB/s"], @(256 * 1024)] mutableCopy],
        [@[[NSString stringWithFormat:@"512 KB/s"], @(512 * 1024)] mutableCopy],
        [@[[NSString stringWithFormat:@"1 MB/s"], @(1024 * 1024)] mutableCopy],
        [@[[NSString stringWithFormat:@"2 MB/s"], @(2 * 1024 * 1024)] mutableCopy],
        [@[[NSString stringWithFormat:@"5 MB/s"], @(5 * 1024 * 1024)] mutableCopy],
    ];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Speed limit"]
        message:[MVLang t:@"An approximate limit per direct HTTP download. HLS, DASH, torrents and yt-dlp are not limited. Restart a direct download after enabling the limit."]
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *option in options) {
        long long value = [option[1] longLongValue];
        NSString *title = [NSString stringWithFormat:@"%@%@", option[0], (value == MVDownloadManager.shared.speedLimit) ? @" ✓" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            MVDownloadManager.shared.speedLimit = value;
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)presentSheet:(UIAlertController *)sheet {
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                                self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

/// Website data, detected links and history are cleared; favorites (including
/// their saved URLs), downloads, open tabs and diagnostic logs are retained.
- (void)confirmClearBrowserData {
    if (self.clearingBrowserData) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Clear browser data"]
                                                                  message:[MVLang t:@"This removes website cookies, cache and storage, detected links, and browsing history except favorites. Favorites and downloads, including their links, open tabs and diagnostic logs remain. Active tabs or downloads may create new data."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Clear browser data"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        self.clearingBrowserData = YES;
        [self.tableView reloadData];
        [MVMediaProbe beginClearingBrowserCookies];
        [MVSnifferStore.shared clearAll];
        [MVBrowserHistory.shared clearHistory];
        // Older versions used Foundation's shared session as well as WebKit;
        // clear its cookies and HTTP cache too. New downloader sessions do not
        // read/write those shared stores.
        NSHTTPCookieStorage *sharedCookies = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in sharedCookies.cookies) [sharedCookies deleteCookie:cookie];
        [NSURLCache.sharedURLCache removeAllCachedResponses];
        WKWebsiteDataStore *store = WKWebsiteDataStore.defaultDataStore;
        NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
        NSDate *epoch = [NSDate dateWithTimeIntervalSince1970:0];
        [store removeDataOfTypes:types modifiedSince:epoch completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [MVMediaProbe finishClearingBrowserCookies];
                self.clearingBrowserData = NO;
                [self.tableView reloadData];
                MVLogInfo(@"settings: browser data cleared");
                if (!self.view.window) return;
                UIAlertController *done = [UIAlertController alertControllerWithTitle:[MVLang t:@"Browser data cleared"]
                                                                             message:nil
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Close"] style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:done animated:YES completion:nil];
            });
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Warn that pattern-based redaction cannot recognize every personal detail.
- (void)shareLogs {
    if (self.preparingLogs) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Share logs"]
                                                                  message:[MVLang t:@"Links and common credentials are redacted where recognized, but logs may still contain sensitive information and file names. Share only with someone you trust."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self prepareAndShareLogs];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)prepareAndShareLogs {
    self.preparingLogs = YES;
    [MVLog prepareRedactedLogsWithCompletion:^(NSArray<NSURL *> *urls, NSError *error) {
        self.preparingLogs = NO;
        if (!self.view.window) {
            if (urls.count) [NSFileManager.defaultManager removeItemAtURL:urls.firstObject.URLByDeletingLastPathComponent error:nil];
            return;
        }
        if (error || !urls.count) {
            NSString *message = error ? [MVLang t:@"Could not prepare logs"] : [MVLang t:@"No files"];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Share logs"]
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Close"] style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        NSURL *directory = urls.firstObject.URLByDeletingLastPathComponent;
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
        share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *activityError) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        };
        share.popoverPresentationController.sourceView = self.view;
        share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                                    self.view.bounds.size.height / 2, 1, 1);
        [self presentViewController:share animated:YES completion:nil];
    }];
}

- (void)showContactSheet {
    MVContactSheetViewController *sheet = [MVContactSheetViewController new];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pc = sheet.sheetPresentationController;
        pc.prefersGrabberVisible = NO;
        pc.preferredCornerRadius = 28;
        // A small, quiet pop-up rather than a full-height page. The medium detent
        // is available from iOS 15, the app's floor, so no higher guard is needed.
        pc.detents = @[UISheetPresentationControllerDetent.mediumDetent];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showLanguageMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Language"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = MVLang.shared.code;
    for (NSString *code in [MVLang availableCodes]) {
        NSString *label = [MVLang displayNameForCode:code];
        UIAlertAction *action = [UIAlertAction actionWithTitle:label
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *a) {
            MVLang.shared.code = code;
            [self refresh];
        }];
        if ([code isEqualToString:current]) {
            [action setValue:[UIImage systemImageNamed:@"checkmark"] forKey:@"image"];
        }
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 200, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showAppearanceMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Appearance"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *modes = @[
        @[@"Dark", @(MVThemeModeDark), @"moon.fill"],
        @[@"Light", @(MVThemeModeLight), @"sun.max.fill"],
        @[@"System", @(MVThemeModeSystem), @"circle.lefthalf.filled"],
    ];
    for (NSArray *mode in modes) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:[MVLang t:mode[0]]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *a) {
            MVTheme.shared.mode = [mode[1] integerValue];
            [self refresh];
        }];
        [action setValue:[UIImage systemImageNamed:mode[2]] forKey:@"image"];
        if (MVTheme.shared.mode == [mode[1] integerValue]) {
            [action setValue:[UIImage systemImageNamed:@"checkmark"] forKey:@"image"];
        }
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 200, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showWallpaperMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Wallpaper"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = MVTheme.wallpaperName;
    for (NSString *key in MVTheme.wallpaperNames) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:[MVLang t:[self wallpaperLabelForKey:key]]
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *a) {
            [MVTheme setWallpaperName:key];
            [self refresh];
        }];
        if ([key isEqualToString:current]) {
            [action setValue:[UIImage systemImageNamed:@"checkmark"] forKey:@"image"];
        }
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 200, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Wallpapers

- (NSString *)wallpaperLabelForKey:(NSString *)key {
    NSDictionary *labels = @{
        @"classic":  @"Classic",
        @"midnight": @"Midnight",
        @"aurora":   @"Aurora",
        @"sunset":   @"Sunset",
        @"ocean":    @"Ocean",
        @"forest":   @"Forest",
        @"graphite": @"Graphite",
        @"neon":     @"Neon",
        @"cosmic":   @"Cosmic",
        @"waves":    @"Waves",
    };
    return labels[key] ?: key;
}

- (NSString *)modeName {
    switch (MVTheme.shared.mode) {
        case MVThemeModeDark:  return [MVLang t:@"Dark"];
        case MVThemeModeLight: return [MVLang t:@"Light"];
        default:               return [MVLang t:@"System"];
    }
}

/// Puts the given accessory into the cell's trailing slot, centering it.
- (void)attachToRight:(MVSettingsCell *)cell view:(UIView *)view {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.rightView addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.centerXAnchor constraintEqualToAnchor:cell.rightView.centerXAnchor],
        [view.centerYAnchor constraintEqualToAnchor:cell.rightView.centerYAnchor],
    ]];
}

/// The pill that shows the current appearance mode next to "Appearance".
- (UIView *)modeBadge {
    UILabel *label = [UILabel new];
    label.text = self.modeName;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    UIView *badge = [[UIView alloc] initWithFrame:CGRectZero];
    badge.backgroundColor = [MVTheme accent];
    badge.layer.cornerRadius = 11;
    [badge addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:-12],
        [badge.heightAnchor constraintEqualToConstant:24],
    ]];
    return badge;
}

// A small reusable preview swatch (gradient or rendered pattern).
- (UIView *)wallpaperSwatchViewForName:(NSString *)key {
    UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    swatch.layer.cornerRadius = 9;
    swatch.layer.masksToBounds = YES;
    swatch.layer.borderWidth = 0.5;
    swatch.layer.borderColor = [MVTheme cardBorder].CGColor;

    CGSize sz = CGSizeMake(34, 34);
    if ([MVTheme wallpaperUsesImage:key]) {
        UIImage *img = [MVTheme wallpaperImageForName:key size:sz];
        if (img) {
            UIImageView *iv = [[UIImageView alloc] initWithFrame:swatch.bounds];
            iv.image = img;
            iv.contentMode = UIViewContentModeScaleAspectFill;
            [swatch addSubview:iv];
            return swatch;
        }
    }
    NSArray<UIColor *> *colors = [MVTheme wallpaperColorsForName:key];
    if (colors.count) {
        CAGradientLayer *grad = [CAGradientLayer layer];
        NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
        for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
        grad.colors = cg;
        if (colors.count > 1) {
            NSMutableArray *loc = [NSMutableArray array];
            for (NSUInteger i = 0; i < colors.count; i++) [loc addObject:@((CGFloat)i / (colors.count - 1))];
            grad.locations = loc;
        }
        grad.startPoint = CGPointMake(0.5, 0);
        grad.endPoint = CGPointMake(0.5, 1);
        grad.frame = swatch.bounds;
        [swatch.layer addSublayer:grad];
    }
    return swatch;
}

#pragma mark - Engine info

- (NSString *)engineVersion {
    NSDictionary *info = [[MVPython shared] engineInfo];
    NSString *v = info[@"yt_dlp"];
    return v.length ? v : [MVLang t:@"Not available"];
}

- (long long)cacheSize {
    NSString *dir = [MVPaths cache];
    long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:dir];
    for (NSString *name in e) {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        total += [attrs[NSFileSize] longLongValue];
    }
    return total;
}

- (void)clearCache {
    NSString *dir = [MVPaths cache];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *name in names) {
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    }
    [self refresh];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Cache cleared"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
