#import "MVSnifferSheet.h"
#import "MVSnifferStore.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"

static NSString *const kItemCell = @"MVSnifferItemCell";
static NSString *const kQualityCell = @"MVSnifferQualityCell";

/// The qualities the page itself can be fetched at, best first. "best" lets
/// yt-dlp choose; 1080 and above is fetched as two streams and muxed on device.
static NSArray<NSArray<NSString *> *> *MVQualityOptions(void) {
    static NSArray *options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        options = @[
            @[@"Best available", @"best"],
            @[@"1080p HD", @"1080"],
            @[@"Up to 720p", @"720p"],
            @[@"Up to 480p", @"480p"],
            @[@"Audio only (M4A)", @"audio"],
            @[@"MP3 (audio)", @"mp3"],
        ];
    });
    return options;
}

#pragma mark - Quality row

/// One quality choice. A plain row: the list itself is the answer to the
/// question the sheet asked, so it needs no card around each line.
@interface MVSnifferQualityCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title symbol:(NSString *)symbol;
@end

@implementation MVSnifferQualityCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [MVTheme card];
        self.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.textLabel.textColor = [MVTheme text];
        self.imageView.tintColor = [MVTheme accent];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title symbol:(NSString *)symbol {
    self.textLabel.text = title;
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

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (self.offersPage ? 1 : 0) + (self.items.count ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.offersPage && section == 0) return (NSInteger)MVQualityOptions().count;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.offersPage && section == 0) return [MVLang t:@"Video quality"];
    return [MVLang t:@"Files on this page"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.offersPage && indexPath.section == 0) {
        MVSnifferQualityCell *cell = [tableView dequeueReusableCellWithIdentifier:kQualityCell forIndexPath:indexPath];
        NSArray<NSString *> *option = MVQualityOptions()[indexPath.row];
        NSString *symbol = indexPath.row == 0 ? @"wand.and.stars"
                         : (indexPath.row >= 4 ? @"music.note" : @"film");
        [cell configureWithTitle:[MVLang t:option[0]] symbol:symbol];
        return cell;
    }
    MVSnifferItemCell *cell = [tableView dequeueReusableCellWithIdentifier:kItemCell forIndexPath:indexPath];
    [cell configureWithItem:self.items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.offersPage && indexPath.section == 0) {
        [self chooseQuality:MVQualityOptions()[indexPath.row][1]];
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
