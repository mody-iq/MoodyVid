#import "MVPlaylistViewController.h"
#import "MVDownloadEngine.h"
#import "MVLang.h"
#import "MVPaths.h"
#import "MVPython.h"
#import "MVTheme.h"

@interface MVPlaylistViewController ()
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) NSMutableIndexSet *selectedEntries;
@property (nonatomic, strong) UIBarButtonItem *downloadItem;
@property (nonatomic) BOOL truncated;
@end

@implementation MVPlaylistViewController

- (instancetype)initWithURL:(NSString *)url {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _url = [url copy];
        _entries = @[];
        _selectedEntries = [NSMutableIndexSet indexSet];
    }
    return self;
}

+ (void)presentFrom:(UIViewController *)presenter url:(NSString *)url {
    MVPlaylistViewController *playlist = [[self alloc] initWithURL:url];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:playlist];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [MVLang t:@"Playlist"];
    self.tableView.backgroundColor = [MVTheme background];
    self.tableView.rowHeight = 64;
    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Cancel"]
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.downloadItem = [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Download"]
        style:UIBarButtonItemStyleDone target:self action:@selector(downloadSelected)];
    self.downloadItem.enabled = NO;
    self.navigationItem.rightBarButtonItem = self.downloadItem;
    [self showMessage:[MVLang t:@"Reading playlist…"]];
    [self loadPlaylist];
}

- (void)showMessage:(NSString *)message {
    UILabel *label = [UILabel new];
    label.text = message;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [MVTheme secondaryText];
    label.numberOfLines = 0;
    self.tableView.backgroundView = label;
}

- (void)loadPlaylist {
    __weak typeof(self) weakSelf = self;
    [[MVPython shared] call:@"downloader" function:@"inspect_playlist" args:@[self.url]
                 completion:^(NSDictionary *result, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *items = [result[@"entries"] isKindOfClass:NSArray.class] ? result[@"entries"] : @[];
        NSMutableArray *valid = [NSMutableArray array];
        for (id value in items) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *entry = value;
            NSString *address = [entry[@"url"] isKindOfClass:NSString.class] ? entry[@"url"] : nil;
            NSString *title = [entry[@"title"] isKindOfClass:NSString.class] ? entry[@"title"] : @"";
            NSURLComponents *parts = address ? [NSURLComponents componentsWithString:address] : nil;
            NSString *scheme = parts.scheme.lowercaseString;
            if (!parts.host.length || (! [scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"])) continue;
            NSNumber *duration = [entry[@"duration"] isKindOfClass:NSNumber.class] ? entry[@"duration"] : @0;
            [valid addObject:@{@"url": address, @"title": title.length ? title : address, @"duration": duration}];
            if (valid.count == 100) break;
        }
        self_.entries = valid;
        self_.truncated = [result[@"truncated"] isKindOfClass:NSNumber.class] && [result[@"truncated"] boolValue];
        NSString *title = [result[@"title"] isKindOfClass:NSString.class] ? result[@"title"] : nil;
        if (title.length) self_.title = title;
        if (valid.count) self_.tableView.backgroundView = nil;
        else [self_ showMessage:error.length ? error : [MVLang t:@"No videos found in this playlist"]];
        [self_.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.entries.count ? 2 : 0; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? [MVLang t:@"Choose videos"] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1 && self.truncated) return [MVLang t:@"Only the first 100 playlist entries are shown."];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"PlaylistItem";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.backgroundColor = [MVTheme card];
    cell.textLabel.textColor = [MVTheme text];
    cell.detailTextLabel.textColor = [MVTheme secondaryText];
    cell.tintColor = [MVTheme accent];
    if (indexPath.section == 0) {
        BOOL all = self.selectedEntries.count == self.entries.count;
        cell.textLabel.text = [MVLang t:(all ? @"Clear selection" : @"Select all")];
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        NSDictionary *entry = self.entries[indexPath.row];
        cell.textLabel.text = entry[@"title"];
        double duration = [entry[@"duration"] doubleValue];
        cell.detailTextLabel.text = duration > 0 ? [MVPaths formatDuration:duration] : @"";
        cell.accessoryType = [self.selectedEntries containsIndex:(NSUInteger)indexPath.row]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (self.selectedEntries.count == self.entries.count) [self.selectedEntries removeAllIndexes];
        else [self.selectedEntries addIndexesInRange:NSMakeRange(0, self.entries.count)];
    } else {
        NSUInteger index = (NSUInteger)indexPath.row;
        if ([self.selectedEntries containsIndex:index]) [self.selectedEntries removeIndex:index];
        else [self.selectedEntries addIndex:index];
    }
    self.downloadItem.enabled = self.selectedEntries.count > 0;
    self.downloadItem.title = [NSString stringWithFormat:@"%@ (%lu)", [MVLang t:@"Download"],
                               (unsigned long)self.selectedEntries.count];
    [tableView reloadData];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

+ (void)enqueueEntries:(NSArray<NSDictionary *> *)entries startingAt:(NSUInteger)start {
    // Small main-queue batches avoid freezing the UI while each record is saved.
    NSUInteger end = MIN(start + 4, entries.count);
    for (NSUInteger i = start; i < end; i++) {
        [MVDownloadEngine.shared downloadURL:entries[i][@"url"] quality:@"best" completion:nil];
    }
    if (end < entries.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self enqueueEntries:entries startingAt:end]; });
    }
}

- (void)downloadSelected {
    NSMutableArray *chosen = [NSMutableArray array];
    [self.selectedEntries enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.entries.count) [chosen addObject:self.entries[idx]];
    }];
    if (!chosen.count) return;
    NSArray *entries = [chosen copy];
    [self dismissViewControllerAnimated:YES completion:^{
        [MVPlaylistViewController enqueueEntries:entries startingAt:0];
        [NSNotificationCenter.defaultCenter postNotificationName:@"MVShowDownloadsTabNotification" object:nil];
    }];
}

@end
