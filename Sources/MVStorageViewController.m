#import "MVStorageViewController.h"
#import "MVStorageScanner.h"
#import "MVTrashStore.h"
#import "MVPaths.h"
#import "MVTheme.h"
#import "MVLang.h"

@interface MVStorageViewController ()
@property (nonatomic, strong) UISegmentedControl *sections;
@property (nonatomic, copy) NSDictionary *scan;
@property (nonatomic, copy) NSArray<NSDictionary *> *trashEntries;
@property (nonatomic, strong) NSProgress *scanProgress;
@property (nonatomic) BOOL scanning;
@end

@implementation MVStorageViewController

+ (void)presentFrom:(UIViewController *)presenter {
    MVStorageViewController *controller = [[self alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [MVLang t:@"Manage storage"];
    self.tableView.backgroundColor = [MVTheme background];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    self.view.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Done"] style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(startScan)];
    self.sections = [[UISegmentedControl alloc] initWithItems:@[[MVLang t:@"Large"], [MVLang t:@"Duplicates"], [MVLang t:@"Partial"], [MVLang t:@"Trash"]]];
    self.sections.selectedSegmentIndex = 0;
    [self.sections addTarget:self action:@selector(sectionChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 55)];
    self.sections.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.sections];
    [NSLayoutConstraint activateConstraints:@[
        [self.sections.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [self.sections.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
        [self.sections.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    self.tableView.tableHeaderView = header;
    [self startScan];
}

- (void)close {
    [self.scanProgress cancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sectionChanged { [self reload]; }

- (NSArray<NSDictionary *> *)visibleEntries {
    switch (self.sections.selectedSegmentIndex) {
        case 1: return self.scan[@"duplicates"] ?: @[];
        case 2: return self.scan[@"partials"] ?: @[];
        case 3: return self.trashEntries ?: @[];
        default: return self.scan[@"large"] ?: @[];
    }
}

- (void)startScan {
    [self.scanProgress cancel];
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
    self.scanProgress = progress;
    self.scanning = YES;
    self.trashEntries = MVTrashStore.shared.entries;
    [self reload];
    NSArray *protected = [MVStorageProtection protectedPaths];
    MVStorageScanner *scanner = [[MVStorageScanner alloc] initWithRoot:MVPaths.downloads
        maximumFiles:5000 hashBudget:4ULL * 1024 * 1024 * 1024];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = [scanner scanProtecting:protected cancelled:^BOOL{ return progress.cancelled; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self_ = weakSelf;
            if (!self_ || self_.scanProgress != progress || progress.cancelled) return;
            self_.scan = result;
            self_.scanning = NO;
            self_.trashEntries = MVTrashStore.shared.entries;
            [self_ reload];
        });
    });
}

- (void)reload {
    NSArray *entries = self.visibleEntries;
    UILabel *empty = [UILabel new];
    empty.textColor = [MVTheme secondaryText];
    empty.textAlignment = NSTextAlignmentCenter;
    empty.numberOfLines = 0;
    empty.text = self.scanning && self.sections.selectedSegmentIndex != 3
        ? [MVLang t:@"Scanning files…"] : [MVLang t:@"Nothing to show"];
    self.tableView.backgroundView = entries.count ? nil : empty;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.visibleEntries.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.sections.selectedSegmentIndex == 3) return [MVLang t:@"Trash is never emptied automatically. Files deleted elsewhere may bypass it."];
    if (self.scanning) return [MVLang t:@"Scanning files…"];
    if ([self.scan[@"limited"] boolValue]) return [MVLang t:@"The scan reached its safety limit; not all files or duplicates are shown."];
    if (self.sections.selectedSegmentIndex == 1) return [MVLang t:@"Duplicates are compared by content. Nothing is deleted automatically."];
    if (self.sections.selectedSegmentIndex == 2) return [MVLang t:@"Files needed for a saved download cannot be moved."];
    return [MVLang t:@"Choose a file to move it to Trash. No files are removed automatically."];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StorageEntry"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"StorageEntry"];
    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    BOOL inTrash = self.sections.selectedSegmentIndex == 3;
    NSString *path = entry[@"path"];
    cell.textLabel.text = inTrash ? entry[@"name"] : path.lastPathComponent;
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.textColor = [MVTheme text];
    cell.detailTextLabel.textColor = [MVTheme secondaryText];
    NSString *size = [MVPaths formatBytes:[entry[@"size"] longLongValue]];
    NSMutableArray *parts = [NSMutableArray arrayWithObject:size];
    if ([entry[@"protected"] boolValue]) [parts addObject:[MVLang t:@"Needed by a download"]];
    if (entry[@"group"]) [parts addObject:[NSString stringWithFormat:@"%@ %@", [MVLang t:@"Group"], entry[@"group"]]];
    NSString *relative = inTrash ? entry[@"original"] : nil;
    if (!inTrash && [path hasPrefix:[MVPaths.downloads stringByAppendingString:@"/"]]) {
        relative = [path substringFromIndex:MVPaths.downloads.length + 1];
    }
    if (relative.length) [parts addObject:relative];
    cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    cell.detailTextLabel.numberOfLines = 2;
    cell.backgroundColor = [MVTheme card];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.visibleEntries[(NSUInteger)indexPath.row];
    if (self.sections.selectedSegmentIndex == 3) { [self showTrashActions:entry]; return; }
    NSString *path = entry[@"path"];
    if ([entry[@"protected"] boolValue]) {
        [self alert:[MVLang t:@"Needed by a download"] message:[MVLang t:@"This file is needed by a saved download. Remove its task first, or leave it in place."]];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Move to Trash?"]
        message:path.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Move to Trash"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *error = nil;
        if (![MVTrashStore.shared moveToTrash:path protecting:[MVStorageProtection protectedPaths] error:&error]) {
            [self alert:[MVLang t:@"Failed"] message:[MVLang t:error ?: @"Could not move the file to Trash."]];
        } else [self startScan];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showTrashActions:(NSDictionary *)entry {
    NSString *identifier = entry[@"identifier"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry[@"name"] message:[MVLang t:@"Restore the file or delete it permanently."] preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Restore"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *error = nil;
        NSString *path = [MVTrashStore.shared restore:identifier protecting:[MVStorageProtection protectedPaths] error:&error];
        if (!path) [self alert:[MVLang t:@"Failed"] message:[MVLang t:error ?: @"Could not restore the file."]];
        else {
            [self startScan];
            [self alert:[MVLang t:@"Restored"] message:path.lastPathComponent];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete permanently"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete permanently?"]
            message:[MVLang t:@"This cannot be undone."] preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete permanently"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSString *error = nil;
            if (![MVTrashStore.shared deletePermanently:identifier error:&error]) [self alert:[MVLang t:@"Failed"] message:[MVLang t:error ?: @"Could not delete this item."]];
            else { self.trashEntries = MVTrashStore.shared.entries; [self reload]; }
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"OK"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
