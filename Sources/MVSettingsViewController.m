#import "MVSettingsViewController.h"
#import <AVFoundation/AVFoundation.h>
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
    self.title = [MVLang t:@"Settings"];

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
    self.title = [MVLang t:@"Settings"];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;   // Language
        case 1: return 3;   // Theme
        case 2: return 2;   // Engine
        case 3: return 2;   // Storage
        case 4: return 1;   // Security
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return [MVLang t:@"Language"];
        case 1: return [MVLang t:@"Appearance"];
        case 2: return [MVLang t:@"Download engine"];
        case 3: return [MVLang t:@"Storage"];
        case 4: return [MVLang t:@"Security"];
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

    if (indexPath.section == 0) {
        content.text = [MVLang t:@"Language"];
        content.secondaryText = MVLang.shared.isRTL ? [MVLang t:@"Arabic"] : [MVLang t:@"English"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        NSArray *modes = @[@[@"Dark", @(MVThemeModeDark)], @[@"Light", @(MVThemeModeLight)], @[@"System", @(MVThemeModeSystem)]];
        content.text = [MVLang t:modes[indexPath.row][0]];
        if (MVTheme.shared.mode == [modes[indexPath.row][1] integerValue]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = [MVTheme accent];
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            content.text = [MVLang t:@"Version"];
            content.secondaryText = [self engineVersion];
        } else {
            content.text = [MVLang t:@"JavaScript engine"];
            content.secondaryText = [self javascriptStatus];
        }
    } else if (indexPath.section == 3) {
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
    if (indexPath.section == 0) {
        [self showLanguageMenu];
    } else if (indexPath.section == 1) {
        NSArray *modes = @[@(MVThemeModeDark), @(MVThemeModeLight), @(MVThemeModeSystem)];
        MVTheme.shared.mode = [modes[indexPath.row] integerValue];
        [self refresh];
    } else if (indexPath.section == 3 && indexPath.row == 1) {
        [self clearCache];
    }
}

- (void)showLanguageMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Language"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *code in @[@"ar", @"en"]) {
        NSString *label = [code isEqualToString:@"ar"] ? [MVLang t:@"Arabic"] : [MVLang t:@"English"];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            MVLang.shared.code = code;
        }]];
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
