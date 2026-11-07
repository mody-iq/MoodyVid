#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps the app awake while a download is running.
///
/// iOS suspends a backgrounded app a few seconds after it leaves the foreground
/// unless it is doing something the system considers legitimate. The app already
/// declares the `audio` background mode, so the one thing iOS always lets run is
/// playback. A UIBackgroundTask alone is not enough either: it is capped at a few
/// minutes, which a large video can exceed.
///
/// The fix is to play silence through the audio session for exactly as long as
/// something is downloading. That holds the process open (a real audio session
/// keeps the app running) until the queue drains, then it stops and releases the
/// session. Nothing is audible.
@interface MVBackgroundKeeper : NSObject

+ (instancetype)shared;

/// Begins holding the app awake. Safe to call repeatedly.
- (void)begin;

/// Releases the hold. Safe to call when not held.
- (void)end;

/// YES while the app is being held awake by a download.
@property (nonatomic, readonly) BOOL isHolding;

@end

NS_ASSUME_NONNULL_END
