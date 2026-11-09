#import "MVBrowserTab.h"

@implementation MVBrowserTab

- (NSString *)displayTitle {
    if (self.title.length) return self.title;
    if (self.url.length) {
        NSURL *url = [NSURL URLWithString:self.url];
        if (url.host.length) return url.host;
    }
    return @"New Tab";
}

@end
