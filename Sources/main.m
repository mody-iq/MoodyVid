#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "MVTabBarController.h"
#import "MVTheme.h"
#import "MVLang.h"
#import "MVPython.h"
#import "MVDownloadEngine.h"
#import "MVDownloadManager.h"
#import "MVPlayerCenter.h"
#import "MVLog.h"

@interface MVAppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    MVLogInfo(@"app: launch v%@ build %@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]);

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[MVTabBarController alloc] init];
    [self.window makeKeyAndVisible];

    // Warm the interpreter up in the background so the first download does not
    // pay for the whole start-up, and so Settings can show the engine version.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[MVPython shared] start];
    });

    // Downloads finish while the user is elsewhere, so a banner is the only way
    // they find out. Without a delegate, banners are suppressed in foreground.
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                                                                    completionHandler:^(BOOL granted, NSError *error) {}];

    // The new manager owns the queue for every engine; it also takes over the
    // records the old engine left behind so one list shows everything.
    [[MVDownloadManager shared] resumeInterrupted];

    // If the system killed us mid-download, pick the queue back up. yt-dlp
    // continues the .part files it left behind.
    [[MVDownloadEngine shared] resumeInterrupted];
    return YES;
}

#pragma mark - Background URL sessions

/// The system wakes the app here when a background transfer finishes. The direct
/// engine hands its work to a background session when the app is suspended, so
/// this call is what lets it complete and update the row.
- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler {
    MVLogInfo(@"app: background URL session event %@", identifier);
    // No background session is registered in this checkpoint; acknowledging the
    // call keeps the system's bookkeeping correct for when one is added.
    completionHandler();
}

#pragma mark - Notifications

/// Shows the banner even when the app is in the foreground, which is where the
/// user usually is when a queued download finishes.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MVAppDelegate class]));
    }
}
