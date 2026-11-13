#import "MVNetworkPolicy.h"
#import "MVQueuePolicy.h"
#import <Network/Network.h>

NSString *const MVNetworkPolicyDidChangeNotification = @"MVNetworkPolicyDidChangeNotification";

@implementation MVNetworkPolicy {
    nw_path_monitor_t _monitor;
    BOOL _pathKnown;
    BOOL _satisfied;
    BOOL _usesWifi;
    BOOL _usesCellular;
}

+ (instancetype)shared {
    static MVNetworkPolicy *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVNetworkPolicy new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _wifiOnly = [NSUserDefaults.standardUserDefaults boolForKey:@"MVWifiOnly"];
        _monitor = nw_path_monitor_create();
        if (_monitor) {
            __weak typeof(self) weakSelf = self;
            nw_path_monitor_set_queue(_monitor, dispatch_get_main_queue());
            nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
                typeof(self) self_ = weakSelf;
                if (!self_) return;
                BOOL before = self_.allowsNewDownloads;
                self_->_pathKnown = YES;
                self_->_satisfied = nw_path_get_status(path) == nw_path_status_satisfied;
                self_->_usesWifi = nw_path_uses_interface_type(path, nw_interface_type_wifi);
                self_->_usesCellular = nw_path_uses_interface_type(path, nw_interface_type_cellular);
                if (before != self_.allowsNewDownloads) [self_ notifyChange];
            });
            nw_path_monitor_start(_monitor);
        }
        // If no monitor/path is available, the restricted queue waits instead of
        // guessing. Disabling the restriction always permits new work.
    }
    return self;
}

- (BOOL)allowsNewDownloads {
    return MVNetworkAllowsNewDownloads(_wifiOnly, _pathKnown, _satisfied,
                                       _usesWifi, _usesCellular) != 0;
}

- (void)setWifiOnly:(BOOL)wifiOnly {
    if (_wifiOnly == wifiOnly) return;
    _wifiOnly = wifiOnly;
    [NSUserDefaults.standardUserDefaults setBool:wifiOnly forKey:@"MVWifiOnly"];
    [self notifyChange];
}

- (void)notifyChange {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (NSThread.isMainThread) {
        [center postNotificationName:MVNetworkPolicyDidChangeNotification object:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [center postNotificationName:MVNetworkPolicyDidChangeNotification object:self];
        });
    }
}

@end
