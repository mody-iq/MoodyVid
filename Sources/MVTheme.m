#import "MVTheme.h"

NSString *const MVThemeDidChangeNotification = @"MVThemeDidChangeNotification";

static NSString *const kThemeModeKey = @"MVThemeMode";

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

// Dark palette: near-black (OLED friendly) with a violet accent.
+ (UIColor *)background   { return MVColor(0.04, 0.04, 0.06,  0.96, 0.96, 0.98); }
+ (UIColor *)card         { return MVColor(0.11, 0.11, 0.15,  1.00, 1.00, 1.00); }
+ (UIColor *)cardBorder   { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)separator    { return MVColor(1.00, 1.00, 1.00,  0.00, 0.00, 0.00); }
+ (UIColor *)text         { return MVColor(0.97, 0.97, 1.00,  0.07, 0.07, 0.10); }
+ (UIColor *)secondaryText{ return MVColor(0.62, 0.62, 0.70,  0.42, 0.42, 0.48); }
+ (UIColor *)accent       { return MVColor(0.55, 0.36, 1.00,  0.42, 0.22, 0.92); }
+ (UIColor *)accentSoft   { return MVColor(0.55, 0.36, 1.00,  0.42, 0.22, 0.92); }
+ (UIColor *)success      { return MVColor(0.20, 0.83, 0.60,  0.10, 0.65, 0.45); }
+ (UIColor *)warning      { return MVColor(1.00, 0.70, 0.20,  0.85, 0.55, 0.05); }
+ (UIColor *)danger       { return MVColor(1.00, 0.35, 0.42,  0.85, 0.20, 0.28); }

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
