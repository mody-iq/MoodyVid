#import "MVTabsViewController.h"
#import "MVLang.h"
#import "MVTheme.h"

static NSString *const kTabCell = @"MVTabsCell";

@interface MVTabsCell : UICollectionViewCell
@property (nonatomic, strong) UIView *card;
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
        _card.backgroundColor = [MVTheme glassCard];
        [MVTheme applyCardStyle:_card cornerRadius:16];
        [self.contentView addSubview:_card];

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
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        _closeButton.tintColor = [MVTheme secondaryText];
        [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_closeButton];

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:14],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],

            [_hostLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_hostLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_hostLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],

            [_closeButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8],
            [_closeButton.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-8],
            [_closeButton.widthAnchor constraintEqualToConstant:28],
            [_closeButton.heightAnchor constraintEqualToConstant:28],
        ]];
    }
    return self;
}

- (void)closeTapped { if (self.onClose) self.onClose(); }

- (void)configureWithTab:(MVBrowserTab *)tab active:(BOOL)active {
    self.titleLabel.text = [tab displayTitle];
    self.hostLabel.text = tab.url.length ? [NSURL URLWithString:tab.url].host : @"";
    self.card.layer.borderWidth = active ? 2 : 0.5;
    self.card.layer.borderColor = active ? [MVTheme accent].CGColor
                                         : [[MVTheme cardBorder] colorWithAlphaComponent:0.3].CGColor;
}

@end

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
    self.view.backgroundColor = UIColor.clearColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = [MVLang t:@"Tabs"];
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [MVTheme text];
    [self.view addSubview:title];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
    add.tintColor = [MVTheme accent];
    [add addTarget:self action:@selector(newTab) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(12, 18, 18, 18);
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.translatesAutoresizingMaskIntoConstraints = NO;
    self.collection.backgroundColor = UIColor.clearColor;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    [self.collection registerClass:MVTabsCell.class forCellWithReuseIdentifier:kTabCell];
    [self.view addSubview:self.collection];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],

        [add.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [add.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [add.widthAnchor constraintEqualToConstant:34],
        [add.heightAnchor constraintEqualToConstant:34],

        [self.collection.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collection.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)newTab { if (self.onNewTab) self.onNewTab(); [self dismissViewControllerAnimated:YES completion:nil]; }

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
    return CGSizeMake(MAX(120, width), 110);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    MVBrowserTab *tab = self.tabs[indexPath.item];
    if (self.onSelect) self.onSelect(tab.identifier);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
