#import "MVBrowserHome.h"
#import "MVBrowserHistory.h"
#import "MVLang.h"
#import "MVTheme.h"
#import <objc/runtime.h>

static NSString *const kShortcutsKey = @"MVBrowserShortcuts";

@implementation MVBrowserShortcut

+ (instancetype)name:(NSString *)name url:(NSString *)url symbol:(NSString *)symbol color:(NSString *)color {
    MVBrowserShortcut *shortcut = [MVBrowserShortcut new];
    shortcut.name = name; shortcut.url = url; shortcut.symbol = symbol; shortcut.color = color;
    return shortcut;
}

- (NSDictionary *)dictionary {
    return @{@"name": self.name ?: @"", @"url": self.url ?: @"",
             @"symbol": self.symbol ?: @"globe", @"color": self.color ?: @"#0FA0B0"};
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    return [self name:dict[@"name"] ?: @"" url:dict[@"url"] ?: @""
               symbol:dict[@"symbol"] ?: @"globe" color:dict[@"color"] ?: @"#0FA0B0"];
}

@end

@interface MVBrowserHomeView () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UITextField *historySearch;
@property (nonatomic, strong) UIStackView *shortcutGrid;
@property (nonatomic, strong) UIStackView *bookmarkList;
@property (nonatomic, strong) UIStackView *historyList;
@property (nonatomic, strong) UILabel *historyEmpty;
@property (nonatomic, strong) UILabel *bookmarkEmpty;
@end

@implementation MVBrowserHomeView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = UIColor.clearColor;

        _scroll = [UIScrollView new];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.alwaysBounceVertical = YES;
        _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
        [self addSubview:_scroll];

        _stack = [UIStackView new];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 18;
        [_scroll addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:18],
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:18],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-18],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-24],
        ]];

        [self buildSections];
        [self reload];
    }
    return self;
}

- (UILabel *)sectionTitle:(NSString *)key {
    UILabel *label = [UILabel new];
    label.text = [MVLang t:key];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [MVTheme secondaryText];
    return label;
}

- (void)buildSections {
    // Shortcuts
    [_stack addArrangedSubview:[self sectionTitle:@"Shortcuts"]];
    _shortcutGrid = [UIStackView new];
    _shortcutGrid.axis = UILayoutConstraintAxisVertical;
    _shortcutGrid.spacing = 12;
    [_stack addArrangedSubview:_shortcutGrid];

    // Bookmarks
    [_stack addArrangedSubview:[self sectionTitle:@"Bookmarks"]];
    _bookmarkList = [UIStackView new];
    _bookmarkList.axis = UILayoutConstraintAxisVertical;
    _bookmarkList.spacing = 8;
    [_stack addArrangedSubview:_bookmarkList];
    _bookmarkEmpty = [self emptyLabel:@"No bookmarks yet"];
    [_stack addArrangedSubview:_bookmarkEmpty];

    // History
    [_stack addArrangedSubview:[self sectionTitle:@"History"]];
    _historySearch = [UITextField new];
    _historySearch.placeholder = [MVLang t:@"Search history"];
    _historySearch.borderStyle = UITextBorderStyleRoundedRect;
    _historySearch.backgroundColor = [MVTheme card];
    _historySearch.textColor = [MVTheme text];
    _historySearch.autocorrectionType = UITextAutocorrectionTypeNo;
    _historySearch.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _historySearch.clearButtonMode = UITextFieldViewModeWhileEditing;
    _historySearch.returnKeyType = UIReturnKeySearch;
    _historySearch.delegate = self;
    [_historySearch addTarget:self action:@selector(historyFilterChanged) forControlEvents:UIControlEventEditingChanged];
    [_historySearch.heightAnchor constraintEqualToConstant:38].active = YES;
    [_stack addArrangedSubview:_historySearch];

    _historyList = [UIStackView new];
    _historyList.axis = UILayoutConstraintAxisVertical;
    _historyList.spacing = 8;
    [_stack addArrangedSubview:_historyList];

    _historyEmpty = [self emptyLabel:@"No history yet"];
    [_stack addArrangedSubview:_historyEmpty];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:[MVLang t:@"Clear history"] forState:UIControlStateNormal];
    [clear setTitleColor:[MVTheme danger] forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [clear addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stack addArrangedSubview:clear];
}

- (UILabel *)emptyLabel:(NSString *)key {
    UILabel *label = [UILabel new];
    label.text = [MVLang t:key];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [MVTheme secondaryText];
    label.numberOfLines = 0;
    return label;
}

#pragma mark - Shortcuts

+ (NSArray<MVBrowserShortcut *> *)defaultShortcuts {
    return @[
        [MVBrowserShortcut name:@"Google" url:@"https://www.google.com" symbol:@"magnifyingglass" color:@"#4285F4"],
        [MVBrowserShortcut name:@"YouTube" url:@"https://m.youtube.com" symbol:@"play.rectangle.fill" color:@"#FF3B30"],
        [MVBrowserShortcut name:@"Instagram" url:@"https://www.instagram.com" symbol:@"camera.fill" color:@"#E1306C"],
        [MVBrowserShortcut name:@"Facebook" url:@"https://m.facebook.com" symbol:@"f.circle.fill" color:@"#1877F2"],
        [MVBrowserShortcut name:@"TikTok" url:@"https://www.tiktok.com" symbol:@"music.note" color:@"#25F4EE"],
        [MVBrowserShortcut name:@"X" url:@"https://x.com" symbol:@"xmark" color:@"#8E8E93"],
        [MVBrowserShortcut name:@"Reddit" url:@"https://www.reddit.com" symbol:@"bubble.left.fill" color:@"#FF4500"],
        [MVBrowserShortcut name:@"SoundCloud" url:@"https://m.soundcloud.com" symbol:@"waveform" color:@"#FF5500"],
        [MVBrowserShortcut name:@"Pinterest" url:@"https://www.pinterest.com" symbol:@"p.circle.fill" color:@"#E60023"],
        [MVBrowserShortcut name:@"Wikipedia" url:@"https://www.wikipedia.org" symbol:@"book.fill" color:@"#636E72"],
    ];
}

+ (NSArray<MVBrowserShortcut *> *)shortcuts {
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:kShortcutsKey];
    if (!raw.count) return [self defaultShortcuts];
    NSMutableArray<MVBrowserShortcut *> *out = [NSMutableArray array];
    for (NSDictionary *dict in raw) {
        if ([dict isKindOfClass:NSDictionary.class]) [out addObject:[MVBrowserShortcut fromDictionary:dict]];
    }
    if (!out.count) return [self defaultShortcuts];
    // A saved list keeps the user's own tiles, but a built-in site added in an
    // update (Google) must still appear, so append any default whose URL is not
    // already there.
    NSMutableSet<NSString *> *urls = [NSMutableSet set];
    for (MVBrowserShortcut *shortcut in out) [urls addObject:shortcut.url];
    for (MVBrowserShortcut *builtin in [self defaultShortcuts]) {
        if (![urls containsObject:builtin.url]) [out addObject:builtin];
    }
    return out;
}

+ (void)setShortcuts:(NSArray<MVBrowserShortcut *> *)shortcuts {
    NSMutableArray *out = [NSMutableArray array];
    for (MVBrowserShortcut *shortcut in shortcuts) [out addObject:[shortcut dictionary]];
    [NSUserDefaults.standardUserDefaults setObject:out forKey:kShortcutsKey];
}

#pragma mark - Reload

- (void)reload {
    [self rebuildShortcuts];
    [self rebuildBookmarks];
    [self rebuildHistory];
    self.semanticContentAttribute = MVLang.shared.isRTL
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
}

- (void)rebuildShortcuts {
    for (UIView *view in _shortcutGrid.arrangedSubviews.copy) {
        [_shortcutGrid removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MVBrowserShortcut *> *shortcuts = [MVBrowserHomeView shortcuts];
    // Four per row keeps the tiles square on an XS Max and still readable in
    // landscape (the row simply gets wider).
    const NSInteger perRow = 4;
    for (NSUInteger i = 0; i < shortcuts.count; i += perRow) {
        UIStackView *row = [UIStackView new];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 12;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger j = i; j < MIN(i + perRow, shortcuts.count); j++) {
            [row addArrangedSubview:[self tileForShortcut:shortcuts[j]]];
        }
        // Pad the last row so the tiles keep their width instead of stretching.
        for (NSUInteger k = row.arrangedSubviews.count; k < perRow; k++) {
            [row addArrangedSubview:[UIView new]];
        }
        [_shortcutGrid addArrangedSubview:row];
    }
}

- (UIView *)tileForShortcut:(MVBrowserShortcut *)shortcut {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [MVTheme glassCard];
    [MVTheme applyCardStyle:button cornerRadius:16];
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [button setTitle:shortcut.name forState:UIControlStateNormal];
    [button setTitleColor:[MVTheme text] forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:shortcut.symbol] forState:UIControlStateNormal];
    [button setTintColor:[self colorForHex:shortcut.color]];
    // Title under the icon, the way a mobile new-tab grid looks.
    button.configuration = nil;
    button.titleEdgeInsets = UIEdgeInsetsMake(56, 0, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(-18, 0, 0, 0);
    [button addTarget:self action:@selector(shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = shortcut.name;
    [button.heightAnchor constraintEqualToConstant:84].active = YES;
    objc_setAssociatedObject(button, "MVShortcutURL", shortcut.url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return button;
}

- (UIColor *)colorForHex:(NSString *)hex {
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return [MVTheme accent];
    unsigned int value = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
}

- (void)shortcutTapped:(UIButton *)sender {
    NSString *url = objc_getAssociatedObject(sender, "MVShortcutURL");
    if (url.length) [self.delegate homeView:self didSelectURL:url title:sender.accessibilityLabel];
}

#pragma mark - Bookmarks / history

- (UIView *)linkRowWithTitle:(NSString *)title url:(NSString *)url symbol:(NSString *)symbol {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    row.backgroundColor = [MVTheme glassCard];
    [MVTheme applyCardStyle:row cornerRadius:12];
    [row setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [row setTintColor:[MVTheme accent]];
    [row setTitle:title forState:UIControlStateNormal];
    [row setTitleColor:[MVTheme text] forState:UIControlStateNormal];
    row.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    [row.heightAnchor constraintEqualToConstant:42].active = YES;
    objc_setAssociatedObject(row, "MVLinkURL", url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(row, "MVLinkTitle", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [row addTarget:self action:@selector(linkRowTapped:) forControlEvents:UIControlEventTouchUpInside];
    return row;
}

- (void)linkRowTapped:(UIButton *)sender {
    NSString *url = objc_getAssociatedObject(sender, "MVLinkURL");
    NSString *title = objc_getAssociatedObject(sender, "MVLinkTitle");
    if (url.length) [self.delegate homeView:self didSelectURL:url title:title];
}

- (void)rebuildBookmarks {
    for (UIView *view in _bookmarkList.arrangedSubviews.copy) {
        [_bookmarkList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MVBrowserEntry *> *favorites = MVBrowserHistory.shared.favorites;
    _bookmarkEmpty.hidden = favorites.count > 0;
    for (MVBrowserEntry *entry in favorites) {
        NSString *title = entry.title.length ? entry.title : entry.url;
        [_bookmarkList addArrangedSubview:[self linkRowWithTitle:title url:entry.url symbol:@"star.fill"]];
    }
}

- (void)rebuildHistory {
    for (UIView *view in _historyList.arrangedSubviews.copy) {
        [_historyList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSString *filter = _historySearch.text.lowercaseString;
    NSMutableArray<MVBrowserEntry *> *rows = [NSMutableArray array];
    for (MVBrowserEntry *entry in MVBrowserHistory.shared.history) {
        if (entry.favorite) continue;   // already shown under Bookmarks
        if (filter.length &&
            ![entry.title.lowercaseString containsString:filter] &&
            ![entry.url.lowercaseString containsString:filter]) continue;
        [rows addObject:entry];
        if (rows.count >= 60) break;   // the page is a shortcut, not the full log
    }
    _historyEmpty.hidden = rows.count > 0;
    for (MVBrowserEntry *entry in rows) {
        NSString *title = entry.title.length ? entry.title : entry.url;
        [_historyList addArrangedSubview:[self linkRowWithTitle:title url:entry.url symbol:@"clock"]];
    }
}

- (void)historyFilterChanged { [self rebuildHistory]; }

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)clearTapped {
    if ([self.delegate respondsToSelector:@selector(homeViewDidRequestClearHistory:)]) {
        [self.delegate homeViewDidRequestClearHistory:self];
    }
}

- (NSString *)searchText { return _historySearch.text ?: @""; }
- (void)setSearchText:(NSString *)searchText { _historySearch.text = searchText; [self rebuildHistory]; }

@end
