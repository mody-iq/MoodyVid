#import "MVBackgroundKeeper.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@interface MVBackgroundKeeper ()
@property (nonatomic, strong, nullable) AVAudioPlayer *player;
@property (nonatomic) NSInteger holders;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation MVBackgroundKeeper

+ (instancetype)shared {
    static MVBackgroundKeeper *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVBackgroundKeeper new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (BOOL)isHolding { return self.holders > 0; }

- (void)begin {
    self.holders++;
    if (self.holders != 1) return;   // already awake, nothing to start
    [self startHolding];
}

- (void)end {
    if (self.holders == 0) return;
    self.holders--;
    if (self.holders > 0) return;
    [self stopHolding];
}

- (void)startHolding {
    NSError *sessionError = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // Only take over the category when it is not already plain playback: the
    // video player sets exactly that, and re-configuring it mid-playback is an
    // unnecessary risk. MixWithOthers so the silent track never interrupts
    // whatever else the user is listening to.
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]) {
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&sessionError];
    }
    [session setActive:YES error:nil];

    NSURL *silence = [self silenceFileURL];
    if (silence) {
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:silence error:nil];
        self.player.numberOfLoops = -1;   // loop forever
        self.player.volume = 0;           // inaudible
        [self.player prepareToPlay];
        [self.player play];
    }

    // Belt and braces: the background task buys the first minutes even if the
    // audio session is momentarily refused (for example during a phone call).
    if (self.backgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"MoodyVid download keep-alive"
                                                                        expirationHandler:^{
            typeof(self) self_ = weakSelf;
            if (self_) [self_ stopHolding];
        }];
    }
}

- (void)stopHolding {
    [self.player stop];
    self.player = nil;
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}

/// Writes a one-second silent WAV once, then reuses it. Generating it in code
/// avoids shipping an audio asset whose only job is to be inaudible.
- (nullable NSURL *)silenceFileURL {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = dirs.firstObject;
    if (!dir.length) return nil;
    NSString *path = [dir stringByAppendingPathComponent:@"mv-silence.wav"];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];

    const uint32_t sampleRate = 44100;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint32_t frames = sampleRate;                 // one second
    const uint32_t dataSize = frames * channels * (bitsPerSample / 8);

    NSMutableData *data = [NSMutableData data];
    void (^put32)(uint32_t) = ^(uint32_t v) {
        uint32_t le = CFSwapInt32HostToLittle(v);
        [data appendBytes:&le length:4];
    };
    void (^put16)(uint16_t) = ^(uint16_t v) {
        uint16_t le = CFSwapInt16HostToLittle(v);
        [data appendBytes:&le length:2];
    };

    [data appendBytes:"RIFF" length:4];
    put32(36 + dataSize);
    [data appendBytes:"WAVE" length:4];

    [data appendBytes:"fmt " length:4];
    put32(16);                                          // PCM chunk size
    put16(1);                                           // format: PCM
    put16(channels);
    put32(sampleRate);
    put32(sampleRate * channels * (bitsPerSample / 8)); // byte rate
    put16(channels * (bitsPerSample / 8));              // block align
    put16(bitsPerSample);

    [data appendBytes:"data" length:4];
    put32(dataSize);
    [data appendData:[NSMutableData dataWithLength:dataSize]];   // silence

    if (![data writeToFile:path atomically:YES]) return nil;
    return [NSURL fileURLWithPath:path];
}

@end
