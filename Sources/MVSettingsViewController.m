#import "MVSettingsViewController.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVPython.h"

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
/// both the sheet and its links follow; `url` opens the profile, and the app
/// scheme in front of it lets iOS jump straight into the app when it is
/// installed, falling back to the web page otherwise.
static NSArray<NSDictionary *> *MVContactAccounts(void) {
    return @[
        @{ @"name": @"Instagram", @"handle": @"mohammed.mutar",
           @"icon": @"camera.fill", @"url": @"https://instagram.com/mohammed.mutar",
           @"scheme": @"instagram://user?username=mohammed.mutar",
           @"r": @0.93, @"g": @0.36, @"b": @0.55 },
        @{ @"name": @"Facebook", @"handle": @"Mohammed Mutar",
           @"icon": @"f.circle.fill", @"url": @"https://facebook.com/mohammed.mutar",
           @"scheme": @"fb://profile/mohammed.mutar",
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
        _iconBack.layer.cornerRadius = 12;
        _iconBack.layer.masksToBounds = YES;
        [_card addSubview:_iconBack];

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.image = [UIImage systemImageNamed:account[@"icon"]];
        _icon.tintColor = brand;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIFontWeightSemibold];
        [_card addSubview:_icon];

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
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.card.backgroundColor = [[MVTheme card] colorWithAlphaComponent:highlighted ? 0.85 : 0.55];
    }];
}

@end

/// The small pop-up shown by the Contact row: a frosted sheet listing the social
/// accounts, each row opening the profile in its app (or the browser).
@interface MVContactSheetViewController : UIViewController
@end

@implementation MVContactSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // A frosted, quiet sheet: a soft material behind a small stack of accounts,
    // no loud colours — the tint is only on the icon chips.
    self.view.backgroundColor = UIColor.clearColor;
    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
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
    MVMoreSectionLanguage = 0,
    MVMoreSectionAppearance,
    MVMoreSectionWallpaper,
    MVMoreSectionStorage,
    MVMoreSectionAbout,
};

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionLanguage:   return 1;
        case MVMoreSectionAppearance: return 1;
        case MVMoreSectionWallpaper:  return 1;
        case MVMoreSectionStorage:    return 2;
        case MVMoreSectionAbout:      return 3;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionStorage:    return [MVLang t:@"Storage"];
        case MVMoreSectionAbout:      return [MVLang t:@"About"];
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return title.length ? 44 : 16;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    UIView *box = [UIView new];
    box.backgroundColor = UIColor.clearColor;
    if (!title.length) return box;

    UILabel *label = [UILabel new];
    label.text = title.uppercaseString;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [MVTheme secondaryText];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:30],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-30],
        [label.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
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
        case MVMoreSectionLanguage: {
            cell.titleLabel.text = [MVLang t:@"Language"];
            cell.subtitleLabel.text = [MVLang displayNameForCode:MVLang.shared.code];
            [cell configureIcon:@"globe" tint:[MVTheme accent]];
            [cell setHasChevron:YES];
            break;
        }
        case MVMoreSectionAppearance: {
            cell.titleLabel.text = [MVLang t:@"Appearance"];
            cell.subtitleLabel.text = [self modeName];
            [self attachToRight:cell view:[self modeBadge]];
            [cell configureIcon:@"paintpalette.fill" tint:[MVTheme warning]];
            [cell setHasChevron:YES];
            break;
        }
        case MVMoreSectionWallpaper: {
            cell.titleLabel.text = [MVLang t:@"Wallpaper"];
            cell.subtitleLabel.text = [MVLang t:[self wallpaperLabelForKey:MVTheme.wallpaperName]];
            [self attachToRight:cell view:[self wallpaperSwatchViewForName:MVTheme.wallpaperName]];
            [cell configureIcon:@"photo.on.rectangle.angled" tint:[MVTheme success]];
            [cell setHasChevron:YES];
            break;
        }
        case MVMoreSectionStorage: {
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Storage"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%@ • %@ %@",
                                           [MVPaths formatBytes:[MVPaths totalSpace]],
                                           [MVPaths formatBytes:[MVPaths freeSpace]],
                                           [MVLang t:@"available"]];
                [cell configureIcon:@"internaldrive.fill" tint:[MVTheme accentSoft]];
            } else {
                cell.titleLabel.text = [MVLang t:@"Clear cache"];
                cell.subtitleLabel.text = [NSString stringWithFormat:@"%@ — %@", [MVPaths formatBytes:[self cacheSize]], [MVLang t:@"Tap to clear"]];
                [cell configureIcon:@"trash.fill" tint:[MVTheme danger]];
                [cell setHasChevron:YES];
            }
            break;
        }
        case MVMoreSectionAbout: {
            if (indexPath.row == 0) {
                cell.titleLabel.text = [MVLang t:@"Version"];
                cell.subtitleLabel.text = [self engineVersion];
                [cell configureIcon:@"info.circle.fill" tint:[MVTheme accent]];
            } else if (indexPath.row == 1) {
                cell.titleLabel.text = [MVLang t:@"Developer"];
                cell.subtitleLabel.text = @"Mohammed-Mutar 🇮🇶";
                [cell configureIcon:@"person.crop.circle.fill" tint:[MVTheme success]];
            } else {
                cell.titleLabel.text = [MVLang t:@"Contact"];
                cell.subtitleLabel.text = [MVLang t:@"Follow me on social media"];
                [cell configureIcon:@"at" tint:[MVTheme accent]];
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
        case MVMoreSectionLanguage:
            [self showLanguageMenu];
            break;
        case MVMoreSectionAppearance:
            [self showAppearanceMenu];
            break;
        case MVMoreSectionWallpaper:
            [self showWallpaperMenu];
            break;
        case MVMoreSectionStorage:
            if (indexPath.row == 1) [self clearCache];
            break;
        case MVMoreSectionAbout:
            if (indexPath.row == 2) [self showContactSheet];
            break;
        default:
            break;
    }
}

- (void)showContactSheet {
    MVContactSheetViewController *sheet = [MVContactSheetViewController new];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pc = sheet.sheetPresentationController;
        pc.prefersGrabberVisible = NO;
        pc.preferredCornerRadius = 28;
        if (@available(iOS 16.0, *)) {
            // A small, quiet pop-up that hugs its content, not a full-height page.
            pc.detents = @[[UISheetPresentationControllerDetent customDetentWithResolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                return 330.0;
            }]];
        } else {
            pc.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        }
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
