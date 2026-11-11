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
@property (nonatomic, strong) UIStackView *historyList;
@property (nonatomic, strong) UILabel *historyEmpty;
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
        _stack.spacing = 22;
        [_scroll addSubview:_stack];

        // Pinned to the content guide, not the frame: the page must be able to
        // scroll, and a stack of fixed-width tiles must not fight a frame pin.
        UILayoutGuide *content = _scroll.contentLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
            [_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-28],
            [_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
            [_stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
            [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-36],
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

- (UILabel *)emptyLabel:(NSString *)key {
    UILabel *label = [UILabel new];
    label.text = [MVLang t:key];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [MVTheme secondaryText];
    label.numberOfLines = 0;
    return label;
}

- (void)buildSections {
    // Shortcuts: the row of site tiles, the page's one loud element.
    [_stack addArrangedSubview:[self sectionTitle:@"Shortcuts"]];
    _shortcutGrid = [UIStackView new];
    _shortcutGrid.axis = UILayoutConstraintAxisVertical;
    _shortcutGrid.spacing = 10;
    [_stack addArrangedSubview:_shortcutGrid];

    // One list, not three: bookmarked pages are the rows that carry a star, so
    // history and bookmarks share the same section and the search field filters
    // both. Three stacked sections made the page long and repetitive.
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
    _historyList.spacing = 6;
    [_stack addArrangedSubview:_historyList];

    _historyEmpty = [self emptyLabel:@"No history yet"];
    [_stack addArrangedSubview:_historyEmpty];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:[MVLang t:@"Clear history"] forState:UIControlStateNormal];
    [clear setTitleColor:[MVTheme danger] forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    clear.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [clear addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    [_stack addArrangedSubview:clear];
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

/// A shortcut tile: the brand glyph over the site name. The brand colour is kept
/// on the glyph only — a wall of saturated tiles was the loudest thing on the
/// page — and the tile itself stays a quiet card. Built as a stack rather than a
/// button so the icon-above-title layout does not depend on inset arithmetic.
- (UIView *)tileForShortcut:(MVBrowserShortcut *)shortcut {
    UIView *tile = [UIView new];
    [MVTheme applyCardStyle:tile cornerRadius:16];
    tile.isAccessibilityElement = YES;
    tile.accessibilityLabel = shortcut.name;
    tile.accessibilityTraits = UIAccessibilityTraitButton;

    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.image = [UIImage systemImageNamed:shortcut.symbol];
    icon.tintColor = [self colorForHex:shortcut.color];
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *label = [UILabel new];
    label.text = shortcut.name;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [MVTheme text];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;

    UIStackView *column = [UIStackView new];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.alignment = UIStackViewAlignmentCenter;
    column.spacing = 8;
    [column addArrangedSubview:icon];
    [column addArrangedSubview:label];
    [tile addSubview:column];

    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintEqualToConstant:84],
        [icon.widthAnchor constraintEqualToConstant:26],
        [icon.heightAnchor constraintEqualToConstant:26],
        [column.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [column.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        [column.leadingAnchor constraintGreaterThanOrEqualToAnchor:tile.leadingAnchor constant:6],
        [column.trailingAnchor constraintLessThanOrEqualToAnchor:tile.trailingAnchor constant:-6],
    ]];

    objc_setAssociatedObject(tile, "MVShortcutURL", shortcut.url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [tile addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(shortcutTapped:)]];
    return tile;
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

- (void)shortcutTapped:(UITapGestureRecognizer *)gesture {
    NSString *url = objc_getAssociatedObject(gesture.view, "MVShortcutURL");
    NSString *title = gesture.view.accessibilityLabel;
    if (url.length) [self.delegate homeView:self didSelectURL:url title:title];
}

#pragma mark - History

/// One history line: a glyph that is a star for a bookmarked page and a clock
/// otherwise, then the title. Bookmarks are just the starred rows, so the page
/// has one list instead of three.
- (UIView *)linkRowWithTitle:(NSString *)title url:(NSString *)url favorite:(BOOL)favorite {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    [MVTheme applyCardStyle:row cornerRadius:12];
    [row setImage:[UIImage systemImageNamed:(favorite ? @"star.fill" : @"clock")] forState:UIControlStateNormal];
    [row setTintColor:favorite ? [MVTheme warning] : [MVTheme secondaryText]];
    [row setTitle:title forState:UIControlStateNormal];
    [row setTitleColor:[MVTheme text] forState:UIControlStateNormal];
    row.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
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

- (void)rebuildHistory {
    for (UIView *view in _historyList.arrangedSubviews.copy) {
        [_historyList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSArray<MVBrowserEntry *> *favorites = MVBrowserHistory.shared.favorites;
    NSMutableSet<NSString *> *favoriteURLs = [NSMutableSet set];
    for (MVBrowserEntry *entry in favorites) [favoriteURLs addObject:entry.url];

    NSString *filter = _historySearch.text.lowercaseString;
    NSMutableArray<MVBrowserEntry *> *rows = [NSMutableArray array];
    // Bookmarked pages lead the list, then the rest of the history.
    for (MVBrowserEntry *entry in favorites) {
        if (filter.length &&
            ![entry.title.lowercaseString containsString:filter] &&
            ![entry.url.lowercaseString containsString:filter]) continue;
        [rows addObject:entry];
    }
    for (MVBrowserEntry *entry in MVBrowserHistory.shared.history) {
        if ([favoriteURLs containsObject:entry.url]) continue;   // already listed
        if (filter.length &&
            ![entry.title.lowercaseString containsString:filter] &&
            ![entry.url.lowercaseString containsString:filter]) continue;
        [rows addObject:entry];
        if (rows.count >= 60) break;   // the page is a shortcut, not the full log
    }
    _historyEmpty.hidden = rows.count > 0;
    for (MVBrowserEntry *entry in rows) {
        NSString *title = entry.title.length ? entry.title : entry.url;
        BOOL favorite = [favoriteURLs containsObject:entry.url];
        [_historyList addArrangedSubview:[self linkRowWithTitle:title url:entry.url favorite:favorite]];
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
