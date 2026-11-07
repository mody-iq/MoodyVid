#import "MVTheme.h"

NSString *const MVThemeDidChangeNotification = @"MVThemeDidChangeNotification";

static NSString *const kThemeModeKey = @"MVThemeMode";
static NSString *const kWallpaperKey = @"MVWallpaper";

/// The stock wallpaper: the current flat backdrop, before any gradient is drawn.
static NSString *const kWallpaperClassic = @"classic";
static NSString *const kWallpaperMidnight = @"midnight";
static NSString *const kWallpaperAurora = @"aurora";
static NSString *const kWallpaperSunset = @"sunset";
static NSString *const kWallpaperForest = @"forest";

@implementation MVTheme

+ (instancetype)shared {
    static MVTheme *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [MVTheme new];
        instance->_mode = [NSUserDefaults.standardUserDefaults integerForKey:kThemeModeKey];
    });
    return instance;
}

- (void)setMode:(NSInteger)mode {
    if (_mode == mode) return;
    _mode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kThemeModeKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MVThemeDidChangeNotification object:nil];
}

- (BOOL)isDark {
    if (self.mode == MVThemeModeDark) return YES;
    if (self.mode == MVThemeModeLight) return NO;
    return UITraitCollection.currentTraitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
}

// A colour that differs between the dark and light palettes. The provider block
// is handed the traits it is being resolved for, so we must use those rather
// than the ambient collection (which is wrong on background threads).
static UIColor *MVColor(CGFloat dr, CGFloat dg, CGFloat db, CGFloat lr, CGFloat lg, CGFloat lb) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark;
        switch (MVTheme.shared.mode) {
            case MVThemeModeDark:  dark = YES; break;
            case MVThemeModeLight: dark = NO;  break;
            default: dark = traits.userInterfaceStyle != UIUserInterfaceStyleLight; break;
        }
        if (dark) return [UIColor colorWithRed:dr green:dg blue:db alpha:1.0];
        return [UIColor colorWithRed:lr green:lg blue:lb alpha:1.0];
    }];
}

// Dark palette: near-black with a navy cast and a teal accent, matching the
// design (background #0a0a0c, accent #0FA0B0).
+ (UIColor *)background   { return MVColor(0.039, 0.039, 0.047,  0.96, 0.96, 0.98); }
+ (UIColor *)card         { return MVColor(0.094, 0.094, 0.118,  1.00, 1.00, 1.00); }
+ (UIColor *)cardBorder   { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)separator    { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)text         { return MVColor(0.96, 0.97, 0.98,  0.07, 0.07, 0.10); }
+ (UIColor *)secondaryText{ return MVColor(0.58, 0.62, 0.66,  0.42, 0.42, 0.48); }
+ (UIColor *)accent       { return MVColor(0.06, 0.63, 0.69,  0.02, 0.48, 0.55); }
+ (UIColor *)accentSoft   { return MVColor(0.06, 0.63, 0.69,  0.02, 0.48, 0.55); }
+ (UIColor *)success      { return MVColor(0.20, 0.83, 0.60,  0.10, 0.65, 0.45); }
+ (UIColor *)warning      { return MVColor(1.00, 0.70, 0.20,  0.85, 0.55, 0.05); }
+ (UIColor *)danger       { return MVColor(1.00, 0.35, 0.42,  0.85, 0.20, 0.28); }

#pragma mark - Wallpapers

// As with MVColor, each entry carries dark and light RGB values; the dynamic
// provider picks per wallpaper + current appearance. "Start" is the top of the
// gradient, "end" the bottom, tuned to keep the design's text readable.
static NSDictionary<NSString *, NSArray *> *MVWallpaperTable(void) {
    return @{
        kWallpaperClassic:  @[@[@0.039, @0.039, @0.047], @[@0.039, @0.039, @0.047],
                              @[@0.96,  @0.96,  @0.98],  @[@0.96,  @0.96,  @0.98]],
        kWallpaperMidnight: @[@[@0.02,  @0.05,  @0.09], @[@0.02,  @0.14,  @0.20],
                              @[@0.90,  @0.93,  @0.99], @[@0.72,  @0.85,  @0.96]],
        kWallpaperAurora:   @[@[@0.03,  @0.07,  @0.10], @[@0.10,  @0.22,  @0.34],
                              @[@0.92,  @0.95,  @0.99], @[@0.78,  @0.90,  @0.97]],
        kWallpaperSunset:   @[@[@0.09,  @0.04,  @0.12], @[@0.32,  @0.10,  @0.20],
                              @[@0.99,  @0.94,  @0.93], @[@0.96,  @0.82,  @0.86]],
        kWallpaperForest:   @[@[@0.02,  @0.06,  @0.04], @[@0.06,  @0.18,  @0.12],
                              @[@0.93,  @0.97,  @0.94], @[@0.77,  @0.90,  @0.82]],
    };
}

+ (NSArray<NSString *> *)wallpaperNames {
    return @[kWallpaperClassic, kWallpaperMidnight, kWallpaperAurora, kWallpaperSunset, kWallpaperForest];
}

+ (NSString *)wallpaperName {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kWallpaperKey];
    if ([MVTheme.wallpaperNames containsObject:saved]) return saved;
    return kWallpaperClassic;
}

+ (void)setWallpaperName:(NSString *)name {
    if (!name.length || ![MVTheme.wallpaperNames containsObject:name]) return;
    [NSUserDefaults.standardUserDefaults setObject:name forKey:kWallpaperKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MVThemeDidChangeNotification object:nil];
}

// Each wallpaper entry is start/end pairs for dark and light:
// [darkStart, darkEnd, lightStart, lightEnd], each an RGB triple. idx 0 picks
// the top colour, idx 1 the bottom. Returns a dynamic colour.
static UIColor *MVWallpaperColor(NSString *kind, NSInteger idx) {
    NSArray *entry = MVWallpaperTable()[kind];
    if (entry.count < 4) return UIColor.clearColor;
    NSArray *dark = entry[idx], *light = entry[idx + 2];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL darkMode;
        switch (MVTheme.shared.mode) {
            case MVThemeModeDark:  darkMode = YES; break;
            case MVThemeModeLight: darkMode = NO;  break;
            default: darkMode = traits.userInterfaceStyle != UIUserInterfaceStyleLight; break;
        }
        NSArray *c = darkMode ? dark : light;
        return [UIColor colorWithRed:[c[0] doubleValue] green:[c[1] doubleValue] blue:[c[2] doubleValue] alpha:1.0];
    }];
}

+ (UIColor *)wallpaperStart { return MVWallpaperColor(MVTheme.wallpaperName, 0); }
+ (UIColor *)wallpaperEnd   { return MVWallpaperColor(MVTheme.wallpaperName, 1); }

+ (UIColor *)wallpaperStartForName:(NSString *)name {
    return [MVTheme.wallpaperNames containsObject:name] ? MVWallpaperColor(name, 0) : UIColor.clearColor;
}
+ (UIColor *)wallpaperEndForName:(NSString *)name {
    return [MVTheme.wallpaperNames containsObject:name] ? MVWallpaperColor(name, 1) : UIColor.clearColor;
}

+ (void)applyWallpaperTo:(UIView *)view {
    if (!view) return;
    for (CALayer *layer in [view.layer.sublayers copy]) {
        if ([layer isKindOfClass:CAGradientLayer.class]) {
            // Assumes the gradient is the wallpaper; remove any previous one.
            if (layer.name != nil && [layer.name isEqualToString:@"MVWallpaperLayer"]) {
                [layer removeFromSuperlayer];
            }
        }
    }
    if ([MVTheme.wallpaperName isEqualToString:kWallpaperClassic]) {
        view.backgroundColor = [MVTheme background];
        return;
    }
    CAGradientLayer *g = [CAGradientLayer layer];
    g.name = @"MVWallpaperLayer";
    g.frame = view.bounds;
    g.colors = @[(id)MVTheme.wallpaperStart.CGColor, (id)MVTheme.wallpaperEnd.CGColor];
    g.startPoint = CGPointMake(0.5, 0);
    g.endPoint = CGPointMake(0.5, 1);
    [view.layer insertSublayer:g atIndex:0];
    view.backgroundColor = UIColor.clearColor;
}

+ (void)applyCardStyle:(UIView *)view {
    [self applyCardStyle:view cornerRadius:18.0];
}

+ (void)applyCardStyle:(UIView *)view cornerRadius:(CGFloat)radius {
    view.backgroundColor = [self card];
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0;
    // A faint white border is what gives the translucent "glass" edge on dark.
    view.layer.borderColor = [[self cardBorder] colorWithAlphaComponent:MVTheme.shared.isDark ? 0.10 : 0.06].CGColor;
}

+ (void)applyPrimaryButtonStyle:(UIButton *)button {
    button.backgroundColor = [self accent];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.6] forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
}

@end
