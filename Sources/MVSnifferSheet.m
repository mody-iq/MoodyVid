#import "MVSnifferSheet.h"
#import "MVSnifferStore.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVPaths.h"
#import "MVLog.h"

static NSString *const kItemCell = @"MVSnifferItemCell";

#pragma mark - Row

/// One detected link. A fixed 68pt row: icon, name, a subtitle that carries the
/// kind and the size, and a trailing Download button.
@interface MVSnifferRowCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconBack;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, copy, nullable) void (^onDownload)(void);
- (void)configureWithItem:(MVSnifferItem *)item;
@end

@implementation MVSnifferRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [UIView new];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        _card.backgroundColor = [MVTheme glassCard];
        _card.layer.cornerRadius = 14;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.layer.borderWidth = 0.5;
        _card.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.3].CGColor;
        [self.contentView addSubview:_card];

        _iconBack = [UIView new];
        _iconBack.translatesAutoresizingMaskIntoConstraints = NO;
        _iconBack.layer.cornerRadius = 10;
        _iconBack.layer.masksToBounds = YES;
        [_card addSubview:_iconBack];

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIFontWeightSemibold];
        [_card addSubview:_icon];

        _nameLabel = [UILabel new];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _nameLabel.textColor = [MVTheme text];
        _nameLabel.numberOfLines = 1;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_card addSubview:_nameLabel];

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _detailLabel.textColor = [MVTheme secondaryText];
        _detailLabel.numberOfLines = 1;
        [_card addSubview:_detailLabel];

        _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        _downloadButton.tintColor = [MVTheme accent];
        [_downloadButton addTarget:self action:@selector(downloadTapped) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_downloadButton];

        [NSLayoutConstraint activateConstraints:@[
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

            [_iconBack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_iconBack.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_iconBack.widthAnchor constraintEqualToConstant:36],
            [_iconBack.heightAnchor constraintEqualToConstant:36],

            [_icon.centerXAnchor constraintEqualToAnchor:_iconBack.centerXAnchor],
            [_icon.centerYAnchor constraintEqualToAnchor:_iconBack.centerYAnchor],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconBack.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:_downloadButton.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:12],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],

            [_downloadButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
            [_downloadButton.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_downloadButton.widthAnchor constraintEqualToConstant:36],
            [_downloadButton.heightAnchor constraintEqualToConstant:36],
        ]];
    }
    return self;
}

- (void)downloadTapped { if (self.onDownload) self.onDownload(); }

- (void)configureWithItem:(MVSnifferItem *)item {
    self.nameLabel.text = item.displayName;
    self.icon.image = [UIImage systemImageNamed:[MVSnifferItem symbolForKind:item.kind]];
    self.icon.tintColor = [MVTheme accent];
    self.iconBack.backgroundColor = [[MVTheme accent] colorWithAlphaComponent:0.14];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[MVLang t:[MVSnifferItem titleKeyForKind:item.kind]]];
    if (item.totalBytes > 0) [parts addObject:[MVPaths formatBytes:item.totalBytes]];
    else if (!item.probed) [parts addObject:[MVLang t:@"Checking…"]];
    // HLS and DASH have engines now; only torrent is still pending.
    if (item.kind == MVSniffKindTorrent) {
        [parts addObject:[MVLang t:@"Later update"]];
    }
    self.detailLabel.text = [parts componentsJoinedByString:@" • "];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onDownload = nil;
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
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = [MVLang t:@"Found media"];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [MVTheme text];
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [MVTheme secondaryText];
    [close addTarget:self action:@selector(dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = [MVLang t:@"Tap to download, long press for more"];
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitle.textColor = [MVTheme secondaryText];
    [self.view addSubview:subtitle];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 76;
    [self.tableView registerClass:MVSnifferRowCell.class forCellReuseIdentifier:kItemCell];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = [MVLang t:@"Nothing found yet"];
    self.emptyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.emptyLabel.textColor = [MVTheme secondaryText];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    [self.view addSubview:self.emptyLabel];

    // Page actions: the yt-dlp path is what makes an un-sniffable page (a site
    // whose stream is behind a blob or a token) still downloadable.
    UIStackView *actions = [UIStackView new];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;

    UIButton *all = [UIButton buttonWithType:UIButtonTypeSystem];
    [all setTitle:[MVLang t:@"Download all"] forState:UIControlStateNormal];
    [MVTheme applyPrimaryButtonStyle:all];
    [all addTarget:self action:@selector(downloadAll) forControlEvents:UIControlEventTouchUpInside];

    UIButton *page = [UIButton buttonWithType:UIButtonTypeSystem];
    [page setTitle:[MVLang t:@"Download page with yt-dlp"] forState:UIControlStateNormal];
    page.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    page.titleLabel.numberOfLines = 2;
    [MVTheme applyCardStyle:page cornerRadius:18];
    [page setTitleColor:[MVTheme accent] forState:UIControlStateNormal];
    [page addTarget:self action:@selector(downloadPage) forControlEvents:UIControlEventTouchUpInside];

    [actions addArrangedSubview:all];
    [actions addArrangedSubview:page];
    [self.view addSubview:actions];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],

        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
        [close.heightAnchor constraintEqualToConstant:32],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [self.tableView.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:12],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-8],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],

        [actions.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [actions.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [actions.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [actions.heightAnchor constraintEqualToConstant:46],
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
    // A page that plays through a blob (YouTube and friends) yields no sniffable
    // link, which left the sheet empty even though the page is downloadable. Offer
    // the page itself, at the top, so the row is right there.
    if ([MVSnifferItem isVideoPageURL:self.pageURL]) {
        MVSnifferItem *page = [MVSnifferItem itemWithURL:self.pageURL
                                                pageURL:self.pageURL
                                              pageTitle:self.pageTitle
                                                   mime:nil];
        page.kind = MVSniffKindPage;
        page.suggestedFilename = self.pageTitle.length ? self.pageTitle : page.displayName;
        page.probed = YES;   // nothing to probe; a page has no size
        page.totalBytes = 0;
        [items insertObject:page atIndex:0];
    }
    self.items = items;
    self.emptyLabel.hidden = self.items.count > 0;
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MVSnifferRowCell *cell = [tableView dequeueReusableCellWithIdentifier:kItemCell forIndexPath:indexPath];
    MVSnifferItem *item = self.items[indexPath.row];
    [cell configureWithItem:item];
    __weak typeof(self) weakSelf = self;
    cell.onDownload = ^{ [weakSelf downloadItem:item]; };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self downloadItem:self.items[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
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

- (void)downloadItem:(MVSnifferItem *)item {
    if (!item || !self.onDownload) return;
    self.onDownload(@[item]);
    [self dismissSheet];
}

- (void)downloadAll {
    if (!self.items.count || !self.onDownload) return;
    self.onDownload(self.items.copy);
    [self dismissSheet];
}

- (void)downloadPage {
    if (!self.pageURL.length || !self.onDownloadPageWithYTDlp) return;
    // Dismiss first: the browser then presents its quality sheet, and two
    // presentations at once are dropped silently.
    NSString *url = self.pageURL;
    NSString *title = self.pageTitle ?: @"";
    void (^handler)(NSString *, NSString *) = self.onDownloadPageWithYTDlp;
    [self dismissViewControllerAnimated:YES completion:^{
        handler(url, title);
    }];
}

@end
