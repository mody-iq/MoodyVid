#import "MVTaskCell.h"
#import "MVPaths.h"
#import "MVLang.h"
#import "MVTheme.h"
#import "MVSnifferItem.h"

/// The round button at the end of a row: a progress ring while the task runs and
/// a plain icon once it has finished. Mirrors the ring the existing rows use, so
/// a mixed list still looks like one list.
@interface MVTaskActionButton : UIButton
- (void)showProgress:(double)progress;
- (void)showIcon:(NSString *)symbolName;
@end

@implementation MVTaskActionButton {
    CAShapeLayer *_track;
    CAShapeLayer *_ring;
    UIView *_stop;
    UIImageView *_icon;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 44, 44)])) {
        _track = [CAShapeLayer layer];
        _track.fillColor = UIColor.clearColor.CGColor;
        _track.lineWidth = 2.5;
        [self.layer addSublayer:_track];

        _ring = [CAShapeLayer layer];
        _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineWidth = 2.5;
        _ring.lineCap = kCALineCapRound;
        _ring.strokeEnd = 0;
        [self.layer addSublayer:_ring];

        _stop = [UIView new];
        _stop.frame = CGRectMake(0, 0, 10, 10);
        _stop.layer.cornerRadius = 2;
        _stop.userInteractionEnabled = NO;
        [self addSubview:_stop];

        _icon = [UIImageView new];
        _icon.frame = CGRectMake(0, 0, 32, 32);
        _icon.contentMode = UIViewContentModeCenter;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];
    }
    return self;
}

- (void)showProgress:(double)progress {
    _icon.hidden = YES;
    _stop.hidden = NO;
    _track.hidden = NO;
    _ring.hidden = NO;
    // A small sliver stays visible so a task that just started still looks alive.
    _ring.strokeEnd = MAX(0.04, MIN(1.0, progress));
    [self setNeedsLayout];
}

- (void)showIcon:(NSString *)symbolName {
    _icon.hidden = NO;
    _stop.hidden = YES;
    _track.hidden = YES;
    _ring.hidden = YES;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    _icon.image = [UIImage systemImageNamed:symbolName withConfiguration:config];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:center radius:14
                                                      startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    UIColor *accent = [[MVTheme accent] resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *track = [[[MVTheme secondaryText] colorWithAlphaComponent:0.30]
                      resolvedColorWithTraitCollection:self.traitCollection];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = self.bounds;
    _ring.frame = self.bounds;
    _track.path = circle.CGPath;
    _ring.path = circle.CGPath;
    _track.strokeColor = track.CGColor;
    _ring.strokeColor = accent.CGColor;
    [CATransaction commit];

    _stop.backgroundColor = accent;
    _stop.center = center;
    _icon.tintColor = [MVTheme secondaryText];
    _icon.center = center;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

@end

@implementation MVTaskCell {
    MVTaskActionButton *_actionButton;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;

        UIView *highlight = [UIView new];
        highlight.backgroundColor = [[MVTheme secondaryText] colorWithAlphaComponent:0.15];
        self.selectedBackgroundView = highlight;

        self.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        self.textLabel.textColor = [MVTheme text];
        self.textLabel.numberOfLines = 1;
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        self.detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        self.detailTextLabel.numberOfLines = 1;

        _actionButton = [[MVTaskActionButton alloc] initWithFrame:CGRectZero];
        [_actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
        self.accessoryView = _actionButton;
    }
    return self;
}

- (void)actionTapped { if (self.onAction) self.onAction(); }

/// "1.6 MB of 11.0 MB · 3.2 MB/s · 1m 5s left". Each size is wrapped in
/// direction isolates so the numbers keep their order inside an Arabic line.
+ (NSString *)detailTextForTask:(MVDownloadTask *)task {
    switch (task.state) {
        case MVTaskStateQueued:
            return [MVLang t:@"Queued"];
        case MVTaskStatePaused:
            return [MVLang t:@"Paused"];
        case MVTaskStateCompleted:
            return task.totalBytes > 0 ? [MVPaths formatBytes:task.totalBytes] : [MVLang t:@"Completed"];
        case MVTaskStateFailed:
            return [NSString stringWithFormat:@"%@: %@", [MVLang t:@"Failed"],
                    task.error ?: [MVLang t:@"Unknown error"]];
        case MVTaskStateCancelled:
            return [MVLang t:@"Cancel"];
        case MVTaskStateRunning:
            break;
    }

    // A phase ("Joining segments", "Merging…") is more useful than a byte count
    // while the engine is busy with work that moves no bytes.
    if (task.phase.length) {
        if (task.totalBytes <= 0) return task.phase;
        return [NSString stringWithFormat:@"%@ • %@", task.phase,
                [MVPaths formatBytes:task.totalBytes]];
    }
    if (task.totalBytes <= 0) {
        if (task.doneBytes > 0) return [NSString stringWithFormat:@"%@ • %@",
                                        [MVPaths formatBytes:task.doneBytes], [MVLang t:@"Downloading"]];
        return [MVLang t:@"Connecting…"];
    }
    NSString *of = MVLang.shared.isRTL ? @"من" : @"of";
    NSMutableString *text = [NSMutableString stringWithFormat:@"\u2068%@\u2069 %@ \u2068%@\u2069",
                             [MVPaths formatBytes:task.doneBytes], of, [MVPaths formatBytes:task.totalBytes]];
    if (task.speed > 0) {
        [text appendFormat:@" • %@", [MVPaths formatSpeed:task.speed]];
        if (task.eta > 0) [text appendFormat:@" • %@", [MVPaths formatDuration:task.eta]];
    }
    return text;
}

- (void)configureWithTask:(MVDownloadTask *)task {
    self.textLabel.text = task.title.length ? task.title : task.url;
    self.textLabel.textColor = [MVTheme text];

    switch (task.state) {
        case MVTaskStateRunning:
            self.detailTextLabel.text = [MVTaskCell detailTextForTask:task];
            self.detailTextLabel.textColor = [[MVTheme text] colorWithAlphaComponent:0.85];
            [_actionButton showProgress:task.progress];
            break;
        case MVTaskStateQueued:
        case MVTaskStatePaused:
            self.detailTextLabel.text = [MVTaskCell detailTextForTask:task];
            self.detailTextLabel.textColor = [MVTheme secondaryText];
            [_actionButton showIcon:@"play.fill"];
            break;
        case MVTaskStateCompleted:
            self.detailTextLabel.text = [MVTaskCell detailTextForTask:task];
            self.detailTextLabel.textColor = [MVTheme success];
            [_actionButton showIcon:@"square.and.arrow.down"];
            break;
        case MVTaskStateFailed:
            self.detailTextLabel.text = [MVTaskCell detailTextForTask:task];
            self.detailTextLabel.textColor = [MVTheme danger];
            [_actionButton showIcon:@"exclamationmark.circle"];
            break;
        case MVTaskStateCancelled:
            self.detailTextLabel.text = [MVTaskCell detailTextForTask:task];
            self.detailTextLabel.textColor = [MVTheme secondaryText];
            [_actionButton showIcon:@"square.and.arrow.down"];
            break;
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onAction = nil;
}

@end
