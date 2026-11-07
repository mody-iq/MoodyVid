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

@interface MVSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
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

    // A credit line pinned to the bottom of the screen. It must sit outside the
    // table so it never scrolls away: the About section is the last one, but
    // users still scrolled it off while reading the rows above.
    self.footerLabel = [UILabel new];
    self.footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerLabel.text = [MVLang t:@"Made with love"];
    self.footerLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.footerLabel.textColor = [MVTheme secondaryText];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.footerLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.footerLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.footerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.footerLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
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
                cell.subtitleLabel.text = @"Moh.mutar7@gmail.com";
                [cell configureIcon:@"envelope.fill" tint:[MVTheme warning]];
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
            if (indexPath.row == 2) [self copyDeveloperEmail];
            break;
        default:
            break;
    }
}

- (void)copyDeveloperEmail {
    UIPasteboard.generalPasteboard.string = @"Moh.mutar7@gmail.com";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Copied"]
                                                                  message:@"Moh.mutar7@gmail.com"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
