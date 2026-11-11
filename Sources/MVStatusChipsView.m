#import "MVStatusChipsView.h"
#import "MVTheme.h"

@implementation MVStatusChip
+ (instancetype)chipWithTitle:(NSString *)title tag:(NSInteger)tag {
    MVStatusChip *chip = [MVStatusChip new];
    chip.title = title;
    chip.tag = tag;
    return chip;
}
@end

@interface MVStatusChipButton : UIButton
@property (nonatomic) NSInteger chipTag;
@property (nonatomic) BOOL selectedChip;
- (void)configureWithChip:(MVStatusChip *)chip;
@end

@implementation MVStatusChipButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.titleLabel.font = [MVTheme chipFont];
        self.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
        self.layer.cornerRadius = 16.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        [self applyStyle];
    }
    return self;
}

- (void)configureWithChip:(MVStatusChip *)chip {
    self.chipTag = chip.tag;
    NSString *text = chip.count > 0 ? [NSString stringWithFormat:@"%@  %ld", chip.title, (long)chip.count]
                                    : chip.title;
    [self setTitle:text forState:UIControlStateNormal];
    [self invalidateIntrinsicContentSize];
    [self applyStyle];
}

- (void)setSelectedChip:(BOOL)selectedChip {
    _selectedChip = selectedChip;
    [self applyStyle];
}

- (void)applyStyle {
    if (self.selectedChip) {
        self.backgroundColor = [MVTheme accent];
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.layer.borderColor = UIColor.clearColor.CGColor;
    } else {
        self.backgroundColor = [[MVTheme glassCard] colorWithAlphaComponent:0.5];
        [self setTitleColor:[MVTheme text] forState:UIControlStateNormal];
        self.layer.borderColor = [[MVTheme cardBorder] colorWithAlphaComponent:0.14].CGColor;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyStyle];
}

@end

@implementation MVStatusChipsView {
    UIScrollView *_scroll;
    UIStackView *_stack;
    NSMutableArray<MVStatusChipButton *> *_buttons;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _buttons = [NSMutableArray array];

        _scroll = [UIScrollView new];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        [self addSubview:_scroll];

        _stack = [UIStackView new];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.spacing = 8;
        _stack.alignment = UIStackViewAlignmentCenter;
        [_scroll addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:2],
            [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-2],
            [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor],
            [_stack.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor constant:-4],
        ]];
    }
    return self;
}

- (void)setChips:(NSArray<MVStatusChip *> *)chips {
    _chips = [chips copy];
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_buttons removeAllObjects];
    for (MVStatusChip *chip in chips) {
        MVStatusChipButton *b = [MVStatusChipButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b configureWithChip:chip];
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [b.heightAnchor constraintGreaterThanOrEqualToConstant:32].active = YES;
        [_stack addArrangedSubview:b];
        [_buttons addObject:b];
    }
    [self updateSelection];
}

- (void)setSelectedTag:(NSInteger)selectedTag {
    _selectedTag = selectedTag;
    [self updateSelection];
}

- (void)updateSelection {
    for (MVStatusChipButton *b in _buttons) {
        b.selectedChip = (b.chipTag == self.selectedTag);
    }
}

- (void)chipTapped:(MVStatusChipButton *)sender {
    self.selectedTag = sender.chipTag;
    if (self.onSelect) self.onSelect(sender.chipTag);
}

@end
