#import <UIKit/UIKit.h>
#import "MVTabBarController.h"
#import "MVTheme.h"
#import "MVLang.h"
#import "MVPython.h"

@interface MVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[MVTabBarController alloc] init];
    [self.window makeKeyAndVisible];

    // Warm the interpreter up in the background so the first download does not
    // pay for the whole start-up, and so Settings can show the engine version.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[MVPython shared] start];
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MVAppDelegate class]));
    }
}
