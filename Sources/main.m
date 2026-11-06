#import <UIKit/UIKit.h>
#import "MVPython.h"
#import "MVDownloaderViewController.h"

@interface MVRootViewController : UIViewController
@end

@implementation MVRootViewController

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[MVPython shared] start];
    MVDownloaderViewController *dl = [[MVDownloaderViewController alloc] init];
    dl.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:dl animated:NO completion:nil];
}

@end

@interface MVAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    MVRootViewController *root = [[MVRootViewController alloc] init];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MVAppDelegate class]));
    }
}
