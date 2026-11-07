#import "MVDownloadsViewController.h"
#import <AVKit/AVKit.h>
#import "MVPlayerCenter.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"

static NSString *const kDoneCell = @"MVDoneCell";

// The round button at the end of a row: a progress ring with a stop square while
// the download runs, and a plain icon once it has finished.
@interface MVRowActionButton : UIButton
- (void)showProgress:(double)progress;
- (void)showIcon:(NSString *)symbolName;
@end

@implementation MVRowActionButton {
    CAShapeLayer *_track;
    CAShapeLayer *_ring;
    UIView *_stop;
    UIImageView *_icon;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 44, 44)])) {
        _track = [CAShapeLayer layer];
        _track.fillColor = UIColor.clearColor.CGColor;
        _track.lineWidth = 2.5;
        [self.layer addSublayer:_track];

        _ring = [CAShapeLayer layer];
        _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineWidth = 2.5;
        _ring.lineCap = kCALineCapRound;
        _ring.strokeEnd = 0;
        [self.layer addSublayer:_ring];

        _stop = [UIView new];
        _stop.frame = CGRectMake(0, 0, 10, 10);
        _stop.layer.cornerRadius = 2;
        _stop.userInteractionEnabled = NO;
        [self addSubview:_stop];

        _icon = [UIImageView new];
        _icon.frame = CGRectMake(0, 0, 32, 32);
        _icon.contentMode = UIViewContentModeCenter;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];
    }
    return self;
}

- (void)showProgress:(double)progress {
    _icon.hidden = YES;
    _stop.hidden = NO;
    _track.hidden = NO;
    _ring.hidden = NO;
    // A small sliver stays visible so a download that just started still looks alive.
    _ring.strokeEnd = MAX(0.04, MIN(1.0, progress));
    [self setNeedsLayout];
}

- (void)showIcon:(NSString *)symbolName {
    _icon.hidden = NO;
    _stop.hidden = YES;
    _track.hidden = YES;
    _ring.hidden = YES;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    _icon.image = [UIImage systemImageNamed:symbolName withConfiguration:config];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center
                                                          radius:14
                                                      startAngle:-M_PI_2
                                                        endAngle:M_PI * 1.5
                                                       clockwise:YES];
    UIColor *accent = [[MVTheme accent] resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *track = [[[MVTheme secondaryText] colorWithAlphaComponent:0.30]
                      resolvedColorWithTraitCollection:self.traitCollection];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = self.bounds;
    _ring.frame = self.bounds;
    _track.path = circle.CGPath;
    _ring.path = circle.CGPath;
    _track.strokeColor = track.CGColor;
    _ring.strokeColor = accent.CGColor;
    [CATransaction commit];

    _stop.backgroundColor = accent;
    _stop.center = center;
    _icon.tintColor = [MVTheme secondaryText];
    _icon.center = center;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

@end

// One row, as in a plain file list: the title, a line under it, and the round
// button at the end.
@interface MVDownloadCell : UITableViewCell
@property (nonatomic, strong) MVRowActionButton *actionButton;
@property (nonatomic, copy, nullable) void (^onAction)(void);
- (void)configureWithRecord:(MVDownloadRecord *)record;
@end

@implementation MVDownloadCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;

        UIView *highlight = [UIView new];
        highlight.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.15];
        self.selectedBackgroundView = highlight;

        self.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.textLabel.textColor = [MVTheme text];
        self.textLabel.numberOfLines = 1;
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        self.detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        self.detailTextLabel.numberOfLines = 1;

        _actionButton = [[MVRowActionButton alloc] initWithFrame:CGRectZero];
        [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
        self.accessoryView = _actionButton;
    }
    return self;
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

/// "1.6 MB of 11.0 MB". Each size is wrapped in direction isolates so the numbers
/// and units stay in the right order inside an Arabic line.
+ (NSString *)sizesTextForRecord:(MVDownloadRecord *)record {
    if (record.totalBytes <= 0) {
        return [NSString stringWithFormat:@"%.0f%%", record.progress * 100];
    }
    long long done = (long long)llround(record.progress * (double)record.totalBytes);
    NSString *of = MVLang.shared.isRTL ? @"من" : @"of";
    return [NSString stringWithFormat:@"\u2068%@\u2069 %@ \u2068%@\u2069",
            [MVPaths formatBytes:done], of, [MVPaths formatBytes:record.totalBytes]];
}

- (void)configureWithRecord:(MVDownloadRecord *)record {
    self.textLabel.text = record.title.length ? record.title : record.url;
    self.textLabel.textColor = [MVTheme text];

    UIColor *normal = [[MVTheme text] colorWithAlphaComponent:0.85];
    switch (record.state) {
        case MVDownloadStateWaiting:
            self.detailTextLabel.text = [MVLang t:@"Waiting"];
            self.detailTextLabel.textColor = [MVTheme secondaryText];
            [self.actionButton showProgress:0];
            break;
        case MVDownloadStateActive:
            // The engine stores a transient phase message ("Merging…",
            // "Converting…") in `error` while a post-download step runs; the
            // record is still active, so the row shows it as its status.
            if (record.error.length && record.totalBytes > 0 && record.progress >= 1.0) {
                self.detailTextLabel.text = record.error;
            } else if (record.progress <= 0 && record.totalBytes <= 0) {
                // Pre-download phase (DNS, metadata): no bytes yet, so show a
                // meaningful status instead of a frozen 0%.
                self.detailTextLabel.text = [MVLang t:@"Connecting…"];
            } else {
                self.detailTextLabel.text = [MVDownloadCell sizesTextForRecord:record];
            }
            self.detailTextLabel.textColor = normal;
            [self.actionButton showProgress:record.progress];
            break;
        case MVDownloadStateCompleted:
            self.detailTextLabel.text = [MVLang t:@"Completed"];
            self.detailTextLabel.textColor = [MVTheme success];
            [self.actionButton showIcon:@"square.and.arrow.down"];
            break;
        case MVDownloadStateFailed:
            self.detailTextLabel.text = [NSString stringWithFormat:@"%@: %@", [MVLang t:@"Failed"],
                                         record.error ?: [MVLang t:@"Unknown error"]];
            self.detailTextLabel.textColor = [MVTheme danger];
            [self.actionButton showIcon:@"exclamationmark.circle"];
            break;
        case MVDownloadStateCancelled:
            self.detailTextLabel.text = [MVLang t:@"Cancel"];
            self.detailTextLabel.textColor = [MVTheme secondaryText];
            [self.actionButton showIcon:@"square.and.arrow.down"];
            break;
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onAction = nil;
}

@end

@interface MVDownloadsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *queueLabel;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic) BOOL editingMode;
@property (nonatomic, copy) NSArray<NSString *> *shownIdentifiers;
@end

@implementation MVDownloadsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"Downloads"];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.tableView.separatorColor = [[MVTheme separator] colorWithAlphaComponent:0.35];
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:MVDownloadCell.class forCellReuseIdentifier:kDoneCell];
    // A slim header that shows how many items are still waiting, so the queue
    // reads like a list instead of a mystery: "3 waiting · 2 downloading".
    self.queueLabel = [UILabel new];
    self.queueLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.queueLabel.textColor = [MVTheme secondaryText];
    self.queueLabel.textAlignment = NSTextAlignmentCenter;
    self.queueLabel.frame = CGRectMake(0, 0, 320, 28);
    self.tableView.tableHeaderView = self.queueLabel;
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
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[MVLang t:@"Edit"] style:UIBarButtonItemStylePlain
        target:self action:@selector(toggleEditMode)];
    self.definesPresentationContext = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange)
                                               name:MVDownloadStoreDidChangeNotification object:nil];
    for (NSString *name in @[MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
}

- (void)refresh {
    self.title = [MVLang t:@"Downloads"];
    self.emptyLabel.text = [MVLang t:@"No downloads yet"];
    self.search.searchBar.placeholder = [MVLang t:@"Search downloads"];
    [MVTheme applyWallpaperTo:self.view];
    [self reloadList];
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
    }
}

- (void)reloadList {
    self.shownIdentifiers = [[self records] valueForKey:@"identifier"];
    [self updateQueueLabel];
    [self.tableView reloadData];
}

/// The queue summary line above the rows: how many are still downloading and
/// how many are waiting their turn. Hidden entirely when nothing is running.
- (void)updateQueueLabel {
    NSArray<MVDownloadRecord *> *all = MVDownloadStore.shared.records;
    NSUInteger active = 0, waiting = 0;
    for (MVDownloadRecord *r in all) {
        if (r.state == MVDownloadStateActive) active++;
        if (r.state == MVDownloadStateWaiting) waiting++;
    }
    NSString *text = @"";
    if (active || waiting) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (active) [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)active, [MVLang t:@"downloading"]]];
        if (waiting) [parts addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)waiting, [MVLang t:@"waiting"]]];
        text = [parts componentsJoinedByString:@" · "];
    }
    self.queueLabel.text = text;
    self.queueLabel.hidden = text.length == 0;
}

/// Progress arrives four times a second. Reloading the whole table that often
/// would cancel a tap on the stop button halfway through, so when the same rows
/// are still in the same order only the visible cells are refreshed in place.
- (void)storeDidChange {
    NSArray<MVDownloadRecord *> *now = [self records];
    BOOL sameRows = (now.count == self.shownIdentifiers.count);
    for (NSUInteger i = 0; sameRows && i < now.count; i++) {
        if (![now[i].identifier isEqualToString:self.shownIdentifiers[i]]) sameRows = NO;
    }
    if (!sameRows) {
        [self reloadList];
        return;
    }
    [self updateQueueLabel];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        MVDownloadCell *cell = (MVDownloadCell *)[self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:MVDownloadCell.class] && indexPath.row < (NSInteger)now.count) {
            [cell configureWithRecord:now[indexPath.row]];
        }
    }
    self.emptyLabel.hidden = now.count > 0;
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
    [self reloadList];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *records = [self records];
    self.emptyLabel.hidden = records.count > 0;
    return records.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVDownloadCell *cell = [tableView dequeueReusableCellWithIdentifier:kDoneCell forIndexPath:indexPath];
    MVDownloadRecord *record = [self records][indexPath.row];
    [cell configureWithRecord:record];

    // The round button cancels a running download; on a finished row it opens
    // the same menu as tapping the row.
    __weak typeof(self) weakSelf = self;
    __weak MVDownloadCell *weakCell = cell;
    cell.onAction = ^{
        if (record.isActive) {
            [[MVDownloadEngine shared] cancelDownload:record.identifier];
        } else {
            [weakSelf showMenuForRecord:record sourceView:weakCell];
        }
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.editingMode) return;
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
            [self playFile:record];
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

- (void)playFile:(MVDownloadRecord *)record {
    // Hand the whole visible list to the player so its previous/next buttons
    // move through the downloads. Only finished rows with a file are playable.
    NSArray<MVDownloadRecord *> *records = [self records];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger index = 0;
    for (NSUInteger i = 0; i < records.count; i++) {
        MVDownloadRecord *r = records[i];
        if (r.state != MVDownloadStateCompleted || r.path.length == 0) continue;
        [urls addObject:[NSURL fileURLWithPath:r.path]];
        [titles addObject:r.title.length ? r.title : r.path.lastPathComponent.stringByDeletingPathExtension];
        if (r == record) index = (NSInteger)urls.count - 1;
    }
    if (!urls.count) return;

    [[MVPlayerCenter shared] playQueue:urls titles:titles fromIndex:index];
    if (record.thumbnail.length && [NSFileManager.defaultManager fileExistsAtPath:record.thumbnail]) {
        UIImage *art = [UIImage imageWithContentsOfFile:record.thumbnail];
        if (art) [[MVPlayerCenter shared] setThumbnailImage:art];
    }
    // The user tapped "Play": bring the video player up right away. The mini
    // bar remains for when they dismiss it.
    [[MVPlayerCenter shared] presentCurrentPlayer];
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


- (void)toggleEditMode {
    self.editingMode = !self.editingMode;
    [self.tableView setEditing:self.editingMode animated:YES];
    self.navigationItem.rightBarButtonItem.title = self.editingMode ? [MVLang t:@"Done"] : [MVLang t:@"Edit"];
    if (!self.editingMode) {
        [self reloadList];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    MVDownloadRecord *record = [self records][indexPath.row];
    if (record.isActive) {
        [[MVDownloadEngine shared] cancelDownload:record.identifier];
    } else {
        if (record.path.length) [[NSFileManager defaultManager] removeItemAtPath:record.path error:nil];
        [MVDownloadStore.shared remove:record];
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [MVLang t:@"Delete"];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
