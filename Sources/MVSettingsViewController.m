#import "MVSettingsViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVPython.h"
#import "MVBrowserViewController.h"
#import "MVBrowserHistory.h"

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
    [self.tableView reloadData];
}

#pragma mark - Table

// Sections, in order: Premium, Browsing, Language, Appearance, Engine, Storage,
// Security. Keeping the numbers in one place makes the cell and the selection
// code agree on what a row means.
typedef NS_ENUM(NSInteger, MVMoreSection) {
    MVMoreSectionPremium = 0,
    MVMoreSectionBrowsing,
    MVMoreSectionLanguage,
    MVMoreSectionAppearance,
    MVMoreSectionEngine,
    MVMoreSectionStorage,
    MVMoreSectionSecurity,
};

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 7; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionPremium:    return 1;
        case MVMoreSectionBrowsing:   return 2;   // Favorites, History
        case MVMoreSectionLanguage:   return 1;
        case MVMoreSectionAppearance: return 3;
        case MVMoreSectionEngine:     return 2;
        case MVMoreSectionStorage:    return 2;
        case MVMoreSectionSecurity:   return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case MVMoreSectionBrowsing:   return [MVLang t:@"Browser"];
        case MVMoreSectionLanguage:   return [MVLang t:@"Language"];
        case MVMoreSectionAppearance: return [MVLang t:@"Appearance"];
        case MVMoreSectionEngine:     return [MVLang t:@"Download engine"];
        case MVMoreSectionStorage:    return [MVLang t:@"Storage"];
        case MVMoreSectionSecurity:   return [MVLang t:@"Security"];
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
    cell.backgroundColor = [MVTheme card];

    if (indexPath.section == MVMoreSectionPremium) {
        content.text = [MVLang t:@"Premium"];
        content.secondaryText = [MVLang t:@"Remove ads and unlock more"];
        content.image = [UIImage systemImageNamed:@"crown.fill"];
        content.imageProperties.tintColor = [MVTheme warning];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionBrowsing) {
        if (indexPath.row == 0) {
            content.text = [MVLang t:@"Favorites"];
            content.secondaryText = [NSString stringWithFormat:@"%lu", (unsigned long)MVBrowserHistory.shared.favorites.count];
            content.image = [UIImage systemImageNamed:@"star.fill"];
            content.imageProperties.tintColor = [MVTheme warning];
        } else {
            content.text = [MVLang t:@"History"];
            content.secondaryText = [NSString stringWithFormat:@"%lu", (unsigned long)MVBrowserHistory.shared.history.count];
            content.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
            content.imageProperties.tintColor = [MVTheme accent];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == MVMoreSectionLanguage) {
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
    } else if (indexPath.section == MVMoreSectionEngine) {
        if (indexPath.row == 0) {
            content.text = [MVLang t:@"Version"];
            content.secondaryText = [self engineVersion];
        } else {
            content.text = [MVLang t:@"JavaScript engine"];
            content.secondaryText = [self javascriptStatus];
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
        content.text = [MVLang t:@"Passcode lock"];
        UISwitch *toggle = [UISwitch new];
        toggle.onTintColor = [MVTheme accent];
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:@"MVPasscodeLock"];
        [toggle addTarget:self action:@selector(togglePasscode:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case MVMoreSectionPremium:
            [self showPremium];
            break;
        case MVMoreSectionBrowsing:
            [self showBookmarksFavorites:indexPath.row == 0];
            break;
        case MVMoreSectionLanguage:
            [self showLanguageMenu];
            break;
        case MVMoreSectionAppearance: {
            NSArray *modes = @[@(MVThemeModeDark), @(MVThemeModeLight), @(MVThemeModeSystem)];
            MVTheme.shared.mode = [modes[indexPath.row] integerValue];
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

/// Favorites and History share one list screen; only the source differs.
- (void)showBookmarksFavorites:(BOOL)favorites {
    NSArray<MVBrowserEntry *> *entries = favorites
        ? MVBrowserHistory.shared.favorites
        : MVBrowserHistory.shared.history;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:favorites ? @"Favorites" : @"History"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger shown = 0;
    for (MVBrowserEntry *e in entries) {
        if (shown >= 15) break;
        shown++;
        [sheet addAction:[UIAlertAction actionWithTitle:(e.title.length ? e.title : e.url)
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [MVBrowserViewController presentFrom:self url:e.url];
        }]];
    }
    if (!shown) {
        [sheet setValue:[[NSAttributedString alloc] initWithString:[MVLang t:favorites ? @"No favorites yet" : @"No history yet"]]
                 forKey:@"attributedMessage"];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 200, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

/// A plain, honest information screen. There is no paid tier yet, so this
/// explains what the app does rather than pretending to sell something.
- (void)showPremium {
    NSString *message = MVLang.shared.isRTL
        ? @"MoodyVid مجاني بالكامل.\n\n• تحميل من أكثر من 1000 موقع\n• دقة تصل إلى 4K\n• تحميل في الخلفية\n• بدون إعلانات\n\nشكراً لاستخدامك التطبيق."
        : @"MoodyVid is completely free.\n\n• Download from 1000+ sites\n• Quality up to 4K\n• Background downloads\n• No ads\n\nThanks for using the app.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Premium"]
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Close"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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

- (void)togglePasscode:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"MVPasscodeLock"];
}

#pragma mark - Engine info

- (NSString *)engineVersion {
    NSDictionary *info = [[MVPython shared] engineInfo];
    NSString *v = info[@"yt_dlp"];
    return v.length ? v : [MVLang t:@"Not available"];
}

- (NSString *)javascriptStatus {
    NSDictionary *info = [[MVPython shared] engineInfo];
    id flag = info[@"javascriptcore"];
    if ([flag respondsToSelector:@selector(boolValue)] && [flag boolValue]) return [MVLang t:@"Available"];
    if (info[@"javascriptcore_error"]) return [MVLang t:@"Not available"];
    return [MVLang t:@"Not available"];
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
