#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the language changes, so open screens can re-read their text.
extern NSString *const MVLangDidChangeNotification;

/// Bilingual strings (Arabic and English) with a runtime switch.
///
/// Strings live in a table in this file rather than in .lproj bundles: the build
/// only copies Info.plist out of Resources, and a table keeps the switch instant
/// (no restart, no bundle reload) and the Arabic and English wording side by side.
@interface MVLang : NSObject

+ (instancetype)shared;

/// "ar" or "en". Persisted in NSUserDefaults; defaults to Arabic.
@property (nonatomic, copy) NSString *code;

/// YES when Arabic is active. Callers use it to set text alignment.
@property (nonatomic, readonly) BOOL isRTL;

/// The translation for `key`, or the key itself when it is missing (so a missing
/// string is visible rather than blank).
+ (NSString *)t:(NSString *)key;

/// Same, with `%@`-style placeholders filled from `args`.
+ (NSString *)t:(NSString *)key args:(NSArray *)args;

@end

NS_ASSUME_NONNULL_END
