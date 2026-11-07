#import "MVFilesViewController.h"
#import <AVKit/AVKit.h>
#import "MVPlayerCenter.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"

typedef NS_ENUM(NSInteger, MVSortMode) {
    MVSortModeName = 0,
    MVSortModeDate = 1,
    MVSortModeSize = 2,
};

@interface MVFilesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *storageLabel;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic) MVSortMode sortMode;
@end

@implementation MVFilesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme background];
    self.title = [MVLang t:@"Files"];

    UIBarButtonItem *newFolder = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"folder.badge.plus"]
                                                                style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(createFolder)];
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(showSortMenu)];
    self.navigationItem.rightBarButtonItems = @[newFolder, sort];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
    [self.tableView addGestureRecognizer:longPress];

    self.storageLabel = [UILabel new];
    self.storageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.storageLabel.textColor = [MVTheme secondaryText];
    self.storageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.storageLabel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"MVFileCell"];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.textColor = [MVTheme secondaryText];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.storageLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.storageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.storageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],

        [self.tableView.topAnchor constraintEqualToAnchor:self.storageLabel.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    for (NSString *name in @[MVDownloadStoreDidChangeNotification, MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (NSString *)currentDirectory { return self.rootOverride ?: [MVPaths downloads]; }

- (NSArray<NSString *> *)entries {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:[self currentDirectory] error:nil] ?: @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        if ([name isEqualToString:@"downloads.json"]) continue;
        if (self.filter.length && ![name localizedCaseInsensitiveContainsString:self.filter]) continue;
        [out addObject:name];
    }

    NSString *dir = [self currentDirectory];
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *pa = [dir stringByAppendingPathComponent:a];
        NSString *pb = [dir stringByAppendingPathComponent:b];
        NSDictionary *da = [fm attributesOfItemAtPath:pa error:nil] ?: @{};
        NSDictionary *db = [fm attributesOfItemAtPath:pb error:nil] ?: @{};
        BOOL dirA = [da[NSFileType] isEqual:NSFileTypeDirectory];
        BOOL dirB = [db[NSFileType] isEqual:NSFileTypeDirectory];
        // Folders always lead, whichever sort is chosen.
        if (dirA != dirB) return dirA ? NSOrderedAscending : NSOrderedDescending;
        switch (self.sortMode) {
            case MVSortModeDate: {
                NSDate *ta = da[NSFileModificationDate] ?: NSDate.distantPast;
                NSDate *tb = db[NSFileModificationDate] ?: NSDate.distantPast;
                return [tb compare:ta];
            }
            case MVSortModeSize:
                return [db[NSFileSize] longLongValue] > [da[NSFileSize] longLongValue] ? NSOrderedAscending : NSOrderedDescending;
            case MVSortModeName:
            default:
                return [a localizedStandardCompare:b];
        }
    }];
}

- (void)refresh {
    self.title = [MVLang t:@"Files"];
    self.emptyLabel.text = [MVLang t:@"No files"];
    self.search.searchBar.placeholder = [MVLang t:@"Search files"];
    self.storageLabel.text = [NSString stringWithFormat:@"%@ %@",
                              [MVPaths formatBytes:[MVPaths freeSpace]], [MVLang t:@"available"]];
    [MVTheme applyWallpaperTo:self.view];
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in [self.view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) layer.frame = self.view.bounds;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *entries = [self entries];
    self.emptyLabel.hidden = entries.count > 0;
    return entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MVFileCell" forIndexPath:indexPath];
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = name;
    content.textProperties.color = [MVTheme text];

    if (isDir) {
        content.image = [UIImage systemImageNamed:@"folder.fill"];
        content.secondaryText = [MVLang t:@"Empty folder"];
    } else {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        long long size = [attrs[NSFileSize] longLongValue];
        NSDate *date = attrs[NSFileModificationDate];
        NSString *ext = path.pathExtension.lowercaseString;
        NSString *thumbPath = [self thumbnailForPath:path];
        if (thumbPath) {
            content.image = [UIImage imageWithContentsOfFile:thumbPath];
            content.imageProperties.maximumSize = CGSizeMake(88, 50);
            content.imageProperties.cornerRadius = 8;
        } else {
            content.image = [UIImage systemImageNamed:[self symbolForExtension:ext]];
        }
        content.secondaryText = [NSString stringWithFormat:@"%@  ·  %@",
                                 [MVPaths formatBytes:size],
                                 [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
    }
    content.secondaryTextProperties.color = [MVTheme secondaryText];
    content.imageProperties.tintColor = [MVTheme accent];
    cell.contentConfiguration = content;
    cell.backgroundColor = [MVTheme card];
    return cell;
}

- (NSString *)symbolForExtension:(NSString *)ext {
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"] || [ext isEqualToString:@"mkv"] || [ext isEqualToString:@"webm"]) return @"play.rectangle.fill";
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp3"] || [ext isEqualToString:@"aac"] || [ext isEqualToString:@"opus"]) return @"waveform";
    if ([ext isEqualToString:@"pdf"]) return @"doc.richtext";
    if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"rar"]) return @"doc.zipper";
    return @"doc";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    if (isDir) {
        MVFilesViewController *sub = [MVFilesViewController new];
        sub.rootOverride = path;
        [self.navigationController pushViewController:sub animated:YES];
        return;
    }

    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext]) {
        [self playPathInQueue:path];
    } else {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:[MVLang t:@"Delete"]
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                      message:[MVLang t:@"This cannot be undone."]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            [self forgetRecordAtPath:path];
            [self refresh];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        done(YES);
    }];
    del.backgroundColor = [MVTheme danger];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

/// Keeps the Downloads list honest when a file is deleted from the Files tab.
- (void)forgetRecordAtPath:(NSString *)path {
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if ([r.path isEqualToString:path]) [MVDownloadStore.shared remove:r];
    }
}

- (void)createFolder {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"New folder"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = [MVLang t:@"Folder name"];
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Create"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
        [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    NSString *name = [self entries][indexPath.row];
    NSString *path = [[self currentDirectory] stringByAppendingPathComponent:name];
    [self showFileMenuForPath:path];
}

- (void)showFileMenuForPath:(NSString *)path {
    NSString *name = path.lastPathComponent;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL playable = [@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext];

    if (!isDir && playable) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Play"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playPathInQueue:path];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Save to Photos"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[MVDownloadEngine shared] saveToPhotos:path completion:^(NSString *fp, NSString *err) {
                if (fp && !err) {
                    [self alert:@"MoodyVid" message:[MVLang t:@"Saved to Photos"]];
                } else if (err) {
                    [self alert:[MVLang t:@"Failed"] message:err];
                }
            }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    }]];
    if (!isDir) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self promptRenamePath:path];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self confirmDeletePath:path];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeletePath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [self forgetRecordAtPath:path];
        [self refresh];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRenamePath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Rename"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = path.lastPathComponent.stringByDeletingPathExtension;
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *target = [[path stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:[name stringByAppendingPathExtension:path.pathExtension]];
        NSError *err = nil;
        if ([NSFileManager.defaultManager moveItemAtPath:path toPath:target error:&err]) {
            for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
                if ([r.path isEqualToString:path]) {
                    r.path = target;
                    [MVDownloadStore.shared update:r];
                }
            }
            [self refresh];
        } else {
            [self alert:[MVLang t:@"Failed"] message:err.localizedDescription ?: [MVLang t:@"Unknown error"]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)thumbnailForPath:(NSString *)path {
    for (MVDownloadRecord *r in MVDownloadStore.shared.records) {
        if (r.thumbnail.length && [r.path isEqualToString:path] &&
            [NSFileManager.defaultManager fileExistsAtPath:r.thumbnail]) {
            return r.thumbnail;
        }
    }
    return nil;
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSortMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[MVLang t:@"Sort by"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSArray *> *options = @[@[@"Name", @(MVSortModeName)], @[@"Date", @(MVSortModeDate)], @[@"Size", @(MVSortModeSize)]];
    for (NSArray *option in options) {
        MVSortMode mode = (MVSortMode)[option[1] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:option[0]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self.sortMode = mode;
            [self refresh];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)playPathInQueue:(NSString *)path {
    // The previous/next buttons in the player step through the visible rows of
    // this folder, ignoring subfolders and non-video files.
    NSArray<NSString *> *names = [self entries];
    NSString *dir = [self currentDirectory];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger index = 0;
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *p = [dir stringByAppendingPathComponent:names[i]];
        NSString *ext = p.pathExtension.lowercaseString;
        if (![@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav", @"webm", @"mkv"] containsObject:ext]) continue;
        [urls addObject:[NSURL fileURLWithPath:p]];
        [titles addObject:p.lastPathComponent.stringByDeletingPathExtension];
        if ([p isEqualToString:path]) index = (NSInteger)urls.count - 1;
    }
    if (!urls.count) return;
    [[MVPlayerCenter shared] playQueue:urls titles:titles fromIndex:index];
    [[MVPlayerCenter shared] presentCurrentPlayer];
}

@end
