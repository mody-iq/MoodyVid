#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The "filter by type" bottom sheet: one row per file type with its SF Symbol
/// and how many downloads are of that type.
///
/// The counts come from the caller, so the sheet holds no state of its own and
/// the Downloads screen stays the single owner of the data.
@interface MVTypeFilterSheet : UIViewController

/// `types` is a list of `@[displayName, symbolName, count, category]`. The first
/// entry is the "All" row; `category` is nil for it.
- (instancetype)initWithTypes:(NSArray<NSArray *> *)types selected:(NSString *)category;

/// Called with the chosen category, or an empty string for the "All" row.
@property (nonatomic, copy, nullable) void (^onSelect)(NSString *category);

@end

NS_ASSUME_NONNULL_END
