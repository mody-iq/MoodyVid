#import "MVDownloadsViewController.h"
#import <AVKit/AVKit.h>
#import "MVPlayerCenter.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"

static NSString *const kDoneCell = @"MVDoneCell";

// One row: thumbnail, title, subtitle, and a progress bar for active downloads.
@interface MVDownloadCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
- (void)configureWithRecord:(MVDownloadRecord *)record;
@end

@implementation MVDownloadCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _thumbView = [UIImageView new];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.layer.cornerRadius = 8;
        _thumbView.layer.masksToBounds = YES;
        _thumbView.clipsToBounds = YES;
        _thumbView.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.12];
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [UILabel new];
        _titleLabel.numberOfLines = 2;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [MVTheme secondaryText];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _progressBar = [UIProgressView new];
        _progressBar.progressTintColor = [MVTheme accent];
        _progressBar.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.20];
        _progressBar.translatesAutoresizingMaskIntoConstraints = NO;

        [self.contentView addSubview:_thumbView];
        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_subtitleLabel];
        [self.contentView addSubview:_progressBar];

        [self.thumbView.widthAnchor constraintEqualToConstant:88].active = YES;
        [self.thumbView.heightAnchor constraintEqualToConstant:50].active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [_thumbView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],

            [_progressBar.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_progressBar.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_progressBar.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:8],
            [_progressBar.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        ]];
    }
    return self;
}

- (void)configureWithRecord:(MVDownloadRecord *)record {
    self.titleLabel.text = record.title.length ? record.title : record.url;

    if (record.thumbnail.length && [NSFileManager.defaultManager fileExistsAtPath:record.thumbnail]) {
        UIImage *img = [UIImage imageWithContentsOfFile:record.thumbnail];
        self.thumbView.image = img ?: [UIImage systemImageNamed:@"play.rectangle.fill"];
        self.thumbView.tintColor = [MVTheme secondaryText];
    } else {
        self.thumbView.image = [UIImage systemImageNamed:@"play.rectangle.fill"];
        self.thumbView.tintColor = [MVTheme secondaryText];
    }

    BOOL showsProgress = record.isActive || record.state == MVDownloadStateWaiting;
    self.progressBar.hidden = !showsProgress;

    switch (record.state) {
        case MVDownloadStateWaiting:
            self.subtitleLabel.text = [MVLang t:@"Waiting"];
            self.progressBar.progress = 0;
            break;
        case MVDownloadStateActive: {
            // Percent, speed and ETA are what make the bar feel alive.
            NSMutableArray *parts = [NSMutableArray array];
            [parts addObject:[NSString stringWithFormat:@"%.0f%%", record.progress * 100]];
            if (record.speed > 0) [parts addObject:[MVPaths formatSpeed:record.speed]];
            if (record.eta > 0) [parts addObject:[NSString stringWithFormat:@"ETA %@", [MVPaths formatDuration:record.eta]]];
            if (record.totalBytes > 0) [parts addObject:[MVPaths formatBytes:record.totalBytes]];
            self.subtitleLabel.text = [parts componentsJoinedByString:@"  ·  "];
            self.progressBar.progress = record.progress;
            break;
        }
        case MVDownloadStateCompleted:
            self.subtitleLabel.text = record.totalBytes > 0
                ? [MVPaths formatBytes:record.totalBytes]
                : [MVLang t:@"Completed"];
            break;
        case MVDownloadStateFailed:
            self.subtitleLabel.text = [NSString stringWithFormat:@"%@: %@", [MVLang t:@"Failed"],
                                       record.error ?: [MVLang t:@"Unknown error"]];
            break;
        case MVDownloadStateCancelled:
            self.subtitleLabel.text = [MVLang t:@"Cancel"];
            break;
    }
    self.subtitleLabel.textColor = record.state == MVDownloadStateFailed
        ? [MVTheme danger] : [MVTheme secondaryText];
}

@end

@interface MVDownloadsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *filter;
@end

@implementation MVDownloadsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme background];
    self.title = [MVLang t:@"Downloads"];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96;
    [self.tableView registerClass:MVDownloadCell.class forCellReuseIdentifier:kDoneCell];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRow:)];
    [self.tableView addGestureRecognizer:longPress];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = [MVLang t:@"No downloads yet"];
    self.emptyLabel.textColor = [MVTheme secondaryText];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = [MVLang t:@"Search downloads"];
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    for (NSString *name in @[MVDownloadStoreDidChangeNotification, MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
}

- (void)refresh {
    self.title = [MVLang t:@"Downloads"];
    self.emptyLabel.text = [MVLang t:@"No downloads yet"];
    self.search.searchBar.placeholder = [MVLang t:@"Search downloads"];
    [self.tableView reloadData];
}

- (NSArray<MVDownloadRecord *> *)records {
    // One list, newest first, with whatever is still downloading pinned to the
    // top so it is the first thing seen. There is no Active/Completed split any
    // more: a row shows its own progress bar while it is still running.
    NSArray *all = [MVDownloadStore.shared.records sortedArrayUsingComparator:^NSComparisonResult(MVDownloadRecord *a, MVDownloadRecord *b) {
        if (a.isActive != b.isActive) return a.isActive ? NSOrderedAscending : NSOrderedDescending;
        return a.createdAt > b.createdAt ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (!self.filter.length) return all;
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(MVDownloadRecord *r, NSDictionary *b) {
        NSString *hay = [NSString stringWithFormat:@"%@ %@", r.title ?: @"", r.url ?: @""];
        return [hay localizedCaseInsensitiveContainsString:self.filter];
    }];
    return [all filteredArrayUsingPredicate:p];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *records = [self records];
    self.emptyLabel.hidden = records.count > 0;
    return records.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVDownloadCell *cell = [tableView dequeueReusableCellWithIdentifier:kDoneCell forIndexPath:indexPath];
    [cell configureWithRecord:[self records][indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showMenuForRecord:[self records][indexPath.row] sourceView:[tableView cellForRowAtIndexPath:indexPath]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVDownloadRecord *record = [self records][indexPath.row];
    if (record.isActive) {
        UIContextualAction *cancel = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                            title:[MVLang t:@"Cancel"]
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [[MVDownloadEngine shared] cancelDownload:record.identifier];
            done(YES);
        }];
        cancel.backgroundColor = [MVTheme danger];
        return [UISwipeActionsConfiguration configurationWithActions:@[cancel]];
    }
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:[MVLang t:@"Delete"]
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self confirmDelete:record];
        done(YES);
    }];
    del.backgroundColor = [MVTheme warning];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)longPressRow:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    [self showMenuForRecord:[self records][indexPath.row]
                 sourceView:[self.tableView cellForRowAtIndexPath:indexPath]];
}

- (void)showMenuForRecord:(MVDownloadRecord *)record sourceView:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:record.title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    if (record.state == MVDownloadStateCompleted && record.path.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Play"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playFile:record.path];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Save to Photos"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[MVDownloadEngine shared] saveToPhotos:record.path completion:^(NSString *fp, NSString *err) {
                if (fp && !err) {
                    [self alert:[MVLang t:@"Saved"] message:[MVLang t:@"Saved to Photos"]];
                } else if (err) {
                    [self alert:[MVLang t:@"Failed"] message:err];
                }
            }];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Share"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[[NSURL fileURLWithPath:record.path]] applicationActivities:nil];
            [self presentViewController:share animated:YES completion:nil];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self promptRename:record];
        }]];
    } else if (record.isActive) {
        [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel download"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[MVDownloadEngine shared] cancelDownload:record.identifier];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self confirmDelete:record];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];

    // Required on iPad, and harmless on iPhone. CGRect is a struct, so it needs
    // a ternary rather than `?:`.
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)playFile:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self alert:[MVLang t:@"Failed"] message:[MVLang t:@"No files"]];
        return;
    }
    [[MVPlayerCenter shared] playURL:[NSURL fileURLWithPath:path]
                                title:path.lastPathComponent.stringByDeletingPathExtension];
}

- (void)promptRename:(MVDownloadRecord *)record {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Rename"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = record.path.lastPathComponent.stringByDeletingPathExtension;
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Rename"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *ext = record.path.pathExtension;
        NSString *target = [[record.path stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
        NSError *err = nil;
        if ([[NSFileManager defaultManager] moveItemAtPath:record.path toPath:target error:&err]) {
            record.path = target;
            [MVDownloadStore.shared update:record];
        } else {
            [self alert:[MVLang t:@"Failed"] message:err.localizedDescription];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDelete:(MVDownloadRecord *)record {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        if (record.path.length) [[NSFileManager defaultManager] removeItemAtPath:record.path error:nil];
        [MVDownloadStore.shared remove:record];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
