#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A small, self-contained content blocker for the in-app browser.
///
/// It ships a hand-written rule list (no downloaded filter lists, no third-party
/// data) that blocks the common ad and popup hosts plus the usual tracking
/// endpoints, and hides the empty boxes they leave behind. `WKContentRuleList`
/// is compiled once and cached by WebKit. WebKit rejects an entire list when any
/// single rule fails, so if the whole list is refused the blocker recompiles
/// each rule on its own and keeps only the ones WebKit accepts. A compile
/// failure therefore degrades blocking instead of disabling it.
@interface MVAdBlocker : NSObject

+ (instancetype)shared;

/// YES when blocking is on. Persisted.
@property (nonatomic) BOOL enabled;

/// The compiled rule list, or nil when disabled or not yet compiled.
/// `completion` runs on the main queue.
- (void)ruleListWithCompletion:(void (^_Nullable)(WKContentRuleList *_Nullable ruleList))completion;

/// Compiles the list now. Safe to call repeatedly; only the first call compiles.
- (void)prepare;

/// Installs the blocker into a web view's configuration, if enabled.
- (void)applyToConfiguration:(WKWebViewConfiguration *)configuration;

/// The rule list as JSON text (exposed for tests and for the settings preview).
+ (NSString *)rulesJSON;

@end

NS_ASSUME_NONNULL_END
