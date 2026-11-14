#import "MVSnifferSheet.h"
#import "MVSnifferStore.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVPython.h"

static NSString *const kItemCell = @"MVSnifferItemCell";
static NSString *const kQualityCell = @"MVSnifferQualityCell";

/// These rows never move while the metadata request is in flight. Actual
/// variants are appended below them; if probing fails, presets are appended.
static NSArray<NSDictionary *> *MVBaseQualityOptions(void) {
    return @[
        @{@"title": [MVLang t:@"Best available"], @"quality": @"best", @"symbol": @"wand.and.stars"},
        @{@"title": [MVLang t:@"Audio only (M4A)"], @"quality": @"audio", @"symbol": @"music.note"},
        @{@"title": [MVLang t:@"MP3 (audio)"], @"quality": @"mp3", @"symbol": @"music.note"},
    ];
}

static NSArray<NSDictionary *> *MVFallbackQualityOptions(void) {
    return @[
        @{@"title": [MVLang t:@"1080p HD"], @"quality": @"1080", @"symbol": @"film"},
        @{@"title": [MVLang t:@"Up to 720p"], @"quality": @"720p", @"symbol": @"film"},
        @{@"title": [MVLang t:@"Up to 480p"], @"quality": @"480p", @"symbol": @"film"},
    ];
}

#pragma mark - Quality row

/// One quality choice. A plain row: the list itself is the answer to the
/// question the sheet asked, so it needs no card around each line.
@interface MVSnifferQualityCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title detail:(nullable NSString *)detail symbol:(NSString *)symbol;
@end

@implementation MVSnifferQualityCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [MVTheme card];
        self.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.textLabel.textColor = [MVTheme text];
        self.detailTextLabel.font = [UIFont systemFontOfSize:12];
        self.detailTextLabel.textColor = [MVTheme secondaryText];
        self.imageView.tintColor = [MVTheme accent];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol {
    self.textLabel.text = title;
    self.detailTextLabel.text = detail;
    self.imageView.image = [UIImage systemImageNamed:symbol];
    self.imageView.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
}

@end

#pragma mark - Item row

/// One link the sniffer found: glyph, name, and the kind with its size. Tapping
/// downloads it; swiping copies the link.
@interface MVSnifferItemCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIImageView *icon;
- (void)configureWithItem:(MVSnifferItem *)item;
@end

@implementation MVSnifferItemCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [MVTheme card];
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.preferredSymbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
        [self.contentView addSubview:_icon];

        _nameLabel = [UILabel new];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _nameLabel.textColor = [MVTheme text];
        _nameLabel.numberOfLines = 1;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self.contentView addSubview:_nameLabel];

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _detailLabel.textColor = [MVTheme secondaryText];
        _detailLabel.numberOfLines = 1;
        [self.contentView addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_icon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [_icon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:24],
            [_icon.heightAnchor constraintEqualToConstant:24],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:14],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        ]];
    }
    return self;
}

- (void)configureWithItem:(MVSnifferItem *)item {
    self.nameLabel.text = item.displayName;
    self.icon.image = [UIImage systemImageNamed:[MVSnifferItem symbolForKind:item.kind]];
    self.icon.tintColor = [MVTheme iconTint];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[MVLang t:[MVSnifferItem titleKeyForKind:item.kind]]];
    if (item.totalBytes > 0) [parts addObject:[MVPaths formatBytes:item.totalBytes]];
    else if (!item.probed) [parts addObject:[MVLang t:@"Checking…"]];
    self.detailLabel.text = [parts componentsJoinedByString:@" · "];
}

@end

#pragma mark - Sheet

@interface MVSnifferSheetViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *tabID;
@property (nonatomic, copy, nullable) NSString *pageURL;
@property (nonatomic, copy, nullable) NSString *pageTitle;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<MVSnifferItem *> *items;
@property (nonatomic) BOOL offersPage;
@property (nonatomic) BOOL readingFormats;
@property (nonatomic, copy) NSArray<NSDictionary *> *qualityChoices;
@property (nonatomic, strong, nullable) id storeObserver;
@end

@implementation MVSnifferSheetViewController

- (instancetype)initWithTabIdentifier:(NSString *)tabID
                             pageURL:(NSString *)pageURL
                           pageTitle:(NSString *)pageTitle {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _tabID = [tabID copy];
        _pageURL = [pageURL copy];
        _pageTitle = [pageTitle copy];
        _items = [NSMutableArray array];
        _qualityChoices = MVBaseQualityOptions();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme background];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.pageTitle.length ? self.pageTitle : [MVLang t:@"Download"];
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    title.textColor = [MVTheme text];
    title.numberOfLines = 1;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [MVTheme secondaryText];
    [close addTarget:self action:@selector(dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 58;
    [self.tableView registerClass:MVSnifferQualityCell.class forCellReuseIdentifier:kQualityCell];
    [self.tableView registerClass:MVSnifferItemCell.class forCellReuseIdentifier:kItemCell];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = [MVLang t:@"Nothing found yet"];
    self.emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.emptyLabel.textColor = [MVTheme secondaryText];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],

        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
        [close.heightAnchor constraintEqualToConstant:32],

        [self.tableView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];

    self.view.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;

    [self reload];
    if (self.offersPage) [self readFormats];
    __weak typeof(self) weakSelf = self;
    self.storeObserver = [NSNotificationCenter.defaultCenter addObserverForName:MVSnifferStoreDidChangeNotification
                                                                        object:nil queue:NSOperationQueue.mainQueue
                                                                    usingBlock:^(NSNotification *note) {
        [weakSelf reload];
    }];
}

- (void)dealloc {
    if (self.storeObserver) [NSNotificationCenter.defaultCenter removeObserver:self.storeObserver];
}

- (void)dismissSheet { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    NSMutableArray<MVSnifferItem *> *items =
        ([MVSnifferStore.shared itemsForTab:self.tabID].mutableCopy ?: [NSMutableArray array]);
    self.items = items;
    // Offer the page itself when it is a known video page, or when the sniffer
    // found nothing to download — otherwise a page whose stream it cannot see
    // would be a dead end. Latch it on, because a link the sniffer finds a moment
    // later must not pull the quality list out from under the user's finger.
    BOOL videoPage = self.pageURL.length > 0 && [MVSnifferItem isVideoPageURL:self.pageURL];
    if (videoPage || items.count == 0) self.offersPage = self.pageURL.length > 0;
    self.emptyLabel.hidden = (self.offersPage || self.items.count > 0);
    [self.tableView reloadData];
}

/// Metadata is optional; a failed probe leaves the familiar presets available.
/// Starting a download never waits for it. No browser cookies are passed to
/// yt-dlp, just as with the existing page downloader.
- (void)readFormats {
    if (!self.pageURL.length) return;
    self.readingFormats = YES;
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [[MVPython shared] call:@"downloader" function:@"inspect_formats" args:@[self.pageURL]
                 completion:^(NSDictionary *result, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *formats = [result[@"formats"] isKindOfClass:NSArray.class] ? result[@"formats"] : @[];
        NSMutableArray *choices = [MVBaseQualityOptions() mutableCopy];
        for (id value in formats) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *item = value;
            NSString *quality = [item[@"quality"] isKindOfClass:NSString.class] ? item[@"quality"] : nil;
            NSNumber *height = [item[@"height"] isKindOfClass:NSNumber.class] ? item[@"height"] : nil;
            NSString *ext = [item[@"ext"] isKindOfClass:NSString.class] ? item[@"ext"] : nil;
            if (!quality.length || !height || height.integerValue <= 0 || !ext.length) continue;
            if (![quality hasPrefix:@"fmt:"] && ![quality hasPrefix:@"split:"]) continue;
            NSMutableString *title = [NSMutableString stringWithFormat:@"%ldp · %@", (long)height.integerValue, ext.uppercaseString];
            NSInteger fps = [item[@"fps"] isKindOfClass:NSNumber.class] ? [item[@"fps"] integerValue] : 0;
            if (fps > 30) [title appendFormat:@" · %ld fps", (long)fps];
            long long size = [item[@"size"] isKindOfClass:NSNumber.class] ? [item[@"size"] longLongValue] : 0;
            BOOL videoOnly = [item[@"video_only"] boolValue];
            NSMutableArray *details = [NSMutableArray array];
            if (size > 0) {
                NSString *prefix = [item[@"estimated"] boolValue] ? @"≈ " : @"";
                [details addObject:[prefix stringByAppendingString:[MVPaths formatBytes:size]]];
            }
            if (videoOnly) [details addObject:[MVLang t:@"Video size only; audio is separate"]];
            [choices addObject:@{@"title": title, @"quality": quality, @"symbol": @"film",
                                 @"detail": [details componentsJoinedByString:@" · "]}];
        }
        if (choices.count == MVBaseQualityOptions().count) [choices addObjectsFromArray:MVFallbackQualityOptions()];
        [self_ applyFormatChoicesWhenIdle:choices];
    }];
}

- (void)applyFormatChoicesWhenIdle:(NSArray<NSDictionary *> *)choices {
    // Do not replace rows under a finger while a user is choosing a file.
    if (self.tableView.tracking || self.tableView.dragging || self.tableView.decelerating) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf applyFormatChoicesWhenIdle:choices];
        });
        return;
    }
    self.readingFormats = NO;
    self.qualityChoices = choices;
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (self.offersPage ? 1 : 0) + (self.items.count ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.offersPage && section == 0) return (NSInteger)self.qualityChoices.count;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.offersPage && section == 0) {
        return self.readingFormats ? [MVLang t:@"Reading link..."] : [MVLang t:@"Video quality"];
    }
    return [MVLang t:@"Files on this page"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.offersPage && indexPath.section == 0) {
        MVSnifferQualityCell *cell = [tableView dequeueReusableCellWithIdentifier:kQualityCell forIndexPath:indexPath];
        NSDictionary *option = self.qualityChoices[indexPath.row];
        [cell configureWithTitle:option[@"title"] detail:option[@"detail"] symbol:option[@"symbol"]];
        return cell;
    }
    MVSnifferItemCell *cell = [tableView dequeueReusableCellWithIdentifier:kItemCell forIndexPath:indexPath];
    [cell configureWithItem:self.items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.offersPage && indexPath.section == 0) {
        [self chooseQuality:self.qualityChoices[indexPath.row][@"quality"]];
    } else {
        [self downloadItem:self.items[indexPath.row]];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.offersPage && indexPath.section == 0) return nil;
    MVSnifferItem *item = self.items[indexPath.row];
    UIContextualAction *copy = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                       title:[MVLang t:@"Copy link"]
                                                                     handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        UIPasteboard.generalPasteboard.string = item.url;
        completion(YES);
    }];
    copy.backgroundColor = [MVTheme accent];
    return [UISwipeActionsConfiguration configurationWithActions:@[copy]];
}

#pragma mark - Actions

- (void)chooseQuality:(NSString *)quality {
    if (!self.pageURL.length || !self.onDownloadPage) return;
    // Dismiss first: the browser starts the job from its own completion, and two
    // presentations at once are dropped silently.
    NSString *url = self.pageURL;
    NSString *title = self.pageTitle ?: @"";
    void (^handler)(NSString *, NSString *, NSString *) = self.onDownloadPage;
    [self dismissViewControllerAnimated:YES completion:^{
        handler(url, title, quality);
    }];
}

- (void)downloadItem:(MVSnifferItem *)item {
    if (!item || !self.onDownload) return;
    self.onDownload(@[item]);
    [self dismissSheet];
}

@end
