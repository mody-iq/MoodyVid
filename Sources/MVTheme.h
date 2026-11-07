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

// Wallpapers
//
/// The gradient a screen draws behind its content. Both colours already adapt
/// to the current appearance (light/dark/system), so a screen just pairs them.
+ (UIColor *)wallpaperStart;
+ (UIColor *)wallpaperEnd;

/// The gradient colours for a *specific* wallpaper, for previews.
+ (UIColor *)wallpaperStartForName:(NSString *)name;
+ (UIColor *)wallpaperEndForName:(NSString *)name;

/// The full stop-colour array for a wallpaper (already dynamic light/dark).
+ (NSArray<UIColor *> *)wallpaperColorsForName:(NSString *)name;

/// All the wallpaper keys available to the settings picker.
+ (NSArray<NSString *> *)wallpaperNames;

/// YES for wallpapers drawn as a raster pattern (waves/neon/cosmic).
+ (BOOL)wallpaperUsesImage:(NSString *)name;

/// Renders the pattern wallpaper at the given point size.
+ (nullable UIImage *)wallpaperImageForName:(NSString *)name size:(CGSize)size;

/// Re-renders the view's wallpaper when it is an image pattern and the
/// appearance changed (image patterns cannot re-resolve dynamic colours, so the
/// screens call this from -traitCollectionDidChange:).
+ (void)refreshWallpaperIfPattern:(UIView *)view;

/// The tint used on frosted-glass surfaces.
+ (UIColor *)glassCard;

/// The currently selected wallpaper key, persisted.
+ (NSString *)wallpaperName;
+ (void)setWallpaperName:(NSString *)name;

/// Adds a wallpaper CAGradientLayer to the view's background, resized to its
/// bounds. Removes any previous wallpaper layer first, so it is safe to call
/// again when the theme or wallpaper changes.
+ (void)applyWallpaperTo:(UIView *)view;

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
