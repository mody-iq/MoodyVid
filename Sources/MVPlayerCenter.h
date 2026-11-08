#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted whenever the floating mini bar is shown or hidden, so other floating
/// UI (for example the parked in-app browser) can move out of its way.
FOUNDATION_EXPORT NSNotificationName const MVPlayerBarVisibilityDidChangeNotification;

/// A single, always-on AVPlayer owned by the app rather than by one screen.
///
/// Playback started from Downloads or Files keeps playing while the user moves
/// between tabs, and — because the app declares the UIBackgroundModes audio
/// capability and plays through the audio session — it also keeps playing when
/// the app moves to the background and another app comes to the front.
@interface MVPlayerCenter : NSObject

+ (instancetype)shared;

/// Starts playing the local file and keeps it in one player.
- (void)playURL:(NSURL *)url title:(NSString *)title;

/// Pauses playback; toggles to play if it was already paused.
- (void)toggle;

/// Stops playback and clears the small floating bar.
- (void)stop;

/// Presents the full-screen player if playback has started.
- (void)presentCurrentPlayer;

/// Hides the floating mini bar (it still reappears on new playback).
- (void)hideFloatingBar;
/// Shows the floating mini bar again.
- (void)showFloatingBar;

/// YES while a tab is showing its own inline player card. The card replaces the
/// mini bar, so setting this YES hides the bar and setting it NO brings it back
/// (unless the full-screen player is up). Setting it NO on tab switch keeps the
/// bar off the full-screen player's controls.
@property (nonatomic) BOOL inlinePlayerActive;

/// YES while the full-screen player is presented over the app.
@property (nonatomic, readonly) BOOL fullPlayerVisible;

/// Replaces the artwork shown in the floating mini-bar.
- (void)setThumbnailImage:(UIImage *)image;

/// Plays a whole list, so the mini-bar's previous/next buttons move through it.
/// Tapping a row in Downloads or Files hands over the rows around it.
- (void)playQueue:(NSArray<NSURL *> *)urls
          titles:(NSArray<NSString *> *)titles
       fromIndex:(NSInteger)index;

/// Jumps to the next/previous item in the current queue.
- (void)playNext;
- (void)playPrevious;

/// YES when there is more than one item, so previous/next are meaningful.
@property (nonatomic, readonly) BOOL hasQueue;
@property (nonatomic, readonly) NSInteger queueIndex;

/// YES while the floating mini bar is actually on screen. Other floating UI
/// (like the parked in-app browser) uses this to move out of its way.
@property (nonatomic, readonly) BOOL floatingBarVisible;

/// Skips by the player's fixed step (used by the 15-second buttons).
- (void)seekForward;
- (void)seekBack;

/// Scrubbing for an inline scrubber. Returns the current position and the
/// duration in seconds (0 while unknown), and seeks to an absolute position.
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
- (void)seekToSeconds:(double)seconds;

@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, readonly, nullable) AVPlayer *player;
@property (nonatomic, readonly, nullable) NSString *currentTitle;

@end

NS_ASSUME_NONNULL_END
