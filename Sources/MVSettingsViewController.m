#import "MVSettingsViewController.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVPython.h"

static NSString *const kCell = @"MVCell";

@interface MVSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation MVSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"More"];

    // A plain full-width list so the More screen scrolls like the Downloads and
    // Files lists and doesn't look like a floating inset panel.
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 54;
    self.tableView.tableFooterView = [UIView new];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kCell];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:MVLangDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
                                               name:MVThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    self.title = [MVLang t:@"More"];
    [MVTheme applyWallpaperTo:self.view];
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
        case MVMoreSectionAbout:      return 1;
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

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (!title.length) {
        UIView *pad = [UIView new];
        pad.backgroundColor = UIColor.clearColor;
        return pad;
    }
    UILabel *label = [UILabel new];
    label.text = title.uppercaseString;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [MVTheme secondaryText];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *box = [UIView new];
    box.backgroundColor = UIColor.clearColor;
    [box addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-20],
        [label.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
    ]];
    return box;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView titleForHeaderInSection:section].length ? 40 : 8;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == MVMoreSectionAbout ? 24 : 4;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [UIView new];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCell forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.textProperties.color = [MVTheme text];
    content.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    cell.backgroundColor = UIColor.clearColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == MVMoreSectionLanguage) {
        content.text = [MVLang t:@"Language"];
        content.secondaryText = [MVLang displayNameForCode:MVLang.shared.code];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionAppearance) {
        content.text = [MVLang t:@"Appearance"];
        cell.accessoryView = [self modeLabel];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionWallpaper) {
        content.text = [MVLang t:@"Wallpaper"];
        // Current wallpaper name plus a small preview swatch.
        NSString *key = MVTheme.wallpaperName;
        content.secondaryText = [MVLang t:[self wallpaperLabelForKey:key]];
        cell.accessoryView = [self wallpaperSwatchViewForName:key];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionStorage) {
        if (indexPath.row == 0) {
            content.text = [MVLang t:@"Storage"];
            content.secondaryText = [NSString stringWithFormat:@"%@ %@", [MVPaths formatBytes:[MVPaths freeSpace]], [MVLang t:@"available"]];
        } else {
            content.text = [MVLang t:@"Clear cache"];
            content.secondaryText = [MVPaths formatBytes:[self cacheSize]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        content.text = [MVLang t:@"Version"];
        content.secondaryText = [self engineVersion];
    }
    cell.contentConfiguration = content;
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
        default:
            break;
    }
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

// The label that shows the current theme next to the "Appearance" row.
- (UIView *)modeLabel {
    UILabel *label = [UILabel new];
    switch (MVTheme.shared.mode) {
        case MVThemeModeDark:  label.text = [MVLang t:@"Dark"];  break;
        case MVThemeModeLight: label.text = [MVLang t:@"Light"]; break;
        default:               label.text = [MVLang t:@"System"]; break;
    }
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = [MVTheme secondaryText];
    [label sizeToFit];
    return label;
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
