#import "MVFloatingAddButton.h"
#import "MVTheme.h"
#import "MVLang.h"

@implementation MVFloatingAddButton {
    NSArray<NSArray *> *_actions;
}

+ (instancetype)button {
    MVFloatingAddButton *b = [MVFloatingAddButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:@"plus" withConfiguration:config] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [MVTheme accent];
    b.layer.cornerRadius = 28.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.28;
    b.layer.shadowRadius = 12;
    b.layer.shadowOffset = CGSizeMake(0, 6);
    b.accessibilityLabel = [MVLang t:@"Add"];
    [b addTarget:b action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:56],
        [b.heightAnchor constraintEqualToConstant:56],
    ]];
    return b;
}

- (void)setActions:(NSArray<NSArray *> *)actions {
    _actions = [actions copy];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSArray *entry in actions) {
        if (entry.count < 3) continue;
        NSString *title = entry[0];
        NSString *symbol = entry[1];
        void (^handler)(void) = entry[2];
        UIAction *action = [UIAction actionWithTitle:title
                                               image:[UIImage systemImageNamed:symbol]
                                          identifier:nil
                                             handler:^(UIAction *a) { handler(); }];
        [children addObject:action];
    }
    self.menu = [UIMenu menuWithChildren:children];
    self.showsMenuAsPrimaryAction = YES;
}

- (void)pulse {
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    anim.values = @[@1.0, @1.12, @0.98, @1.0];
    anim.duration = 0.5;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:anim forKey:@"pulse"];
}

- (void)showMenu {
    // A primary-action menu opens itself; this is only reached if the menu is nil.
    [self pulse];
}

@end
