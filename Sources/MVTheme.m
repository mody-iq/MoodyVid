#import "MVTheme.h"

NSString *const MVThemeDidChangeNotification = @"MVThemeDidChangeNotification";

static NSString *const kThemeModeKey = @"MVThemeMode";
static NSString *const kWallpaperKey = @"MVWallpaper";

static NSString *const kWallpaperClassic  = @"classic";
static NSString *const kWallpaperMidnight = @"midnight";
static NSString *const kWallpaperAurora   = @"aurora";
static NSString *const kWallpaperSunset   = @"sunset";
static NSString *const kWallpaperOcean    = @"ocean";
static NSString *const kWallpaperForest   = @"forest";
static NSString *const kWallpaperGraphite = @"graphite";
static NSString *const kWallpaperNeon     = @"neon";
static NSString *const kWallpaperCosmic   = @"cosmic";
static NSString *const kWallpaperWaves    = @"waves";

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

// The palette follows the iOS system colours, so the app sits naturally beside
// Apple's own apps and adapts with the appearance for free.
+ (UIColor *)background   { return MVColor(0.00, 0.00, 0.00,  0.95, 0.95, 0.97); }
+ (UIColor *)card         { return MVColor(0.11, 0.11, 0.12,  1.00, 1.00, 1.00); }
+ (UIColor *)cardBorder   { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)separator    { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)text         { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)secondaryText{ return MVColor(0.56, 0.56, 0.58,  0.42, 0.42, 0.44); }
+ (UIColor *)accent       { return MVColor(0.04, 0.52, 1.00,  0.00, 0.48, 1.00); }
+ (UIColor *)accentSoft   { return MVColor(0.39, 0.82, 1.00,  0.20, 0.68, 0.90); }
+ (UIColor *)success      { return MVColor(0.19, 0.82, 0.35,  0.20, 0.78, 0.35); }
+ (UIColor *)warning      { return MVColor(1.00, 0.62, 0.04,  1.00, 0.58, 0.00); }
+ (UIColor *)danger       { return MVColor(1.00, 0.27, 0.23,  1.00, 0.23, 0.19); }

#pragma mark - Wallpapers

// Each wallpaper lists any number of colour stops; each stop carries a dark and
// a light RGB triple so the wallpaper adapts to the appearance.
static NSArray<NSArray<NSArray *> *> *MVStops(NSString *name) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            kWallpaperClassic:  @[@[@[@0.039,@0.039,@0.047], @[@0.96,@0.96,@0.98]]],
            kWallpaperMidnight: @[@[@[@0.012,@0.043,@0.078], @[@0.92,@0.95,@0.99]],
                                  @[@[@0.020,@0.133,@0.173], @[@0.83,@0.91,@0.96]],
                                  @[@[@0.039,@0.227,@0.290], @[@0.76,@0.86,@0.94]]],
            kWallpaperAurora:   @[@[@[@0.008,@0.070,@0.043], @[@0.90,@0.97,@0.95]],
                                  @[@[@0.027,@0.188,@0.145], @[@0.82,@0.94,@0.89]],
                                  @[@[@0.055,@0.227,@0.235], @[@0.81,@0.91,@0.93]],
                                  @[@[@0.106,@0.169,@0.333], @[@0.89,@0.88,@0.96]]],
            kWallpaperSunset:   @[@[@[@0.086,@0.027,@0.067], @[@0.99,@0.92,@0.91]],
                                  @[@[@0.227,@0.051,@0.141], @[@0.98,@0.84,@0.86]],
                                  @[@[@0.420,@0.086,@0.188], @[@0.96,@0.72,@0.78]],
                                  @[@[@0.576,@0.188,@0.114], @[@0.94,@0.65,@0.56]]],
            kWallpaperOcean:    @[@[@[@0.008,@0.071,@0.149], @[@0.89,@0.95,@0.99]],
                                  @[@[@0.024,@0.212,@0.388], @[@0.76,@0.89,@0.97]],
                                  @[@[@0.051,@0.416,@0.549], @[@0.62,@0.83,@0.94]]],
            kWallpaperForest:   @[@[@[@0.012,@0.094,@0.047], @[@0.92,@0.97,@0.93]],
                                  @[@[@0.047,@0.184,@0.086], @[@0.84,@0.94,@0.88]],
                                  @[@[@0.086,@0.333,@0.169], @[@0.74,@0.89,@0.80]]],
            kWallpaperGraphite: @[@[@[@0.063,@0.071,@0.086], @[@0.95,@0.96,@0.97]],
                                  @[@[@0.106,@0.129,@0.157], @[@0.89,@0.91,@0.93]],
                                  @[@[@0.165,@0.200,@0.239], @[@0.79,@0.82,@0.86]]],
            kWallpaperNeon:     @[@[@[@0.039,@0.024,@0.078], @[@0.97,@0.95,@1.00]],
                                  @[@[@0.090,@0.051,@0.200], @[@0.91,@0.86,@0.99]],
                                  @[@[@0.055,@0.165,@0.235], @[@0.84,@0.92,@0.98]]],
            kWallpaperCosmic:   @[@[@[@0.027,@0.027,@0.059], @[@0.96,@0.96,@0.99]],
                                  @[@[@0.078,@0.063,@0.196], @[@0.88,@0.88,@0.95]],
                                  @[@[@0.169,@0.118,@0.302], @[@0.76,@0.79,@0.90]]],
            kWallpaperWaves:    @[@[@[@0.039,@0.075,@0.133], @[@0.95,@0.97,@0.99]],
                                  @[@[@0.071,@0.235,@0.322], @[@0.85,@0.92,@0.97]],
                                  @[@[@0.059,@0.369,@0.455], @[@0.75,@0.88,@0.95]]],
        };
    });
    NSArray *stops = table[name];
    return stops ?: table[kWallpaperClassic];
}

+ (NSArray<NSString *> *)wallpaperNames {
    return @[kWallpaperClassic, kWallpaperMidnight, kWallpaperAurora,
             kWallpaperSunset, kWallpaperOcean, kWallpaperForest, kWallpaperGraphite,
             kWallpaperNeon, kWallpaperCosmic, kWallpaperWaves];
}

// Wallpapers rendered as an image (glow blobs / stars / waves) instead of a
// plain smooth gradient.
+ (BOOL)wallpaperUsesImage:(NSString *)name {
    return [name isEqualToString:kWallpaperNeon]
        || [name isEqualToString:kWallpaperCosmic]
        || [name isEqualToString:kWallpaperWaves];
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

// Whether the given traits resolve to the dark palette (honours the manual mode).
+ (BOOL)resolveDarkForTraits:(UITraitCollection *)traits {
    switch (MVTheme.shared.mode) {
        case MVThemeModeDark:  return YES;
        case MVThemeModeLight: return NO;
        default: return traits.userInterfaceStyle != UIUserInterfaceStyleLight;
    }
}

// A dynamic colour for one wallpaper stop.
static UIColor *MVStopColor(NSString *name, NSInteger idx) {
    NSArray *stops = MVStops(name);
    if (idx >= (NSInteger)stops.count) idx = stops.count - 1;
    if (idx < 0) idx = 0;
    NSArray *dark = stops[idx][0], *light = stops[idx][1];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        NSArray *c = [MVTheme resolveDarkForTraits:traits] ? dark : light;
        return [UIColor colorWithRed:[c[0] doubleValue] green:[c[1] doubleValue]
                                blue:[c[2] doubleValue] alpha:1.0];
    }];
}

+ (NSArray<UIColor *> *)wallpaperColorsForName:(NSString *)name {
    if (![MVTheme.wallpaperNames containsObject:name]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < MVStops(name).count; i++) {
        [out addObject:MVStopColor(name, (NSInteger)i)];
    }
    return out;
}

// The literal RGB triple for a wallpaper stop in a given appearance.
static NSArray *MVRGB(NSString *name, NSInteger idx, BOOL dark) {
    NSArray *stops = MVStops(name);
    if (idx >= (NSInteger)stops.count) idx = stops.count - 1;
    return stops[idx][dark ? 0 : 1];
}

+ (UIColor *)wallpaperStart { return MVStopColor(MVTheme.wallpaperName, 0); }
+ (UIColor *)wallpaperEnd {
    NSArray *colors = [self wallpaperColorsForName:MVTheme.wallpaperName];
    return colors.lastObject ?: UIColor.clearColor;
}
+ (UIColor *)wallpaperStartForName:(NSString *)name { return MVStopColor(name, 0); }
+ (UIColor *)wallpaperEndForName:(NSString *)name {
    NSArray *colors = [self wallpaperColorsForName:name];
    return colors.lastObject ?: UIColor.clearColor;
}

#pragma mark - Wallpaper images (pattern wallpapers)

// Rasterises the base gradient plus the pattern overlay. `dark` picks the palette.
static UIImage *MVWallpaperImage(NSString *name, CGSize size, BOOL dark) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // 1. Vertical colour gradient.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    size_t count = MVStops(name).count;
    CGFloat locs[8] = {0};
    CGFloat comps[8 * 4] = {0};
    for (NSUInteger i = 0; i < count && i < 8; i++) {
        NSArray *rgb = MVRGB(name, (NSInteger)i, dark);
        locs[i] = (CGFloat)i / (CGFloat)(count - 1);
        comps[i * 4 + 0] = [rgb[0] doubleValue];
        comps[i * 4 + 1] = [rgb[1] doubleValue];
        comps[i * 4 + 2] = [rgb[2] doubleValue];
        comps[i * 4 + 3] = 1.0;
    }
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, (size_t)count);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
    CGGradientRelease(grad);

    // 2. Pattern overlays.
    if ([name isEqualToString:kWallpaperWaves]) {
        UIColor *line = dark ? [UIColor colorWithWhite:1.0 alpha:0.14]
                             : [UIColor colorWithRed:0.03 green:0.27 blue:0.45 alpha:0.14];
        CGContextSetLineWidth(ctx, 2.0);
        CGFloat periods[3] = {3.5, 5.0, 7.0};
        CGFloat bases[3] = {size.height * 0.78, size.height * 0.89, size.height * 0.97};
        CGFloat amps[3] = {size.height * 0.055, size.height * 0.045, size.height * 0.035};
        for (int i = 0; i < 3; i++) {
            [[line colorWithAlphaComponent:0.28 - i * 0.07] setStroke];
            CGContextBeginPath(ctx);
            for (int x = 0; x <= 140; x++) {
                CGFloat px = (CGFloat)x / 140.0 * size.width;
                CGFloat py = bases[i] + amps[i] * sin((px / size.width) * periods[i] * 2.0 * M_PI);
                if (x == 0) CGContextMoveToPoint(ctx, px, py);
                else CGContextAddLineToPoint(ctx, px, py);
            }
            CGContextStrokePath(ctx);
        }
    } else if ([name isEqualToString:kWallpaperNeon]) {
        NSArray *blobs = @[
            @[@0.20f, @0.28f, @0.45f, @0.55f, @0.35f, @0.90f],
            @[@0.82f, @0.22f, @0.40f, @0.95f, @0.30f, @0.55f],
            @[@0.50f, @0.88f, @0.50f, @1.00f, @0.40f, @0.20f],
        ];
        for (NSArray *b in blobs) {
            CGFloat cx = [b[0] floatValue] * size.width;
            CGFloat cy = [b[1] floatValue] * size.height;
            CGFloat r  = [b[2] floatValue] * size.width;
            CGFloat comps2[8] = {[b[3] floatValue], [b[4] floatValue], [b[5] floatValue], 0.50, 0, 0, 0, 0};
            CGFloat locs2[2] = {0, 1};
            CGGradientRef g = CGGradientCreateWithColorComponents(space, comps2, locs2, 2);
            CGContextDrawRadialGradient(ctx, g, CGPointMake(cx, cy), 0, CGPointMake(cx, cy), r, kCGGradientDrawsAfterEndLocation);
            CGGradientRelease(g);
        }
    } else if ([name isEqualToString:kWallpaperCosmic]) {
        UIColor *star = dark ? [UIColor colorWithWhite:1.0 alpha:0.50]
                             : [UIColor colorWithRed:0.12 green:0.08 blue:0.38 alpha:0.33];
        unsigned seed = 42;
        for (int i = 0; i < 90; i++) {
            CGFloat x = (CGFloat)(rand_r(&seed) % 1000) / 1000.0 * size.width;
            CGFloat y = (CGFloat)(rand_r(&seed) % 1000) / 1000.0 * size.height;
            CGFloat d = 0.7 + (CGFloat)(rand_r(&seed) % 45) / 100.0;
            CGFloat alpha = 0.25 + (CGFloat)(rand_r(&seed) % 60) / 100.0;
            [[star colorWithAlphaComponent:alpha] setFill];
            CGContextFillEllipseInRect(ctx, CGRectMake(x, y, d, d));
        }
        CGFloat comps2[8] = {0.52, 0.24, 0.85, 0.30, 0, 0, 0, 0};
        CGFloat locs2[2] = {0, 1};
        CGGradientRef g = CGGradientCreateWithColorComponents(space, comps2, locs2, 2);
        CGContextDrawRadialGradient(ctx, g,
                                    CGPointMake(size.width * 0.75, size.height * 0.12), 0,
                                    CGPointMake(size.width * 0.75, size.height * 0.12),
                                    size.width * 0.55, kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(g);
    }
    CGColorSpaceRelease(space);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

+ (UIImage *)wallpaperImageForName:(NSString *)name size:(CGSize)size {
    if (size.width <= 1 || size.height <= 1 || ![self wallpaperUsesImage:name]) return nil;
    BOOL dark = [self resolveDarkForTraits:UITraitCollection.currentTraitCollection];
    // Rendering the pattern is a full CoreGraphics pass, and every tab hands the
    // wallpaper back on -viewWillAppear. Cache by name/size/appearance so a tab
    // switch reuses the bitmap instead of re-drawing it on the main thread.
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@-%.0fx%.0f-%d", name, size.width, size.height, dark];
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;
    UIImage *image = MVWallpaperImage(name, size, dark);
    if (image) [cache setObject:image forKey:key];
    return image;
}

+ (void)refreshWallpaperIfPattern:(UIView *)view {
    // Re-applies unconditionally: raster patterns need a fresh render, and
    // gradient wallpapers must be re-resolved to the new appearance's colours.
    if (view) [self applyWallpaperTo:view];
}

#pragma mark - Applying

+ (void)applyWallpaperTo:(UIView *)view {
    if (!view) return;
    for (CALayer *layer in [view.layer.sublayers copy]) {
        if ([layer.name isEqualToString:@"MVWallpaperLayer"]) {
            [layer removeFromSuperlayer];
        }
    }
    NSString *name = MVTheme.wallpaperName;
    if ([name isEqualToString:kWallpaperClassic]) {
        view.backgroundColor = [MVTheme background];
        return;
    }

    view.backgroundColor = UIColor.clearColor;
    CALayer *layer = nil;
    if ([self wallpaperUsesImage:name]) {
        UIImage *img = [self wallpaperImageForName:name size:view.bounds.size];
        if (img) {
            layer = [CALayer layer];
            layer.contents = (id)img.CGImage;
            layer.contentsGravity = kCAGravityResizeAspectFill;
        }
    } else {
        CAGradientLayer *g = [CAGradientLayer layer];
        // CAGradientLayer.colors only accepts CGColorRefs, so resolve the dynamic
        // stops against the current appearance here and re-apply from
        // -traitCollectionDidChange: when the appearance switches.
        NSArray<UIColor *> *colors = [self wallpaperColorsForName:name];
        NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
        for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
        g.colors = cg;
        if (colors.count > 1) {
            NSMutableArray *loc = [NSMutableArray arrayWithCapacity:colors.count];
            for (NSUInteger i = 0; i < colors.count; i++) {
                [loc addObject:@((CGFloat)i / (CGFloat)(colors.count - 1))];
            }
            g.locations = loc;
        }
        g.startPoint = CGPointMake(0.5, 0);
        g.endPoint = CGPointMake(0.5, 1);
        layer = g;
    }
    if (layer) {
        layer.name = @"MVWallpaperLayer";
        layer.frame = view.bounds;
        [view.layer insertSublayer:layer atIndex:0];
    }
}

#pragma mark - Cards / controls

+ (UIColor *)glassCard {
    return [self card];
}

+ (void)applyCardStyle:(UIView *)view {
    [self applyCardStyle:view cornerRadius:18.0];
}

+ (void)applyCardStyle:(UIView *)view cornerRadius:(CGFloat)radius {
    view.backgroundColor = [self glassCard];
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    // No border, no shadow, no blur: a card is a flat fill. This is what lets a
    // long list scroll without a compositing pass per row.
}

+ (void)applyPrimaryButtonStyle:(UIButton *)button {
    button.backgroundColor = [self accent];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.6] forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
}

#pragma mark - Layout tokens

+ (CGFloat)cardCornerRadius { return 16.0; }
+ (CGFloat)cardSpacing { return 12.0; }
+ (CGFloat)screenPadding { return 16.0; }
+ (CGFloat)minTouchTarget { return 44.0; }

#pragma mark - Fonts

+ (UIFont *)cardTitleFont { return [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; }
+ (UIFont *)cardDetailFont { return [UIFont systemFontOfSize:12 weight:UIFontWeightRegular]; }
+ (UIFont *)sectionHeaderFont { return [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; }
+ (UIFont *)chipFont { return [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; }

+ (void)applyIconTileStyle:(UIView *)view tint:(UIColor *)tint {
    if (!view) return;
    view.backgroundColor = [tint colorWithAlphaComponent:0.16];
    view.layer.cornerRadius = 10.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

@end