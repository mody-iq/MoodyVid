#import "MVDownloadsViewController.h"
#import <AVKit/AVKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MVPlayerCenter.h"
#import "MVDownloadStore.h"
#import "MVDownloadEngine.h"
#import "MVDownloadTask.h"
#import "MVTaskStore.h"
#import "MVDownloadManager.h"
#import "MVDownloadRow.h"
#import "MVDownloadActions.h"
#import "MVTaskCardCell.h"
#import "MVStatusChipsView.h"
#import "MVSectionHeader.h"
#import "MVEmptyStateView.h"
#import "MVFloatingAddButton.h"
#import "MVTypeFilterSheet.h"
#import "MVDetailsSheet.h"
#import "MVSnifferItem.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"

static NSString *const kCardCell = @"MVTaskCardCell";

/// The status chips, in the order they are shown.
typedef NS_ENUM(NSInteger, MVStatusFilter) {
    MVStatusFilterAll = 0,
    MVStatusFilterActive,
    MVStatusFilterFinished,
    MVStatusFilterFailed,
    MVStatusFilterScheduled,
};

typedef NS_ENUM(NSInteger, MVSortOrder) {
    MVSortNewest = 0,
    MVSortOldest,
    MVSortNameAZ,
    MVSortNameZA,
    MVSortSizeLarge,
    MVSortSizeSmall,
};

@interface MVDownloadsViewController () <UITableViewDataSource, UITableViewDelegate,
                                         UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) MVStatusChipsView *chips;
@property (nonatomic, strong) MVSectionHeader *summaryHeader;
@property (nonatomic, strong) MVEmptyStateView *emptyState;
@property (nonatomic, strong) MVFloatingAddButton *addButton;
@property (nonatomic, strong) UIView *editBar;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, copy, nullable) NSString *typeFilter;
@property (nonatomic) MVStatusFilter statusFilter;
@property (nonatomic) MVSortOrder sortOrder;
@property (nonatomic) BOOL editingMode;
@property (nonatomic, copy) NSArray<NSString *> *shownIdentifiers;
@end

@implementation MVDownloadsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.title = [MVLang t:@"Downloads"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    [self buildSearch];
    [self buildTable];
    [self buildChips];
    [self buildEmptyState];
    [self buildAddButton];
    [self buildEditBar];
    [self buildNavigationItems];

    self.definesPresentationContext = YES;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange)
                                               name:MVDownloadStoreDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange)
                                               name:MVTaskStoreDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(showNewestTask)
                                               name:@"MVShowDownloadsTabNotification" object:nil];
    for (NSString *name in @[MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
}

#pragma mark - Building

- (void)buildSearch {
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = [MVLang t:@"Search downloads"];
    self.search.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
}

- (void)buildTable {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 84;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.tableFooterView = [UIView new];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 96, 0);
    self.tableView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 96, 0);
    [self.tableView registerClass:MVTaskCardCell.class forCellReuseIdentifier:kCardCell];
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

/// The status chips and the summary line live in the table's header, so they
/// scroll away with the content instead of eating vertical space on a phone.
- (void)buildChips {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 96)];

    self.chips = [[MVStatusChipsView alloc] initWithFrame:CGRectZero];
    self.chips.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.chips.onSelect = ^(NSInteger tag) { weakSelf.statusFilter = (MVStatusFilter)tag; [weakSelf reloadList]; };
    [header addSubview:self.chips];

    self.summaryHeader = [[MVSectionHeader alloc] initWithFrame:CGRectZero];
    self.summaryHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.summaryHeader];

    CGFloat pad = [MVTheme screenPadding];
    [NSLayoutConstraint activateConstraints:@[
        [self.chips.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [self.chips.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:pad],
        [self.chips.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-pad],
        [self.chips.heightAnchor constraintEqualToConstant:38],

        [self.summaryHeader.topAnchor constraintEqualToAnchor:self.chips.bottomAnchor constant:10],
        [self.summaryHeader.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:pad],
        [self.summaryHeader.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-pad],
        [self.summaryHeader.heightAnchor constraintEqualToConstant:20],
        [self.summaryHeader.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6],
    ]];

    // Let the header size itself from its contents.
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(self.view.bounds.size.width, 0)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    header.frame = CGRectMake(0, 0, self.view.bounds.size.width, size.height);
    self.tableView.tableHeaderView = header;
}

- (void)buildEmptyState {
    self.emptyState = [[MVEmptyStateView alloc] initWithFrame:CGRectZero];
    self.emptyState.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyState.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.emptyState.onAction = ^{ [weakSelf promptAddLink]; };
    [self.view addSubview:self.emptyState];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyState.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyState.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40],
        [self.emptyState.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.emptyState.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)buildAddButton {
    self.addButton = [MVFloatingAddButton button];
    [self.view addSubview:self.addButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.addButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-[MVTheme screenPadding]],
        [self.addButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
    ]];
    [self rebuildAddMenu];
}

- (void)rebuildAddMenu {
    __weak typeof(self) weakSelf = self;
    [self.addButton setActions:@[
        @[[MVLang t:@"Add link"], @"link", ^{ [weakSelf promptAddLink]; }],
        @[[MVLang t:@"From clipboard"], @"doc.on.clipboard", ^{ [weakSelf addFromClipboard]; }],
        @[[MVLang t:@"Import links from text file"], @"doc.text", ^{ [weakSelf importLinksFromFile]; }],
        @[[MVLang t:@"Add torrent or magnet"], @"arrow.up.arrow.down.circle", ^{ [weakSelf promptAddTorrent]; }],
    ]];
}

/// The bar that appears in edit mode, pinned to the bottom over the tab bar.
- (void)buildEditBar {
    self.editBar = [UIView new];
    self.editBar.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:self.editBar cornerRadius:[MVTheme cardCornerRadius]];
    self.editBar.hidden = YES;
    [self.view addSubview:self.editBar];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 8;
    [self.editBar addSubview:stack];

    NSArray<NSArray *> *items = @[
        @[@"pause.fill", [MVLang t:@"Pause"], @"editPause"],
        @[@"play.fill", [MVLang t:@"Resume"], @"editResume"],
        @[@"square.and.arrow.up", [MVLang t:@"Share"], @"editShare"],
        @[@"trash", [MVLang t:@"Delete"], @"editDelete"],
    ];
    for (NSArray *item in items) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setImage:[UIImage systemImageNamed:item[0]] forState:UIControlStateNormal];
        [b setTitle:item[1] forState:UIControlStateNormal];
        b.titleLabel.font = [MVTheme cardDetailFont];
        BOOL destructive = [item[0] isEqualToString:@"trash"];
        b.tintColor = destructive ? [MVTheme danger] : [MVTheme accent];
        [b setTitleColor:destructive ? [MVTheme danger] : [MVTheme text] forState:UIControlStateNormal];
        b.contentEdgeInsets = UIEdgeInsetsMake(6, 4, 6, 4);
        b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 4);
        [b addTarget:self action:NSSelectorFromString(item[2]) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:b];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.editBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:[MVTheme screenPadding]],
        [self.editBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-[MVTheme screenPadding]],
        [self.editBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [self.editBar.heightAnchor constraintGreaterThanOrEqualToConstant:56],
        [stack.topAnchor constraintEqualToAnchor:self.editBar.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:self.editBar.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:self.editBar.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.editBar.trailingAnchor constant:-8],
    ]];
}

- (void)buildNavigationItems {
    UIBarButtonItem *edit = [[UIBarButtonItem alloc] initWithTitle:[MVLang t:@"Edit"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(toggleEditMode)];
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:nil action:nil];
    UIBarButtonItem *filter = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                                               style:UIBarButtonItemStylePlain
                                                              target:self action:@selector(showTypeFilter)];
    sort.menu = [self sortMenu];
    self.navigationItem.rightBarButtonItems = @[edit, filter, sort];
}

- (UIMenu *)sortMenu {
    __weak typeof(self) weakSelf = self;
    NSArray<NSArray *> *options = @[
        @[[MVLang t:@"Date: newest"], @(MVSortNewest)],
        @[[MVLang t:@"Date: oldest"], @(MVSortOldest)],
        @[[MVLang t:@"Name: A-Z"], @(MVSortNameAZ)],
        @[[MVLang t:@"Name: Z-A"], @(MVSortNameZA)],
        @[[MVLang t:@"Size: largest"], @(MVSortSizeLarge)],
        @[[MVLang t:@"Size: smallest"], @(MVSortSizeSmall)],
    ];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSArray *option in options) {
        MVSortOrder order = (MVSortOrder)[option[1] integerValue];
        UIAction *action = [UIAction actionWithTitle:option[0] image:nil identifier:nil
                                             handler:^(UIAction *a) {
            weakSelf.sortOrder = order;
            [weakSelf reloadList];
        }];
        action.state = (self.sortOrder == order) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:children];
}

#pragma mark - Refresh

- (void)refresh {
    self.title = [MVLang t:@"Downloads"];
    self.search.searchBar.placeholder = [MVLang t:@"Search downloads"];
    [MVTheme applyWallpaperTo:self.view];
    [self buildNavigationItems];
    [self rebuildAddMenu];
    [self.emptyState refresh];
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
    self.shownIdentifiers = [[self rows] valueForKey:@"identifier"];
    [self updateChips];
    [self updateSummary];
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateChips {
    NSArray<MVDownloadRow *> *all = [self allRows];
    NSInteger active = 0, finished = 0, failed = 0, scheduled = 0;
    for (MVDownloadRow *row in all) {
        if (row.isFailed) failed++;
        else if (row.isFinished) finished++;
        else if (row.isPaused) scheduled++;
        else active++;
    }
    MVStatusChip *allChip = [MVStatusChip chipWithTitle:[MVLang t:@"All"] tag:MVStatusFilterAll];
    allChip.count = (NSInteger)all.count;
    MVStatusChip *activeChip = [MVStatusChip chipWithTitle:[MVLang t:@"Active"] tag:MVStatusFilterActive];
    activeChip.count = active;
    MVStatusChip *finishedChip = [MVStatusChip chipWithTitle:[MVLang t:@"Finished"] tag:MVStatusFilterFinished];
    finishedChip.count = finished;
    MVStatusChip *failedChip = [MVStatusChip chipWithTitle:[MVLang t:@"Failed"] tag:MVStatusFilterFailed];
    failedChip.count = failed;
    MVStatusChip *scheduledChip = [MVStatusChip chipWithTitle:[MVLang t:@"Scheduled"] tag:MVStatusFilterScheduled];
    scheduledChip.count = scheduled;
    self.chips.chips = @[allChip, activeChip, finishedChip, failedChip, scheduledChip];
    self.chips.selectedTag = self.statusFilter;
}

/// "3 active · 1 queued" on the left, the total current speed on the right.
- (void)updateSummary {
    NSInteger active = 0, queued = 0;
    double speed = 0;
    for (MVDownloadRow *row in [self allRows]) {
        if (row.kind == MVRowKindRecord) {
            if (row.record.state == MVDownloadStateActive) active++;
            if (row.record.state == MVDownloadStateWaiting) queued++;
        } else {
            if (row.task.state == MVTaskStateRunning) active++;
            if (row.task.state == MVTaskStateQueued) queued++;
        }
        speed += row.speed;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (active) [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)active, [MVLang t:@"active"]]];
    if (queued) [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)queued, [MVLang t:@"queued"]]];
    NSString *left = parts.count ? [parts componentsJoinedByString:@" · "] : [MVLang t:@"No active downloads"];
    self.summaryHeader.title = left;
    self.summaryHeader.trailingText = speed > 0 ? [MVPaths formatSpeed:speed] : nil;
}

- (void)updateEmptyState {
    NSArray<MVDownloadRow *> *rows = [self rows];
    BOOL empty = rows.count == 0;
    self.emptyState.hidden = !empty;
    if (!empty) return;

    if (self.searchText.length) {
        self.emptyState.symbolName = @"magnifyingglass";
        self.emptyState.title = [MVLang t:@"No results"];
        self.emptyState.message = [MVLang t:@"Try a different search term."];
        self.emptyState.actionTitle = nil;
    } else if (self.statusFilter != MVStatusFilterAll || self.typeFilter.length) {
        self.emptyState.symbolName = @"line.3.horizontal.decrease.circle";
        self.emptyState.title = [MVLang t:@"Nothing here"];
        self.emptyState.message = [MVLang t:@"No downloads match this filter."];
        self.emptyState.actionTitle = nil;
    } else {
        self.emptyState.symbolName = @"arrow.down.circle";
        self.emptyState.title = [MVLang t:@"No downloads yet"];
        self.emptyState.message = [MVLang t:@"Paste a link or browse the web to start a download."];
        self.emptyState.actionTitle = [MVLang t:@"Add link"];
    }
    [self.emptyState refresh];
}

/// Progress arrives four times a second. Reloading the whole table that often
/// would cancel a tap on a card's button halfway through, so when the same rows
/// are still in the same order only the visible cells are refreshed in place.
- (void)storeDidChange {
    NSArray<MVDownloadRow *> *now = [self rows];
    BOOL sameRows = (now.count == self.shownIdentifiers.count);
    for (NSUInteger i = 0; sameRows && i < now.count; i++) {
        if (![now[i].identifier isEqualToString:self.shownIdentifiers[i]]) sameRows = NO;
    }
    if (!sameRows) {
        [self reloadList];
        return;
    }
    [self updateChips];
    [self updateSummary];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        if (indexPath.row >= (NSInteger)now.count) continue;
        MVTaskCardCell *cell = (MVTaskCardCell *)[self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:MVTaskCardCell.class]) {
            [cell configureWithContent:[self contentForRow:now[indexPath.row]]];
        }
    }
    [self updateEmptyState];
}

#pragma mark - Data

/// Every row, unfiltered, in the sort order.
- (NSArray<MVDownloadRow *> *)allRows {
    NSMutableArray<MVDownloadRow *> *all = [NSMutableArray array];
    for (MVDownloadRecord *record in MVDownloadStore.shared.records) {
        [all addObject:[MVDownloadRow rowWithRecord:record]];
    }
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        [all addObject:[MVDownloadRow rowWithTask:task]];
    }
    [self sortRows:all];
    return all;
}

- (void)sortRows:(NSMutableArray<MVDownloadRow *> *)rows {
    MVSortOrder order = self.sortOrder;
    [rows sortUsingComparator:^NSComparisonResult(MVDownloadRow *a, MVDownloadRow *b) {
        switch (order) {
            case MVSortNewest:     return a.createdAt > b.createdAt ? NSOrderedAscending : NSOrderedDescending;
            case MVSortOldest:     return a.createdAt < b.createdAt ? NSOrderedAscending : NSOrderedDescending;
            case MVSortNameAZ:     return [a.title localizedCaseInsensitiveCompare:b.title];
            case MVSortNameZA:     return [b.title localizedCaseInsensitiveCompare:a.title];
            case MVSortSizeLarge:  return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
            case MVSortSizeSmall:  return a.totalBytes < b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
}

/// The rows after the search, status and type filters, sorted. Running rows are
/// pinned to the top so the active work is always visible.
- (NSArray<MVDownloadRow *> *)rows {
    NSMutableArray<MVDownloadRow *> *rows = [NSMutableArray array];
    for (MVDownloadRow *row in [self allRows]) {
        if (![self rowMatchesStatus:row]) continue;
        if (self.typeFilter.length && ![row.typeName isEqualToString:self.typeFilter]) continue;
        if (self.searchText.length) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@", row.title ?: @"", row.url ?: @""];
            if (![hay localizedCaseInsensitiveContainsString:self.searchText]) continue;
        }
        [rows addObject:row];
    }
    if (self.sortOrder == MVSortNewest || self.sortOrder == MVSortOldest) {
        [rows sortUsingComparator:^NSComparisonResult(MVDownloadRow *a, MVDownloadRow *b) {
            if (a.isActive != b.isActive) return a.isActive ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    return rows;
}

- (BOOL)rowMatchesStatus:(MVDownloadRow *)row {
    switch (self.statusFilter) {
        case MVStatusFilterAll:       return YES;
        case MVStatusFilterActive:    return row.isActive && !row.isPaused;
        case MVStatusFilterFinished:  return row.isFinished && !row.isFailed;
        case MVStatusFilterFailed:    return row.isFailed;
        case MVStatusFilterScheduled: return row.isPaused;
    }
    return YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.searchText = searchController.searchBar.text ?: @"";
    [self reloadList];
}

#pragma mark - Cells

/// The plain content the card renders, whatever engine produced the row.
- (MVCardContent *)contentForRow:(MVDownloadRow *)row {
    MVCardContent *content = [MVCardContent new];
    content.title = row.title;
    content.symbolName = [MVTaskCardCell symbolForKindName:row.typeName];
    content.tint = [self tintForRow:row];
    content.errorText = row.errorText;

    if (row.isFailed) {
        content.detail = [NSString stringWithFormat:@"%@ · %@", row.typeName,
                          row.totalBytes > 0 ? [MVPaths formatBytes:row.totalBytes] : [MVLang t:@"Failed"]];
        content.showsProgress = NO;
        content.actionSymbol = @"arrow.clockwise";
    } else if (row.isFinished) {
        NSMutableArray *parts = [NSMutableArray arrayWithObject:row.typeName];
        if (row.totalBytes > 0) [parts addObject:[MVPaths formatBytes:row.totalBytes]];
        NSString *date = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:row.createdAt]
                                                       dateStyle:NSDateFormatterMediumStyle
                                                       timeStyle:NSDateFormatterShortStyle];
        if (date.length) [parts addObject:date];
        content.detail = [parts componentsJoinedByString:@" · "];
        content.showsProgress = NO;
        content.actionSymbol = @"ellipsis";
    } else if (row.isPaused) {
        content.detail = [NSString stringWithFormat:@"%@ · %@", [MVLang t:@"Paused"],
                          [MVPaths formatBytes:row.doneBytes]];
        content.showsProgress = YES;
        content.progress = row.progress;
        content.actionSymbol = @"play.fill";
    } else {
        content.detail = [self detailForActiveRow:row];
        content.showsProgress = YES;
        content.progress = row.progress;
        content.actionSymbol = @"pause.fill";
    }
    return content;
}

- (NSString *)detailForActiveRow:(MVDownloadRow *)row {
    if (row.statusText.length && row.totalBytes <= 0) return row.statusText;
    if (row.totalBytes <= 0) {
        if (row.doneBytes > 0) return [NSString stringWithFormat:@"%@ · %@",
                                       [MVPaths formatBytes:row.doneBytes], [MVLang t:@"Downloading"]];
        return [MVLang t:@"Connecting…"];
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ %@ %@", [MVPaths formatBytes:row.doneBytes],
                      [MVLang t:@"of"], [MVPaths formatBytes:row.totalBytes]]];
    if (row.speed > 0) [parts addObject:[MVPaths formatSpeed:row.speed]];
    if (row.eta > 0) [parts addObject:[MVPaths formatDuration:row.eta]];
    return [parts componentsJoinedByString:@" · "];
}

- (UIColor *)tintForRow:(MVDownloadRow *)row {
    if (row.isFailed) return [MVTheme danger];
    if (row.isFinished) return [MVTheme success];
    if (row.isPaused) return [MVTheme warning];
    return [MVTheme accent];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rows].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVDownloadRow *row = [self rows][indexPath.row];
    MVTaskCardCell *cell = [tableView dequeueReusableCellWithIdentifier:kCardCell forIndexPath:indexPath];
    [cell configureWithContent:[self contentForRow:row]];
    __weak typeof(self) weakSelf = self;
    cell.onAction = ^{ [weakSelf actionTappedForRow:row]; };
    return cell;
}

/// The trailing button: pause while running, resume when paused or failed, and
/// the details sheet once finished.
- (void)actionTappedForRow:(MVDownloadRow *)row {
    if (row.isFinished && !row.isFailed) {
        [self showDetailsForRow:row];
    } else if (row.isPaused || row.isFailed) {
        [MVDownloadActions resumeRow:row];
    } else {
        [MVDownloadActions pauseRow:row];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.editingMode) {
        [self updateEditBar];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showDetailsForRow:[self rows][indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.editingMode) [self updateEditBar];
}

#pragma mark - Details sheet

- (void)showDetailsForRow:(MVDownloadRow *)row {
    MVDetailsSheet *sheet = [[MVDetailsSheet alloc] initWithRow:row];
    __weak typeof(self) weakSelf = self;
    sheet.onPlay = ^(MVDownloadRow *r) { [weakSelf playRow:r]; };
    sheet.onShare = ^(MVDownloadRow *r) { [weakSelf shareRow:r]; };
    sheet.onDelete = ^(MVDownloadRow *r) { [weakSelf confirmDeleteRow:r]; };
    sheet.onSaveToPhotos = ^(MVDownloadRow *r) { [weakSelf saveRowToPhotos:r]; };
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                                 [UISheetPresentationControllerDetent largeDetent]];
        presentation.prefersGrabberVisible = YES;
        presentation.preferredCornerRadius = 24;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Row actions

- (void)shareRow:(MVDownloadRow *)row {
    if (!row.path.length) return;
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:row.path]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
                                                                self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)saveRowToPhotos:(MVDownloadRow *)row {
    if (!row.path.length) return;
    __weak typeof(self) weakSelf = self;
    [[MVDownloadEngine shared] saveToPhotos:row.path completion:^(NSString *fp, NSString *err) {
        if (fp && !err) [weakSelf alert:[MVLang t:@"Saved"] message:[MVLang t:@"Saved to Photos"]];
        else if (err) [weakSelf alert:[MVLang t:@"Failed"] message:err];
    }];
}

/// Plays a single file through the shared player, using the whole visible list
/// as the queue so the mini bar's next/previous still work.
- (void)playRow:(MVDownloadRow *)row {
    [self playFileAtPath:row.path title:row.title];
    if (row.kind == MVRowKindRecord && row.record.thumbnail.length &&
        [NSFileManager.defaultManager fileExistsAtPath:row.record.thumbnail]) {
        UIImage *art = [UIImage imageWithContentsOfFile:row.record.thumbnail];
        if (art) [[MVPlayerCenter shared] setThumbnailImage:art];
    }
}

- (void)playFileAtPath:(NSString *)path title:(NSString *)title {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger index = 0;
    for (MVDownloadRow *row in [self rows]) {
        if (!row.isFinished || !row.path.length) continue;
        NSString *ext = row.path.pathExtension.lowercaseString;
        if (![@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"aac", @"wav"] containsObject:ext]) continue;
        [urls addObject:[NSURL fileURLWithPath:row.path]];
        [titles addObject:row.title.length ? row.title : row.path.lastPathComponent.stringByDeletingPathExtension];
        if ([row.path isEqualToString:path]) index = (NSInteger)urls.count - 1;
    }
    if (!urls.count) {
        [self alert:[MVLang t:@"Can't play this file"]
            message:[MVLang t:@"WebM and MKV aren't supported. You can still share or export it."]];
        return;
    }
    [[MVPlayerCenter shared] playQueue:urls titles:titles fromIndex:index];
    [[MVPlayerCenter shared] presentCurrentPlayer];
}

- (void)confirmDeleteRow:(MVDownloadRow *)row {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [MVDownloadActions removeRow:row deleteFile:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptRenameRow:(MVDownloadRow *)row {
    if (row.kind != MVRowKindRecord || !row.record.path.length) return;
    MVDownloadRecord *record = row.record;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Rename"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = record.path.lastPathComponent.stringByDeletingPathExtension;
        f.semanticContentAttribute = MVLang.shared.isRTL ? UISemanticContentAttributeForceRightToLeft
                                                         : UISemanticContentAttributeForceLeftToRight;
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

#pragma mark - Context menu

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (self.editingMode) return nil;
    MVDownloadRow *row = [self rows][indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        if (row.isFinished && !row.isFailed) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Open"] image:[UIImage systemImageNamed:@"play.fill"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf playRow:row]; }]];
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Share"] image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf shareRow:row]; }]];
        }
        if (row.isPaused || row.isFailed) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Resume"] image:[UIImage systemImageNamed:@"play.fill"]
                                               identifier:nil handler:^(UIAction *a) { [MVDownloadActions resumeRow:row]; }]];
        } else if (row.isActive) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Pause"] image:[UIImage systemImageNamed:@"pause.fill"]
                                               identifier:nil handler:^(UIAction *a) { [MVDownloadActions pauseRow:row]; }]];
        }
        if (row.kind == MVRowKindRecord && row.record.path.length) {
            [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Rename"] image:[UIImage systemImageNamed:@"pencil"]
                                               identifier:nil handler:^(UIAction *a) { [weakSelf promptRenameRow:row]; }]];
        }
        [actions addObject:[UIAction actionWithTitle:[MVLang t:@"Copy link"] image:[UIImage systemImageNamed:@"doc.on.doc"]
                                           identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = row.url;
        }]];
        UIAction *delete = [UIAction actionWithTitle:[MVLang t:@"Delete with file"]
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil handler:^(UIAction *a) { [weakSelf confirmDeleteRow:row]; }];
        delete.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:delete];
        return [UIMenu menuWithChildren:actions];
    }];
}

#pragma mark - Swipe actions

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVDownloadRow *row = [self rows][indexPath.row];
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];

    if (row.isFinished && !row.isFailed) {
        UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                            title:[MVLang t:@"Share"]
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self shareRow:row];
            done(YES);
        }];
        share.backgroundColor = [MVTheme accent];
        share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        [actions addObject:share];
    } else if (row.isPaused) {
        UIContextualAction *resume = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                             title:[MVLang t:@"Resume"]
                                                                           handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [MVDownloadActions resumeRow:row];
            done(YES);
        }];
        resume.backgroundColor = [MVTheme accent];
        [actions addObject:resume];
    } else if (row.isActive) {
        UIContextualAction *pause = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                            title:[MVLang t:@"Pause"]
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [MVDownloadActions pauseRow:row];
            done(YES);
        }];
        pause.backgroundColor = [MVTheme warning];
        [actions addObject:pause];
    }

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:[MVLang t:@"Delete"]
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self confirmDeleteRow:row];
        done(YES);
    }];
    del.backgroundColor = [MVTheme danger];
    [actions addObject:del];

    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

#pragma mark - Edit mode

- (void)toggleEditMode {
    self.editingMode = !self.editingMode;
    [self.tableView setEditing:self.editingMode animated:YES];
    self.navigationItem.rightBarButtonItems.firstObject.title = self.editingMode ? [MVLang t:@"Done"] : [MVLang t:@"Edit"];
    self.editBar.hidden = !self.editingMode;
    self.addButton.hidden = self.editingMode;
    if (self.editingMode) {
        self.tableView.tableHeaderView = nil;
    } else {
        [self buildChips];
        [self reloadList];
    }
    [self updateEditBar];
}

- (void)updateEditBar {
    NSInteger count = (NSInteger)self.tableView.indexPathsForSelectedRows.count;
    for (UIView *v in self.editBar.subviews) v.alpha = count > 0 ? 1.0 : 0.45;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)selectedRowsApply:(void (^)(MVDownloadRow *row))block {
    NSArray<NSIndexPath *> *paths = self.tableView.indexPathsForSelectedRows;
    NSArray<MVDownloadRow *> *rows = [self rows];
    for (NSIndexPath *p in paths) {
        if (p.row < (NSInteger)rows.count) block(rows[p.row]);
    }
}

- (void)editPause {
    [self selectedRowsApply:^(MVDownloadRow *row) {
        if (row.isActive) [MVDownloadActions pauseRow:row];
    }];
    [self exitEditModeAfterAction];
}

- (void)editResume {
    [self selectedRowsApply:^(MVDownloadRow *row) {
        if (row.isPaused || row.isFailed) [MVDownloadActions resumeRow:row];
    }];
    [self exitEditModeAfterAction];
}

- (void)editShare {
    NSMutableArray *urls = [NSMutableArray array];
    [self selectedRowsApply:^(MVDownloadRow *row) {
        if (row.path.length) [urls addObject:[NSURL fileURLWithPath:row.path]];
    }];
    if (urls.count) {
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:urls
                                                                           applicationActivities:nil];
        share.popoverPresentationController.sourceView = self.editBar;
        share.popoverPresentationController.sourceRect = self.editBar.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }
}

- (void)editDelete {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Delete this file?"]
                                                                  message:[MVLang t:@"This cannot be undone."]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Delete"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self selectedRowsApply:^(MVDownloadRow *row) { [MVDownloadActions removeRow:row deleteFile:YES]; }];
        [self exitEditModeAfterAction];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exitEditModeAfterAction {
    if (self.editingMode) [self toggleEditMode];
}

#pragma mark - Add actions

- (void)promptAddLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Add link"]
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"https://…";
        f.keyboardType = UIKeyboardTypeURL;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Add"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self enqueueURLString:alert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addFromClipboard {
    NSString *clip = UIPasteboard.generalPasteboard.string;
    clip = [clip stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clip.length) {
        [self alert:[MVLang t:@"Clipboard is empty"] message:nil];
        return;
    }
    [self enqueueURLString:clip];
}

- (void)importLinksFromFile {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePlainText, UTTypeText]
                                                                  asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) {
        [self alert:[MVLang t:@"Could not read the file"] message:nil];
        return;
    }
    NSInteger added = 0;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) { [self enqueueURLString:trimmed]; added++; }
    }
    [self alert:[MVLang t:@"Imported links"] message:[NSString stringWithFormat:@"%ld", (long)added]];
}

/// The "Add torrent or magnet" sheet: one field plus a Browse button for a
/// `.torrent` file. Both routes funnel through the same torrent entry point.
- (void)promptAddTorrent {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[MVLang t:@"Add torrent or magnet"]
                                                                  message:[MVLang t:@"Paste a magnet link or a .torrent URL"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"magnet:…  /  https://…/file.torrent";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Browse"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[MVLang t:@"Add"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self enqueueURLString:alert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// The single door every "add" route goes through: classify the URL with the
/// sniffer's own rules, then let the manager pick the engine.
- (void)enqueueURLString:(NSString *)raw {
    NSString *url = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!url.length) return;
    MVSnifferItem *item = [MVSnifferItem itemWithURL:url pageURL:nil pageTitle:nil mime:nil];
    BOOL added = NO;
    [[MVDownloadManager shared] enqueueItem:item added:&added];
    if (!added) {
        [self alert:[MVLang t:@"Already in downloads"] message:nil];
    }
}

#pragma mark - Misc

- (void)showNewestTask {
    [self reloadList];
    if ([self rows].count) {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                              atScrollPosition:UITableViewScrollPositionTop animated:YES];
    }
}

- (void)showTypeFilter {
    NSArray<MVDownloadRow *> *all = [self allRows];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (MVDownloadRow *row in all) {
        counts[row.typeName] = @([counts[row.typeName] integerValue] + 1);
    }
    NSArray<NSString *> *types = @[@"Video", @"Audio", @"Document", @"Archive", @"Torrent", @"App", @"Other"];
    NSMutableArray<NSArray *> *entries = [NSMutableArray array];
    // The "All" row carries an empty category rather than NSNull: the sheet's
    // block takes a non-null string, and an empty string already means "no type
    // filter" everywhere else in this controller.
    [entries addObject:@[[MVLang t:@"All"], @"square.grid.2x2", @(all.count), @""]];
    for (NSString *type in types) {
        NSInteger count = [counts[type] integerValue];
        if (count == 0) continue;
        [entries addObject:@[[self localizedTypeName:type], [MVTaskCardCell symbolForKindName:type], @(count), type]];
    }
    MVTypeFilterSheet *sheet = [[MVTypeFilterSheet alloc] initWithTypes:entries selected:self.typeFilter ?: @""];
    __weak typeof(self) weakSelf = self;
    sheet.onSelect = ^(NSString *category) {
        weakSelf.typeFilter = category.length ? category : nil;
        [weakSelf reloadList];
    };
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
        presentation.prefersGrabberVisible = YES;
        presentation.preferredCornerRadius = 24;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)localizedTypeName:(NSString *)type {
    if ([type isEqualToString:@"Video"]) return [MVLang t:@"Video"];
    if ([type isEqualToString:@"Audio"]) return [MVLang t:@"Audio"];
    if ([type isEqualToString:@"Document"]) return [MVLang t:@"Documents"];
    if ([type isEqualToString:@"Archive"]) return [MVLang t:@"Archives"];
    if ([type isEqualToString:@"Torrent"]) return [MVLang t:@"Torrents"];
    if ([type isEqualToString:@"App"]) return [MVLang t:@"Apps"];
    return [MVLang t:@"Other"];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
