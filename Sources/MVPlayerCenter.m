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
        // Frosted layout: the blur view added below sits behind the controls.
        self.backgroundColor = [MVTheme glassCard];
        self.layer.cornerRadius = 16;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:MVTheme.shared.isDark ? 0.16 : 0.10].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 5);
        self.clipsToBounds = NO;

        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:
                                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = 16;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [self insertSubview:glass atIndex:0];

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

/// The full-screen player. A plain view controller with an AVPlayerLayer and a
/// glass control bar. It never takes ownership of the player (unlike
/// AVPlayerViewController, which pauses its player on dismissal), so the audio
/// simply keeps playing when the sheet closes and the mini bar takes over —
/// no resume polling, no audible gap.
@interface MVFullPlayerViewController : UIViewController
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onPrev)(void);
@property (nonatomic, copy, nullable) void (^onNext)(void);
@property (nonatomic, copy, nullable) void (^onSeekBack)(void);
@property (nonatomic, copy, nullable) void (^onSeekForward)(void);
@end

@implementation MVFullPlayerViewController {
    AVPlayerLayer *_videoLayer; // host layer for the player
    CALayer *_scrim;           // dim overlay between wallpaper and video
    UISlider *_slider;
    UILabel *_titleLabel;
    UILabel *_timeLabel;
    UIButton *_playButton;
    UIButton *_prevButton;
    UIButton *_nextButton;
    UIButton *_backButton;
    UIButton *_forwardButton;
    AVPlayer * _Nullable _player;
    id _periodicObserver;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Transparent: the wallpaper sits behind, so the player feels part of the
    // app rather than a black window.
    self.view.backgroundColor = UIColor.clearColor;

    // Wallpaper behind everything, frosting through the glass chrome.
    [MVTheme applyWallpaperTo:self.view];

    // A soft dim scrim helps the video stand out over the wallpaper.
    _scrim = [CALayer layer];
    _scrim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.25].CGColor;
    _scrim.name = @"MVPlayerScrim";

    _videoLayer = [AVPlayerLayer layer];
    _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;

    [self.view.layer insertSublayer:_scrim atIndex:1];
    [self.view.layer insertSublayer:_videoLayer atIndex:2];
    _videoLayer.player = self.player;

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [MVTheme text];
    _titleLabel.numberOfLines = 2;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    close.tintColor = [MVTheme text];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    _timeLabel = [UILabel new];
    _timeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _timeLabel.textColor = [MVTheme secondaryText];
    _timeLabel.textAlignment = NSTextAlignmentCenter;
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_timeLabel];

    _slider = [UISlider new];
    _slider.minimumTrackTintColor = [MVTheme accent];
    _slider.maximumTrackTintColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.25];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_slider];

    _prevButton = [self controlButton:@"backward.end.fill"];
    _backButton = [self controlButton:@"gobackward.15"];
    _playButton = [self controlButton:@"pause.fill"];
    _forwardButton = [self controlButton:@"goforward.15"];
    _nextButton = [self controlButton:@"forward.end.fill"];

    [_prevButton addTarget:self action:@selector(prevTapped) forControlEvents:UIControlEventTouchUpInside];
    [_backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    [_playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [_forwardButton addTarget:self action:@selector(forwardTapped) forControlEvents:UIControlEventTouchUpInside];
    [_nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];

    NSArray<UIButton *> *controls = @[_prevButton, _backButton, _playButton, _forwardButton, _nextButton];
    for (UIButton *b in controls) [self.view addSubview:b];
    [self.view addSubview:_playButton];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 26;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIButton *b in controls) [row addArrangedSubview:b];
    [self.view addSubview:row];

    // Glass control bar behind the transport row.
    UIView *glass = [UIView new];
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    [MVTheme applyCardStyle:glass cornerRadius:22];
    [self.view insertSubview:glass belowSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:56],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-56],

        [close.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [close.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:40],
        [close.heightAnchor constraintEqualToConstant:40],

        [row.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [row.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-34],
        [row.heightAnchor constraintEqualToConstant:56],

        [_prevButton.widthAnchor constraintEqualToConstant:48],
        [_prevButton.heightAnchor constraintEqualToConstant:48],
        [_backButton.widthAnchor constraintEqualToConstant:44],
        [_backButton.heightAnchor constraintEqualToConstant:44],
        [_playButton.widthAnchor constraintEqualToConstant:58],
        [_playButton.heightAnchor constraintEqualToConstant:58],
        [_forwardButton.widthAnchor constraintEqualToConstant:44],
        [_forwardButton.heightAnchor constraintEqualToConstant:44],
        [_nextButton.widthAnchor constraintEqualToConstant:48],
        [_nextButton.heightAnchor constraintEqualToConstant:48],

        [glass.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [glass.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [glass.topAnchor constraintEqualToAnchor:row.topAnchor constant:-18],
        [glass.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:18],

        [_timeLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [_timeLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [_timeLabel.topAnchor constraintEqualToAnchor:glass.bottomAnchor constant:12],

        [_slider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [_slider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [_slider.bottomAnchor constraintEqualToAnchor:glass.topAnchor constant:-14],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scrim.frame = self.view.bounds;
    _videoLayer.frame = self.view.bounds;
    [CATransaction commit];
    for (CALayer *l in [self.view.layer.sublayers copy]) {
        if ([l.name isEqualToString:@"MVWallpaperLayer"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            l.frame = self.view.bounds;
            [CATransaction commit];
        }
    }
}

- (void)setPlayer:(AVPlayer *)player {
    _player = player;
    // The layer may not exist yet (view is still lazy); viewDidLoad attaches it.
    if (_videoLayer) _videoLayer.player = player;
    [self refreshTitle];
    [self syncPlayIcon];
    [self startTicker];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [MVTheme applyWallpaperTo:self.view];
    [self refreshTitle];
    [self syncPlayIcon];
    [self startTicker];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self syncPlayIcon];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [MVTheme refreshWallpaperIfPattern:self.view];
        _titleLabel.textColor = [MVTheme text];
    }
}

- (void)dealloc {
    if (_periodicObserver) {
        [_player removeTimeObserver:_periodicObserver];
    }
}

/// Updates the slider + time label while playing.
- (void)startTicker {
    if (!_player || _periodicObserver) return;
    __weak typeof(self) weakSelf = self;
    _periodicObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                              queue:dispatch_get_main_queue()
                                                         usingBlock:^(CMTime time) {
        [weakSelf tick:time];
    }];
}

- (void)tick:(CMTime)time {
    if (!_player.currentItem) return;
    double total = CMTimeGetSeconds(_player.currentItem.duration);
    double pos = CMTimeGetSeconds(time);
    if (!isnan(total) && total > 0) {
        _slider.maximumValue = total;
        if (!_slider.tracking) _slider.value = MAX(0, MIN(pos, total));
        _timeLabel.text = [NSString stringWithFormat:@"%@  /  %@",
                           [self hms:pos], [self hms:total]];
    }
}

- (NSString *)hms:(double)seconds {
    if (isnan(seconds) || seconds < 0) seconds = 0;
    NSInteger s = (NSInteger)seconds;
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

- (void)syncPlayIcon {
    BOOL playing = _player.rate != 0 && !_player.error;
    UIImage *img = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
    [_playButton setImage:img forState:UIControlStateNormal];
}

- (void)refreshTitle {
    _titleLabel.text = self.title.length ? self.title : @"";
}

- (UIButton *)controlButton:(NSString *)symbol {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor = [MVTheme accent];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.imageView.tintColor = [MVTheme accent];
    return b;
}

- (void)closeTapped {
    if (self.onClose) self.onClose();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playTapped {
    if (_player.rate != 0 && !_player.error) {
        [_player pause];
    } else {
        [_player play];
    }
    [self syncPlayIcon];
}

- (void)prevTapped { if (self.onPrev) self.onPrev(); }
- (void)nextTapped { if (self.onNext) self.onNext(); }
- (void)backTapped { if (self.onSeekBack) self.onSeekBack(); }
- (void)forwardTapped { if (self.onSeekForward) self.onSeekForward(); }

- (void)sliderChanged:(UISlider *)slider {
    if (!_player.currentItem) return;
    // Fast jump (infinite tolerance): exact frame seeks issued dozens of times
    // per second while dragging can pile up and freeze playback.
    CMTime t = CMTimeMakeWithSeconds(slider.value, 1000);
    [_player seekToTime:t toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity];
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
// Bumped every time the item changes or playback is stopped, so a stale
// "resume after dismissal" from an earlier presentation cannot fight the new
// state (for example restarting a paused video the user actually stopped).
@property (nonatomic) NSUInteger generation;
// Remembers playback was running when an interruption began, so we can restart
// it automatically when the interruption ends.
@property (nonatomic) BOOL wasInterruptedWhilePlaying;
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
    self.generation++;
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
    CMTime cur = self.internalPlayer.currentTime;
    // Tap again at the start of the item to restart it, like most players.
    // Guard against an item that is still preparing (indefinite time would
    // otherwise be treated as "way past three seconds" and seek to a bogus spot).
    if (!CMTIME_IS_INDEFINITE(cur) && cur.value > 3 * cur.timescale) {
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
    self.generation++;
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
    if (!self.internalPlayer || !self.internalPlayer.currentItem) return;
    CMTime cur = [self.internalPlayer currentTime];
    // The item may still be preparing right after a replaceCurrentItem, when
    // currentTime is indefinite (NaN) and a seekToTime with an invalid time
    // blocks AVPlayer forever. Anything wrong means "stay put".
    if (CMTIME_IS_INDEFINITE(cur) || CMTimeGetSeconds(cur) != CMTimeGetSeconds(cur)) return;
    double target = CMTimeGetSeconds(cur) + seconds;
    [self safeSeek:target];
}

- (void)seekTo:(double)seconds {
    [self safeSeek:seconds];
}

/// The one seek used everywhere. It clamps to the item duration, guards against
/// NaN/indefinite values (which would freeze AVPlayer), and uses infinite
/// tolerances so the seek is a fast jump instead of a frame-exact decode.
- (void)safeSeek:(double)seconds {
    AVPlayerItem *item = self.internalPlayer.currentItem;
    if (!item) return;
    if (!(seconds == seconds)) return;  // NaN
    double total = CMTimeGetSeconds(item.duration);
    if (total > 0) seconds = MAX(0, MIN(seconds, total - 0.05));
    if (seconds < 0) seconds = 0;
    AVPlayer *p = self.internalPlayer;
    [p seekToTime:CMTimeMakeWithSeconds(seconds, 1000)
        toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity];
}

- (void)seekToSeconds:(double)seconds { [self seekTo:seconds]; }

- (double)currentTime {
    AVPlayerItem *item = self.internalPlayer.currentItem;
    if (!item) return 0;
    double t = CMTimeGetSeconds([self.internalPlayer currentTime]);
    return isnan(t) ? 0 : MAX(0, t);
}

- (double)duration {
    AVPlayerItem *item = self.internalPlayer.currentItem;
    if (!item) return 0;
    double d = CMTimeGetSeconds(item.duration);
    return isnan(d) || d < 0 ? 0 : d;
}

- (BOOL)hasQueue { return self.queue.count > 1; }

- (NSInteger)queueIndex { return self.queueIndex; }

#pragma mark - Playback state

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

- (void)hideFloatingBar { [self hideBar]; }
- (void)showFloatingBar { [self showBar]; }

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
        // Remember we were playing so "ended" can bring us back (e.g. a phone
        // call that the user hangs up). This is the other common "video needs
        // a manual play press" trap.
        self.wasInterruptedWhilePlaying = self.isPlaying;
        [self.internalPlayer pause];
        self.bar.pauseButton.selected = YES;
    } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        if (self.wasInterruptedWhilePlaying) {
            self.wasInterruptedWhilePlaying = NO;
            [self ensureAudioSession];
            [self.internalPlayer play];
            self.bar.pauseButton.selected = NO;
            [self refreshMiniBar];
        }
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
    if ([top isKindOfClass:MVFullPlayerViewController.class]) return;

    MVFullPlayerViewController *full = [MVFullPlayerViewController new];
    __weak typeof(self) weakSelf = self;
    full.title = self.currentTitle;
    full.player = self.internalPlayer;
    full.onClose = ^{
        // The player keeps running on its own — take the mini bar back up and
        // resync its state. No polling: nothing paused it.
        [weakSelf refreshMiniBar];
        [weakSelf showBar];
    };
    full.onPrev = ^{ [weakSelf playPrevious]; };
    full.onNext = ^{ [weakSelf playNext]; };
    full.onSeekBack = ^{ [weakSelf seekBack]; };
    full.onSeekForward = ^{ [weakSelf seekForward]; };

    // Hidden while the full player is up, so it never shows behind it.
    self.bar.alpha = 0;
    if (!self.isPlaying) [self.internalPlayer play];
    full.modalPresentationStyle = UIModalPresentationFullScreen;
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
