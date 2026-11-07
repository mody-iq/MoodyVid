#import "MVPlayerCenter.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import "MVTheme.h"
#import "MVLang.h"

/// The mini bar that stays above every screen while something is playing.
static CGFloat const kMiniBarHeight = 64;
static CGFloat const kMiniThumb = 44;

@interface MVFloatingPlayerBar : UIView
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIProgressView *progress;
@end

@implementation MVFloatingPlayerBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [MVTheme card];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [MVTheme cardBorder].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 4);
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

        _pauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_pauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
        [_pauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateSelected];
        _pauseButton.tintColor = [MVTheme accent];
        _pauseButton.translatesAutoresizingMaskIntoConstraints = NO;

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        _closeButton.tintColor = [MVTheme secondaryText];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;

        _progress = [UIProgressView new];
        _progress.progressTintColor = [MVTheme accent];
        _progress.trackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.18];
        _progress.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_thumbView];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        [self addSubview:_pauseButton];
        [self addSubview:_closeButton];
        [self addSubview:_progress];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_thumbView.widthAnchor constraintEqualToConstant:kMiniThumb],
            [_thumbView.heightAnchor constraintEqualToConstant:kMiniThumb],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:12],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:11],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_pauseButton.leadingAnchor constant:-8],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],

            [_progress.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_progress.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_progress.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:6],

            [_pauseButton.trailingAnchor constraintEqualToAnchor:_closeButton.leadingAnchor constant:-8],
            [_pauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_pauseButton.widthAnchor constraintEqualToConstant:34],
            [_pauseButton.heightAnchor constraintEqualToConstant:34],

            [_closeButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_closeButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_closeButton.widthAnchor constraintEqualToConstant:30],
            [_closeButton.heightAnchor constraintEqualToConstant:30],
        ]];
    }
    return self;
}

@end

@interface MVPlayerCenter () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) AVPlayer *internalPlayer;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, strong) MVFloatingPlayerBar *bar;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic) BOOL audioSessionReady;
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
    [self ensureAudioSession];

    self.currentTitle = title.length ? [title copy] : url.lastPathComponent.stringByDeletingPathExtension;
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
    [self showBar];
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
    [self hideBar];
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
    // The mini bar itself opens the player; the two buttons do not.
    if (touch.view == self.bar.pauseButton || touch.view == self.bar.closeButton) return NO;
    return YES;
}

- (void)refreshMiniBar {
    self.bar.titleLabel.text = self.currentTitle.length ? self.currentTitle : [MVLang t:@"Now playing"];
    self.bar.subtitleLabel.text = self.isPlaying ? [MVLang t:@"Playing"] : [MVLang t:@"Paused"];
    self.bar.pauseButton.selected = !self.isPlaying;
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
    AVPlayerViewController *full = [AVPlayerViewController new];
    full.player = self.internalPlayer;
    if (@available(iOS 15.0, *)) {
        full.allowsPictureInPicturePlayback = YES;
    }
    [full.player play];
    UIViewController *top = [self topViewController];
    if (top) {
        [top presentViewController:full animated:YES completion:nil];
    }
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
