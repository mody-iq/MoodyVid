#import "MVPlayerCenter.h"
#import <MediaPlayer/MediaPlayer.h>
#import "MVTheme.h"
#import "MVLang.h"
#import "MVPaths.h"

/// The bar is hosted in the key window, above every screen, so navigating between
/// tabs cannot push it away.
static CGFloat const kMiniBarHeight = 58;

@interface MVFloatingPlayerBar : UIView
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIProgressView *progress;
@end

@implementation MVFloatingPlayerBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _thumbView = [UIImageView new];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.layer.cornerRadius = 6;
        _thumbView.layer.masksToBounds = YES;
        _thumbView.clipsToBounds = YES;
        _thumbView.image = [UIImage systemImageNamed:@"play.rectangle.fill"];
        _thumbView.tintColor = [MVTheme secondaryText];
        _thumbView.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.12];
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;

        _titleLabel = [UILabel new];
        _titleLabel.numberOfLines = 1;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [MVTheme text];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_pauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
        [_pauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateSelected];
        _pauseButton.tintColor = [MVTheme accent];
        _pauseButton.translatesAutoresizingMaskIntoConstraints = NO;

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        _closeButton.tintColor = [MVTheme secondaryText];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;

        _progress = [UIProgressView new];
        _progress.progressTintColor = [MVTheme accent];
        _progress.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.18];
        _progress.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_thumbView];
        [self addSubview:_titleLabel];
        [self addSubview:_pauseButton];
        [self addSubview:_closeButton];
        [self addSubview:_progress];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_thumbView.widthAnchor constraintEqualToConstant:76],
            [_thumbView.heightAnchor constraintEqualToConstant:42],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:10],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_pauseButton.leadingAnchor constant:-8],

            [_progress.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_progress.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_progress.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],

            [_pauseButton.trailingAnchor constraintEqualToAnchor:_closeButton.leadingAnchor constant:-4],
            [_pauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_pauseButton.widthAnchor constraintEqualToConstant:34],
            [_pauseButton.heightAnchor constraintEqualToConstant:34],

            [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_closeButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_closeButton.widthAnchor constraintEqualToConstant:30],
            [_closeButton.heightAnchor constraintEqualToConstant:30],
        ]];
    }
    return self;
}

@end

@interface MVPlayerCenter ()
@property (nonatomic, strong) AVPlayer *internalPlayer;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, strong) MVFloatingPlayerBar *bar;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic) BOOL audioSessionReady;
@end

@interface MVPlayerCenter () <AVAudioSessionDelegate>
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
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openFullPlayer)];
        [_bar addGestureRecognizer:tap];
        [self registerRemoteCommands];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleInterruption:)
                                                   name:AVAudioSessionInterruptionNotification object:nil];
        // If something louder happens (a phone call, another app), playback has
        // already stopped; do not fight it, just refresh the floating bar.
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
    // Category Playback is what lets audio continue when the app moves into the
    // background and the screen locks (background mode: audio).
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
}

- (void)playURL:(NSURL *)url title:(NSString *)title {
    [self ensureAudioSession];

    self.currentTitle = [title copy];
    if (!self.internalPlayer) {
        self.internalPlayer = [AVPlayer new];
        __weak typeof(self) weakSelf = self;
        self.timeObserver = [self.internalPlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                                             queue:dispatch_get_main_queue()
                                                                        usingBlock:^(CMTime t) {
            [weakSelf syncProgress];
        }];
    }
    [self.internalPlayer replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]];
    [self.internalPlayer play];
    [self showBar];
    [self syncProgress];
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
    [self hideBar];
}

- (BOOL)isPlaying {
    return (self.internalPlayer.rate != 0 && !self.internalPlayer.error);
}

- (AVPlayer *)player { return self.internalPlayer; }

#pragma mark - Floating bar

- (void)showBar {
    UIWindow *window = [self keyWindow];
    if (!window) return;
    if (self.bar.superview) {
        if (self.bar.superview != window) {
            [self.bar removeFromSuperview];
            [window addSubview:self.bar];
        }
    } else {
        [window addSubview:self.bar];
    }
    self.bar.titleLabel.text = self.currentTitle.length ? self.currentTitle : [MVLang t:@"Now playing"];
    self.bar.pauseButton.selected = !self.isPlaying;
    [NSLayoutConstraint activateConstraints:@[
        [self.bar.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:10],
        [self.bar.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [self.bar.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-52],
        [self.bar.heightAnchor constraintEqualToConstant:kMiniBarHeight],
    ]];
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
    UIWindow *window = self.bar.window;
    if (window) return window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.connectedScenes.allObjects.firstObject.windows.firstObject;
}

- (void)syncProgress {
    if (!self.internalPlayer) return;
    double total = CMTimeGetSeconds(self.internalPlayer.currentItem.duration);
    double pos = CMTimeGetSeconds(self.internalPlayer.currentTime);
    if (total > 0) {
        self.bar.progress.progress = pos / total;
    } else {
        self.bar.progress.progress = 0;
    }
}

- (void)handleInterruption:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    NSNumber *type = userInfo[AVAudioSessionInterruptionTypeKey];
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
    AVPlayerViewController *full = [AVPlayerViewController new];
    full.player = self.internalPlayer;
    [full.player play];
    UIViewController *top = [self topViewController];
    if (top) {
        [top presentViewController:full animated:YES completion:nil];
    }
}

- (UIViewController *)topViewController {
    UIViewController *root = self.keyWindow.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    return root;
}

@end
