#import "MVDetailsSheet.h"
#import "MVTheme.h"
#import "MVLang.h"
#import "MVPaths.h"
#import "MVDownloadActions.h"
#import "MVTaskCardCell.h"
#import "MVTaskStore.h"

@interface MVDetailsSheet ()
@property (nonatomic, strong) MVDownloadRow *row;
@end

@implementation MVDetailsSheet {
    UIScrollView *_scroll;
    UIStackView *_stack;
}

- (instancetype)initWithRow:(MVDownloadRow *)row {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _row = row;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MVTheme card];

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _stack = [UIStackView new];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10;
    [_scroll addSubview:_stack];

    CGFloat pad = [MVTheme screenPadding];
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:pad],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-pad],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:pad],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-pad],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-pad * 2],
    ]];

    [self build];
    [self observeChanges];
}

- (void)observeChanges {
    for (NSString *name in @[MVDownloadStoreDidChangeNotification, MVTaskStoreDidChangeNotification,
                             MVLangDidChangeNotification, MVThemeDidChangeNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild)
                                                   name:name object:nil];
    }
}

- (void)rebuild {
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self build];
}

- (void)build {
    MVDownloadRow *row = self.row;

    // Header: icon tile, title, source line.
    UIView *header = [UIView new];
    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [MVTheme accent];
    icon.image = [UIImage systemImageNamed:[MVTaskCardCell symbolForKindName:row.typeName]];
    UIView *tile = [UIView new];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyIconTileStyle:tile tint:[MVTheme accent]];
    [tile addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [MVTheme text];
    title.numberOfLines = 0;
    title.text = row.title;

    UILabel *typeLabel = [UILabel new];
    typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    typeLabel.font = [MVTheme cardDetailFont];
    typeLabel.textColor = [MVTheme secondaryText];
    typeLabel.text = row.typeName;

    [header addSubview:tile];
    [header addSubview:title];
    [header addSubview:typeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [tile.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [tile.topAnchor constraintEqualToAnchor:header.topAnchor],
        [tile.widthAnchor constraintEqualToConstant:44],
        [tile.heightAnchor constraintEqualToConstant:44],
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
        [title.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:12],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor],
        [typeLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [typeLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [typeLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [typeLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];
    [_stack addArrangedSubview:header];

    // Progress bar while active.
    if (row.isActive && !row.isFinished) {
        UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        bar.progressTintColor = [MVTheme accent];
        bar.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.22];
        bar.progress = (float)MAX(0.02, row.progress);
        [_stack addArrangedSubview:bar];
    }

    // The facts worth showing: what it costs, how fast, how long, where it
    // landed. The raw source URL and the engine's own status line are debug
    // detail — the URL is one tap away under "Copy link".
    NSMutableArray<NSArray *> *facts = [NSMutableArray array];
    if (row.totalBytes > 0) {
        [facts addObject:@[[MVLang t:@"Size"],
                           [NSString stringWithFormat:@"%@ %@ %@", [MVPaths formatBytes:row.doneBytes],
                            [MVLang t:@"of"], [MVPaths formatBytes:row.totalBytes]]]];
    }
    if (row.isActive && row.speed > 0) {
        [facts addObject:@[[MVLang t:@"Speed"], [MVPaths formatSpeed:row.speed]]];
    }
    if (row.isActive && row.eta > 0) {
        [facts addObject:@[[MVLang t:@"Time left"], [MVPaths formatDuration:row.eta]]];
    }
    if (row.path.length) [facts addObject:@[[MVLang t:@"Saved path"], row.path.lastPathComponent]];

    if (facts.count) {
        UIView *factsCard = [UIView new];
        [MVTheme applyCardStyle:factsCard cornerRadius:[MVTheme cardCornerRadius]];
        UIStackView *factsStack = [UIStackView new];
        factsStack.translatesAutoresizingMaskIntoConstraints = NO;
        factsStack.axis = UILayoutConstraintAxisVertical;
        factsStack.spacing = 10;
        [factsCard addSubview:factsStack];
        [NSLayoutConstraint activateConstraints:@[
            [factsStack.topAnchor constraintEqualToAnchor:factsCard.topAnchor constant:14],
            [factsStack.bottomAnchor constraintEqualToAnchor:factsCard.bottomAnchor constant:-14],
            [factsStack.leadingAnchor constraintEqualToAnchor:factsCard.leadingAnchor constant:14],
            [factsStack.trailingAnchor constraintEqualToAnchor:factsCard.trailingAnchor constant:-14],
        ]];
        for (NSArray *fact in facts) {
            [factsStack addArrangedSubview:[self factRowTitle:fact[0] value:fact[1]]];
        }
        [_stack addArrangedSubview:factsCard];
    }

    if (row.errorText.length) {
        UILabel *err = [UILabel new];
        err.font = [MVTheme cardDetailFont];
        err.textColor = [MVTheme danger];
        err.numberOfLines = 0;
        err.text = row.errorText;
        [_stack addArrangedSubview:err];
    }

    // Actions that present another screen run only after this sheet closes;
    // otherwise its presenter is already presenting and UIKit rejects the share
    // sheet, player or delete confirmation. Weak captures also avoid a cycle
    // from the buttons back to their owning controller.
    __weak typeof(self) weakSelf = self;
    if (row.isFinished && row.path.length) {
        [_stack addArrangedSubview:[self actionButton:[MVLang t:@"Open"] symbol:@"play.fill" primary:YES
                                             handler:^{ [weakSelf dismissThenPerform:weakSelf.onPlay]; }]];
        [_stack addArrangedSubview:[self iconRow:@[
            @[[MVLang t:@"Share"], @"square.and.arrow.up", ^{ [weakSelf dismissThenPerform:weakSelf.onShare]; }],
            @[[MVLang t:@"Save to Photos"], @"photo.on.rectangle", ^{ [weakSelf dismissThenPerform:weakSelf.onSaveToPhotos]; }],
            @[[MVLang t:@"Show in Files"], @"folder", ^{ [weakSelf dismissThenPerform:weakSelf.onRevealInFiles]; }],
            @[[MVLang t:@"Copy link"], @"doc.on.doc", ^{ UIPasteboard.generalPasteboard.string = row.url; }],
        ]]];
    } else if (row.isPaused || row.isFailed) {
        [_stack addArrangedSubview:[self actionButton:[MVLang t:@"Resume"] symbol:@"play.fill" primary:YES
                                             handler:^{ [MVDownloadActions resumeRow:row]; [weakSelf dismissSelf]; }]];
        [_stack addArrangedSubview:[self iconRow:@[
            @[[MVLang t:@"Copy link"], @"doc.on.doc", ^{ UIPasteboard.generalPasteboard.string = row.url; }],
        ]]];
    } else if (row.isActive) {
        [_stack addArrangedSubview:[self actionButton:[MVLang t:@"Pause"] symbol:@"pause.fill" primary:YES
                                             handler:^{ [MVDownloadActions pauseRow:row]; [weakSelf dismissSelf]; }]];
        [_stack addArrangedSubview:[self iconRow:@[
            @[[MVLang t:@"Copy link"], @"doc.on.doc", ^{ UIPasteboard.generalPasteboard.string = row.url; }],
        ]]];
    } else {
        [_stack addArrangedSubview:[self iconRow:@[
            @[[MVLang t:@"Copy link"], @"doc.on.doc", ^{ UIPasteboard.generalPasteboard.string = row.url; }],
        ]]];
    }
    [_stack addArrangedSubview:[self actionButton:[MVLang t:@"Delete"] symbol:@"trash" primary:NO destructive:YES
                                         handler:^{ [weakSelf dismissThenPerform:weakSelf.onDelete]; }]];
}

- (void)dismissThenPerform:(void (^)(MVDownloadRow *))action {
    MVDownloadRow *row = self.row;
    [self dismissViewControllerAnimated:YES completion:^{ if (action) action(row); }];
}

/// A row of equally sized icon buttons, each with its own accessibility label.
/// The labels are what a screen reader announces; the row stays compact because
/// the icons carry the meaning visually.
- (UIView *)iconRow:(NSArray<NSArray *> *)items {
    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10;
    for (NSArray *item in items) {
        NSString *title = item[0];
        NSString *symbol = item[1];
        void (^handler)(void) = item[2];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        b.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.12];
        b.tintColor = [MVTheme text];
        b.layer.cornerRadius = 14.0;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
        b.accessibilityLabel = title;
        [b.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) { handler(); }] forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:b];
    }
    return row;
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIView *)factRowTitle:(NSString *)title value:(NSString *)value {
    UIView *box = [UIView new];
    UILabel *key = [UILabel new];
    key.translatesAutoresizingMaskIntoConstraints = NO;
    key.font = [MVTheme cardDetailFont];
    key.textColor = [MVTheme secondaryText];
    key.text = title;
    [key setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *val = [UILabel new];
    val.translatesAutoresizingMaskIntoConstraints = NO;
    val.font = [MVTheme cardDetailFont];
    val.textColor = [MVTheme text];
    val.numberOfLines = 2;
    val.textAlignment = NSTextAlignmentNatural;
    val.text = value;

    [box addSubview:key];
    [box addSubview:val];
    [NSLayoutConstraint activateConstraints:@[
        [key.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [key.topAnchor constraintEqualToAnchor:box.topAnchor],
        [key.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [val.leadingAnchor constraintGreaterThanOrEqualToAnchor:key.trailingAnchor constant:12],
        [val.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
        [val.topAnchor constraintEqualToAnchor:box.topAnchor],
        [val.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
    ]];
    return box;
}

- (UIButton *)actionButton:(NSString *)title symbol:(NSString *)symbol primary:(BOOL)primary
                   handler:(void (^)(void))handler {
    return [self actionButton:title symbol:symbol primary:primary destructive:NO handler:handler];
}

- (UIButton *)actionButton:(NSString *)title symbol:(NSString *)symbol primary:(BOOL)primary
               destructive:(BOOL)destructive handler:(void (^)(void))handler {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    if (primary) {
        [MVTheme applyPrimaryButtonStyle:b];
    } else {
        b.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.12];
        [b setTitleColor:destructive ? [MVTheme danger] : [MVTheme text] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 14.0;
        b.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [b setTitle:title forState:UIControlStateNormal];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = primary ? UIColor.whiteColor : (destructive ? [MVTheme danger] : [MVTheme accent]);
    b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    if (handler) {
        UIAction *action = [UIAction actionWithHandler:^(UIAction *a) { handler(); }];
        [b addAction:action forControlEvents:UIControlEventTouchUpInside];
    }
    return b;
}

@end
