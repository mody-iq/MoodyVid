#import "MVTabsViewController.h"
#import "MVLang.h"
#import "MVTheme.h"

static NSString *const kTabCell = @"MVTabsCell";

#pragma mark - Cell

/// One tab card: a small glyph, the title, the host, and a close button. The
/// glyph carries the title's first letter rather than a page screenshot, which
/// would mean snapshotting every web view on every presentation.
@interface MVTabsCell : UICollectionViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *glyphTile;
@property (nonatomic, strong) UILabel *glyphLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hostLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (void)configureWithTab:(MVBrowserTab *)tab active:(BOOL)active;
@end

@implementation MVTabsCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _card = [UIView new];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [MVTheme applyCardStyle:_card cornerRadius:16];
        [self.contentView addSubview:_card];

        _glyphTile = [UIView new];
        _glyphTile.translatesAutoresizingMaskIntoConstraints = NO;
        [MVTheme applyIconTileStyle:_glyphTile tint:[MVTheme secondaryText]];
        [_card addSubview:_glyphTile];

        _glyphLabel = [UILabel new];
        _glyphLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _glyphLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        _glyphLabel.textColor = [MVTheme secondaryText];
        _glyphLabel.textAlignment = NSTextAlignmentCenter;
        [_glyphTile addSubview:_glyphLabel];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.numberOfLines = 2;
        [_card addSubview:_titleLabel];

        _hostLabel = [UILabel new];
        _hostLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _hostLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        _hostLabel.textColor = [MVTheme secondaryText];
        _hostLabel.numberOfLines = 1;
        [_card addSubview:_hostLabel];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        _closeButton.tintColor = [MVTheme secondaryText];
        _closeButton.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.12];
        _closeButton.layer.cornerRadius = 13.0;
        [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_closeButton];

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

            [_glyphTile.topAnchor constraintEqualToAnchor:_card.topAnchor constant:12],
            [_glyphTile.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_glyphTile.widthAnchor constraintEqualToConstant:34],
            [_glyphTile.heightAnchor constraintEqualToConstant:34],
            [_glyphLabel.centerXAnchor constraintEqualToAnchor:_glyphTile.centerXAnchor],
            [_glyphLabel.centerYAnchor constraintEqualToAnchor:_glyphTile.centerYAnchor],

            [_titleLabel.topAnchor constraintEqualToAnchor:_glyphTile.bottomAnchor constant:10],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],

            [_hostLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
            [_hostLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_hostLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_hostLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-12],

            [_closeButton.topAnchor constraintEqualToAnchor:_card.topAnchor constant:8],
            [_closeButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8],
            [_closeButton.widthAnchor constraintEqualToConstant:26],
            [_closeButton.heightAnchor constraintEqualToConstant:26],
        ]];
    }
    return self;
}

- (void)closeTapped { if (self.onClose) self.onClose(); }

- (void)configureWithTab:(MVBrowserTab *)tab active:(BOOL)active {
    NSString *title = [tab displayTitle];
    self.titleLabel.text = title.length ? title : [MVLang t:@"New tab"];
    NSString *host = tab.url.length ? [NSURL URLWithString:tab.url].host : @"";
    self.hostLabel.text = host.length ? host : [MVLang t:@"New tab"];
    self.glyphLabel.text = title.length ? [title substringToIndex:1].uppercaseString : @"+";
    // Resolve the colours into locals first: `.CGColor` after a `?:` mis-binds.
    UIColor *borderColor = active ? [MVTheme accent] : UIColor.clearColor;
    self.card.layer.borderWidth = active ? 2 : 0;
    self.card.layer.borderColor = borderColor.CGColor;
}

@end

#pragma mark - Controller

@interface MVTabsViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) NSArray<MVBrowserTab *> *tabs;
@property (nonatomic, copy) NSString *activeID;
@property (nonatomic, strong) UICollectionView *collection;
@end

@implementation MVTabsViewController

- (instancetype)initWithTabs:(NSArray<MVBrowserTab *> *)tabs activeIdentifier:(NSString *)activeID {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _tabs = tabs ?: @[];
        _activeID = [activeID copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme card];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = [MVLang t:@"Tabs"];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [MVTheme text];
    [self.view addSubview:title];

    UIButton *newTab = [UIButton buttonWithType:UIButtonTypeSystem];
    newTab.translatesAutoresizingMaskIntoConstraints = NO;
    [newTab setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    [newTab setTitle:[MVLang t:@"New tab"] forState:UIControlStateNormal];
    newTab.tintColor = [MVTheme accent];
    newTab.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    newTab.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [newTab addTarget:self action:@selector(newTab) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:newTab];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:[MVLang t:@"Done"] forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(12, 18, 24, 18);
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.translatesAutoresizingMaskIntoConstraints = NO;
    self.collection.backgroundColor = UIColor.clearColor;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    [self.collection registerClass:MVTabsCell.class forCellWithReuseIdentifier:kTabCell];
    [self.view addSubview:self.collection];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],

        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [newTab.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-18],
        [newTab.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [self.collection.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collection.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)newTab { if (self.onNewTab) self.onNewTab(); [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)doneTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - Collection

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.tabs.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MVTabsCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kTabCell forIndexPath:indexPath];
    MVBrowserTab *tab = self.tabs[indexPath.item];
    [cell configureWithTab:tab active:[tab.identifier isEqualToString:self.activeID]];
    __weak typeof(self) weakSelf = self;
    cell.onClose = ^{
        if (weakSelf.onClose) weakSelf.onClose(tab.identifier);
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    };
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = (collectionView.bounds.size.width - 36 - 12) / 2.0;
    return CGSizeMake(MAX(120, width), 132);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    MVBrowserTab *tab = self.tabs[indexPath.item];
    if (self.onSelect) self.onSelect(tab.identifier);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
