#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when the setting or the observed default path changes.
extern NSString *const MVNetworkPolicyDidChangeNotification;

/// Shared admission and policy-change notification for download queues. Native
/// sessions additionally disallow cellular; Python can only stop cooperatively.
@interface MVNetworkPolicy : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL wifiOnly;
@property (nonatomic, readonly) BOOL allowsNewDownloads;
/// Index of the currently observed Wi-Fi interface, or zero if unknown. Read on
/// the main queue; torrent peers bind to it when Wi-Fi-only is enabled.
@property (nonatomic, readonly) unsigned int wifiInterfaceIndex;
@end

NS_ASSUME_NONNULL_END
