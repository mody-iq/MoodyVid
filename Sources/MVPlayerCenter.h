#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

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

/// Presents the native full-screen player if playback has started.
- (void)presentCurrentPlayer;

/// Replaces the artwork shown in the floating mini-bar.
- (void)setThumbnailImage:(UIImage *)image;

@property (nonatomic, readonly, getter=isPlaying) BOOL playing;
@property (nonatomic, readonly, nullable) AVPlayer *player;
@property (nonatomic, readonly, nullable) NSString *currentTitle;

@end

NS_ASSUME_NONNULL_END
