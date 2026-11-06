#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the appearance changes, so open screens can re-apply colours.
extern NSString *const MVThemeDidChangeNotification;

/// The app's colours and shared looks.
///
/// The design is a dark "glassmorphism" look: an OLED-black background with
/// glowing accent colours and translucent cards. Every colour lives here so a
/// screen never hard-codes one and the light theme stays consistent.
@interface MVTheme : NSObject

+ (instancetype)shared;

/// MVThemeModeSystem, MVThemeModeDark or MVThemeModeLight. Persisted.
@property (nonatomic) NSInteger mode;

/// YES when the dark palette is in use right now (mode is dark, or system is dark).
@property (nonatomic, readonly) BOOL isDark;

// Surfaces
+ (UIColor *)background;
+ (UIColor *)card;
+ (UIColor *)cardBorder;
+ (UIColor *)separator;

// Text
+ (UIColor *)text;
+ (UIColor *)secondaryText;

// Accents
+ (UIColor *)accent;
+ (UIColor *)accentSoft;
+ (UIColor *)success;
+ (UIColor *)warning;
+ (UIColor *)danger;

/// A rounded, translucent card with a hairline border, as used across the design.
+ (void)applyCardStyle:(UIView *)view;
+ (void)applyCardStyle:(UIView *)view cornerRadius:(CGFloat)radius;

/// A pill-shaped filled button in the accent colour.
+ (void)applyPrimaryButtonStyle:(UIButton *)button;

@end

typedef NS_ENUM(NSInteger, MVThemeMode) {
    MVThemeModeSystem = 0,
    MVThemeModeDark = 1,
    MVThemeModeLight = 2,
};

NS_ASSUME_NONNULL_END
