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
    self.view.backgroundColor = [MVTheme background];
    self.title = [MVLang t:@"More"];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
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
        case MVMoreSectionAppearance: return 3;
        case MVMoreSectionWallpaper:  return MVTheme.wallpaperNames.count;
        case MVMoreSectionStorage:    return 2;
        case MVMoreSectionAbout:      return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionLanguage:   return [MVLang t:@"Language"];
        case MVMoreSectionAppearance: return [MVLang t:@"Appearance"];
        case MVMoreSectionWallpaper:  return [MVLang t:@"Wallpaper"];
        case MVMoreSectionStorage:    return [MVLang t:@"Storage"];
        case MVMoreSectionAbout:      return [MVLang t:@"About"];
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCell forIndexPath:indexPath];
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.textProperties.color = [MVTheme text];
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == MVMoreSectionLanguage) {
        content.text = [MVLang t:@"Language"];
        content.secondaryText = [MVLang displayNameForCode:MVLang.shared.code];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionAppearance) {
        NSArray *modes = @[@[@"Dark", @(MVThemeModeDark)], @[@"Light", @(MVThemeModeLight)], @[@"System", @(MVThemeModeSystem)]];
        content.text = [MVLang t:modes[indexPath.row][0]];
        if (MVTheme.shared.mode == [modes[indexPath.row][1] integerValue]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = [MVTheme accent];
        }
    } else if (indexPath.section == MVMoreSectionWallpaper) {
        NSArray<NSString *> *names = MVTheme.wallpaperNames;
        NSString *key = names[indexPath.row];
        content.text = [MVLang t:[self wallpaperLabelForKey:key]];
        if ([MVTheme.wallpaperName isEqualToString:key]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = [MVTheme accent];
        } else {
            // A small swatch preview so the choice is not abstract.
            NSArray<UIColor *> *swatchColors = [self wallpaperSwatchForKey:key];
            if (swatchColors.count == 2) {
                CAGradientLayer *grad = [CAGradientLayer layer];
                grad.colors = @[(id)swatchColors[0].CGColor, (id)swatchColors[1].CGColor];
                grad.startPoint = CGPointMake(0.5, 0);
                grad.endPoint = CGPointMake(0.5, 1);
                UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
                swatch.layer.cornerRadius = 8;
                swatch.layer.masksToBounds = YES;
                grad.frame = swatch.bounds;
                [swatch.layer addSublayer:grad];
                cell.accessoryView = swatch;
            }
        }
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
        case MVMoreSectionAppearance: {
            NSArray *modes = @[@(MVThemeModeDark), @(MVThemeModeLight), @(MVThemeModeSystem)];
            MVTheme.shared.mode = [modes[indexPath.row] integerValue];
            [self refresh];
            break;
        }
        case MVMoreSectionWallpaper: {
            [MVTheme setWallpaperName:MVTheme.wallpaperNames[indexPath.row]];
            [self refresh];
            break;
        }
        case MVMoreSectionStorage:
            if (indexPath.row == 1) [self clearCache];
            break;
        default:
            break;
    }
}

- (void)showLanguageMenu {
    // A checkmark per row is clearer than a sheet on iPad, and it is one tap.
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

#pragma mark - Wallpapers

- (NSString *)wallpaperLabelForKey:(NSString *)key {
    NSDictionary *labels = @{
        @"classic":  @"Classic",
        @"midnight": @"Midnight",
        @"aurora":   @"Aurora",
        @"sunset":   @"Sunset",
        @"forest":   @"Forest",
    };
    return labels[key] ?: key;
}

// A two-colour swatch preview. Uses the dynamic wallpaper colours so the swatch
// matches whatever appearance the app is currently in.
- (NSArray<UIColor *> *)wallpaperSwatchForKey:(NSString *)key {
    UIColor *start = [[MVTheme wallpaperStartForName:key]
                      resolvedColorWithTraitCollection:UITraitCollection.currentTraitCollection];
    UIColor *end = [[MVTheme wallpaperEndForName:key]
                    resolvedColorWithTraitCollection:UITraitCollection.currentTraitCollection];
    return @[start, end];
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
