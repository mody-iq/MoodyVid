#import "MVPlayerCenter.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import "MVTheme.h"
#import "MVLang.h"

/// The mini bar that stays above every screen while something is playing.
static CGFloat const kMiniBarHeight = 80;
static CGFloat const kMiniThumb = 46;
static CGFloat const kSeekSeconds = 15.0;

/// A small tinted icon button used in the mini bar.
static UIButton *MVBarButton(NSString *symbol, UIColor *tint) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = tint;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

@interface MVFloatingPlayerBar : UIView
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *forwardButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIProgressView *progress;
@end

@implementation MVFloatingPlayerBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [MVTheme card];
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [MVTheme cardBorder].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 5);
        self.clipsToBounds = NO;

        _thumbView = [UIImageView new];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.layer.cornerRadius = 8;
        _thumbView.layer.masksToBounds = YES;
        _thumbView.clipsToBounds = YES;
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [UILabel new];
        _titleLabel.numberOfLines = 1;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _subtitleLabel = [UILabel new];
        _subtitleLabel.numberOfLines = 1;
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [MVTheme secondaryText];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _prevButton = MVBarButton(@"backward.end.fill", [MVTheme accent]);
        _backButton = MVBarButton(@"gobackward.15", [MVTheme text]);
        _pauseButton = MVBarButton(@"pause.fill", [MVTheme accent]);
        _forwardButton = MVBarButton(@"goforward.15", [MVTheme text]);
        _nextButton = MVBarButton(@"forward.end.fill", [MVTheme accent]);

        _closeButton = MVBarButton(@"xmark.circle.fill", [MVTheme secondaryText]);

        _progress = [UIProgressView new];
        _progress.progressTintColor = [MVTheme accent];
        _progress.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.18];
        _progress.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_thumbView];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        [self addSubview:_prevButton];
        [self addSubview:_backButton];
        [self addSubview:_pauseButton];
        [self addSubview:_forwardButton];
        [self addSubview:_nextButton];
        [self addSubview:_closeButton];
        [self addSubview:_progress];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_thumbView.widthAnchor constraintEqualToConstant:kMiniThumb],
            [_thumbView.heightAnchor constraintEqualToConstant:kMiniThumb],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:12],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_prevButton.leadingAnchor constant:-8],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],

            [_progress.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_progress.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_progress.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:6],

            // Right-side button cluster: prev, back, pause, forward, next, close.
            [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_closeButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_closeButton.widthAnchor constraintEqualToConstant:26],
            [_closeButton.heightAnchor constraintEqualToConstant:26],

            [_nextButton.trailingAnchor constraintEqualToAnchor:_closeButton.leadingAnchor constant:-6],
            [_nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_nextButton.widthAnchor constraintEqualToConstant:32],
            [_nextButton.heightAnchor constraintEqualToConstant:32],

            [_forwardButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor constant:-6],
            [_forwardButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_forwardButton.widthAnchor constraintEqualToConstant:30],
            [_forwardButton.heightAnchor constraintEqualToConstant:30],

            [_pauseButton.trailingAnchor constraintEqualToAnchor:_forwardButton.leadingAnchor constant:-6],
            [_pauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_pauseButton.widthAnchor constraintEqualToConstant:34],
            [_pauseButton.heightAnchor constraintEqualToConstant:34],

            [_backButton.trailingAnchor constraintEqualToAnchor:_pauseButton.leadingAnchor constant:-6],
            [_backButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_backButton.widthAnchor constraintEqualToConstant:30],
            [_backButton.heightAnchor constraintEqualToConstant:30],

            [_prevButton.trailingAnchor constraintEqualToAnchor:_backButton.leadingAnchor constant:-6],
            [_prevButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_prevButton.widthAnchor constraintEqualToConstant:32],
            [_prevButton.heightAnchor constraintEqualToConstant:32],
        ]];
    }
    return self;
}

@end

/// The system player, with a fix: iOS pauses an AVPlayerViewController's player
/// when the controller is dismissed. The user expects the video to keep playing
/// in the mini bar, so playback is resumed if it was playing when the dismissal began.
@interface MVPlayerViewController : AVPlayerViewController
@property (nonatomic, copy, nullable) void (^onDismissed)(void);
@property (nonatomic) BOOL wasPlaying;
@end

@implementation MVPlayerViewController

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed) {
        self.wasPlaying = (self.player.timeControlStatus != AVPlayerTimeControlStatusPaused);
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.isBeingDismissed) return;
    AVPlayer *player = self.player;
    if (self.wasPlaying && player) {
        // Give AVKit a beat to hand the player back before re-starting, then
        // keep nudging it: the system sometimes pauses again right after the
        // dismissal animation completes. Shorter first checks mean the gap the
        // user heard is gone in practice.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [player play];
        });
        for (NSNumber *delay in @[@0.25, @0.5, @1.0, @2.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (player.status == AVPlayerStatusReadyToPlay &&
                    player.timeControlStatus == AVPlayerTimeControlStatusPaused) {
                    [player play];
                }
            });
        }
    }
    if (self.onDismissed) self.onDismissed();
}

@end

@interface MVPlayerCenter () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) AVPlayer *internalPlayer;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, strong) MVFloatingPlayerBar *bar;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic) BOOL audioSessionReady;
// Playlist the previous/next buttons move through.
@property (nonatomic, copy) NSArray<NSURL *> *queue;
@property (nonatomic, copy) NSArray<NSString *> *queueTitles;
@property (nonatomic) NSInteger queueIndex;
@end

@implementation MVPlayerCenter

+ (instancetype)shared {
    static MVPlayerCenter *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVPlayerCenter new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bar = [MVFloatingPlayerBar new];
        [_bar.pauseButton addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [_bar.closeButton addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
        [_bar.backButton addTarget:self action:@selector(seekBack) forControlEvents:UIControlEventTouchUpInside];
        [_bar.forwardButton addTarget:self action:@selector(seekForward) forControlEvents:UIControlEventTouchUpInside];
        [_bar.prevButton addTarget:self action:@selector(playPrevious) forControlEvents:UIControlEventTouchUpInside];
        [_bar.nextButton addTarget:self action:@selector(playNext) forControlEvents:UIControlEventTouchUpInside];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openFullPlayer)];
        tap.delegate = self;
        [_bar addGestureRecognizer:tap];
        [self registerRemoteCommands];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleInterruption:)
                                                   name:AVAudioSessionInterruptionNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleRouteChange:)
                                                   name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

- (void)registerRemoteCommands {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [self toggle];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [self toggle];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [self toggle];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)ensureAudioSession {
    if (self.audioSessionReady) return;
    self.audioSessionReady = YES;
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
}

- (void)playURL:(NSURL *)url title:(NSString *)title {
    [self playQueue:@[url] titles:title.length ? @[title] : @[] fromIndex:0];
}

- (void)playQueue:(NSArray<NSURL *> *)urls titles:(NSArray<NSString *> *)titles fromIndex:(NSInteger)index {
    if (!urls.count) return;
    if (index < 0 || index >= (NSInteger)urls.count) index = 0;
    self.queue = [urls copy];
    self.queueTitles = titles.count == urls.count ? [titles copy] : @[];
    self.queueIndex = index;
    [self loadItemAtIndex:index];
}

- (void)loadItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.queue.count) return;
    self.queueIndex = index;
    NSURL *url = self.queue[index];
    NSString *title = index < (NSInteger)self.queueTitles.count && self.queueTitles[index].length
        ? self.queueTitles[index]
        : url.lastPathComponent.stringByDeletingPathExtension;
    self.currentTitle = title;

    [self ensureAudioSession];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    if (!self.internalPlayer) {
        self.internalPlayer = [AVPlayer new];
        __weak typeof(self) weakSelf = self;
        self.timeObserver = [self.internalPlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                                             queue:dispatch_get_main_queue()
                                                                        usingBlock:^(CMTime t) {
            [weakSelf syncProgress];
        }];
    }
    [self.internalPlayer replaceCurrentItemWithPlayerItem:item];
    [self.internalPlayer play];
    [self refreshMiniBar];
}

- (void)playNext {
    if (self.queue.count < 2) return;
    NSInteger next = self.queueIndex + 1;
    if (next >= (NSInteger)self.queue.count) next = 0;
    [self loadItemAtIndex:next];
    [self refreshMiniBar];
}

- (void)playPrevious {
    if (self.queue.count < 2) return;
    // Tap again at the start of the item to restart it, like most players.
    if (self.internalPlayer.currentTime.value > 3 * self.internalPlayer.currentTime.timescale) {
        [self seekTo:0];
        return;
    }
    NSInteger prev = self.queueIndex - 1;
    if (prev < 0) prev = (NSInteger)self.queue.count - 1;
    [self loadItemAtIndex:prev];
    [self refreshMiniBar];
}

- (void)pause {
    [self.internalPlayer pause];
    self.bar.pauseButton.selected = YES;
}

- (void)toggle {
    if (!self.internalPlayer) return;
    if (self.isPlaying) {
        [self.internalPlayer pause];
        self.bar.pauseButton.selected = YES;
    } else {
        [self.internalPlayer play];
        self.bar.pauseButton.selected = NO;
    }
}

- (void)stop {
    [self.internalPlayer pause];
    self.bar.pauseButton.selected = NO;
    self.queue = nil;
    self.queueTitles = nil;
    [self hideBar];
}

#pragma mark - Seeking

- (void)seekForward {
    [self seekBy:kSeekSeconds];
}

- (void)seekBack {
    [self seekBy:-kSeekSeconds];
}

- (void)seekBy:(double)seconds {
    if (!self.internalPlayer) return;
    CMTime cur = [self.internalPlayer currentTime];
    double target = CMTimeGetSeconds(cur) + seconds;
    if (target < 0) target = 0;
    CMTime t = CMTimeMakeWithSeconds(target, 600);
    [self.internalPlayer seekToTime:t toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity];
}

- (void)seekTo:(double)seconds {
    [self.internalPlayer seekToTime:CMTimeMakeWithSeconds(seconds, 600)
                    toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (BOOL)isPlaying {
    return (self.internalPlayer.rate != 0 && !self.internalPlayer.error);
}

- (AVPlayer *)player { return self.internalPlayer; }

- (void)setThumbnailImage:(UIImage *)image {
    self.bar.thumbView.image = image;
}

#pragma mark - Floating bar

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // The mini bar itself opens the player; the buttons do not.
    for (UIView *v in @[self.bar.pauseButton, self.bar.closeButton, self.bar.backButton,
                        self.bar.forwardButton, self.bar.prevButton, self.bar.nextButton]) {
        if (touch.view == v || [v.subviews containsObject:touch.view]) return NO;
    }
    return YES;
}

- (void)refreshMiniBar {
    self.bar.titleLabel.text = self.currentTitle.length ? self.currentTitle : [MVLang t:@"Now playing"];
    self.bar.subtitleLabel.text = self.isPlaying ? [MVLang t:@"Playing"] : [MVLang t:@"Paused"];
    self.bar.pauseButton.selected = !self.isPlaying;
    BOOL multi = self.queue.count > 1;
    self.bar.prevButton.enabled = multi;
    self.bar.nextButton.enabled = multi;
    self.bar.prevButton.alpha = multi ? 1 : 0.4;
    self.bar.nextButton.alpha = multi ? 1 : 0.4;
}

- (void)showBar {
    UIWindow *window = self.bar.window ?: [self keyWindow];
    if (!window) return;
    if (self.bar.superview != window) {
        if (self.bar.superview) [self.bar removeFromSuperview];
        [window addSubview:self.bar];
        [NSLayoutConstraint activateConstraints:@[
            [self.bar.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:10],
            [self.bar.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-10],
            [self.bar.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-54],
            [self.bar.heightAnchor constraintEqualToConstant:kMiniBarHeight],
        ]];
    }
    self.bar.alpha = 1;
}

- (void)hideBar {
    if (!self.bar.superview) return;
    [UIView animateWithDuration:0.2 animations:^{
        self.bar.alpha = 0;
    } completion:^(BOOL done) {
        if (self.bar.superview) [self.bar removeFromSuperview];
    }];
}

- (UIWindow *)keyWindow {
    UIWindow *candidate = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
            if (!candidate) candidate = w;
        }
    }
    return candidate;
}

- (void)syncProgress {
    if (!self.internalPlayer) return;
    AVPlayerItem *item = self.internalPlayer.currentItem;
    double total = CMTimeGetSeconds(item.duration);
    double pos = CMTimeGetSeconds(self.internalPlayer.currentTime);
    self.bar.progress.progress = (total > 0 && !isnan(pos / total)) ? pos / total : 0;
    // selected == paused; if that disagrees with the player, refresh the labels.
    if (self.bar.pauseButton.selected == self.isPlaying) [self refreshMiniBar];
}

- (void)handleInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        [self.internalPlayer pause];
        self.bar.pauseButton.selected = YES;
    }
}

- (void)handleRouteChange:(NSNotification *)note {
    NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.unsignedIntegerValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [self.internalPlayer pause];
        self.bar.pauseButton.selected = YES;
    }
}

- (void)openFullPlayer {
    [self ensureAudioSession];
    UIViewController *top = [self topViewController];
    if (!top) {
        [self showBar];
        return;
    }
    // A second tap while the player is already open must not stack another one.
    if ([top isKindOfClass:MVPlayerViewController.class]) return;

    MVPlayerViewController *full = [MVPlayerViewController new];
    full.player = self.internalPlayer;
    if (@available(iOS 15.0, *)) {
        full.allowsPictureInPicturePlayback = YES;
    }
    __weak typeof(self) weakSelf = self;
    full.onDismissed = ^{
        [weakSelf refreshMiniBar];
        [weakSelf showBar];
    };
    // Hidden while the full player is up, so it never shows behind it.
    self.bar.alpha = 0;
    [self.internalPlayer play];
    [top presentViewController:full animated:YES completion:nil];

    // If iOS refused the presentation, do not leave the bar hidden forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!full.presentingViewController) [weakSelf showBar];
    });
}

- (void)presentCurrentPlayer {
    // Called from the row menu / long-press sheet: that sheet is still
    // dismissing when this runs, and iOS silently drops a presentViewController
    // while a presentation is in progress (the classic "audio but no player").
    // Wait for the dismissal to finish, then present. The mini-bar tap uses
    // -openFullPlayer directly and is unaffected.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self openFullPlayer];
    });
}

- (UIViewController *)topViewController {
    UIViewController *root = self.keyWindow.rootViewController;
    if (!root) return nil;
    while (root.presentedViewController) root = root.presentedViewController;
    return root;
}

@end
