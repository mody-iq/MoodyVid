// Foundation-only native tests have no Network.framework path monitor.
#import <Foundation/Foundation.h>
@interface MVNetworkPolicy : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL wifiOnly;
@property (nonatomic) unsigned int wifiInterfaceIndex;
@end
@implementation MVNetworkPolicy
+ (instancetype)shared { static MVNetworkPolicy *p; static dispatch_once_t once; dispatch_once(&once, ^{ p = [self new]; }); return p; }
@end
