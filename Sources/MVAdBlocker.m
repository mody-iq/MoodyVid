#import "MVAdBlocker.h"
#import "MVLog.h"

static NSString *const kEnabledKey = @"MVAdBlockEnabled";
static NSString *const kRuleListID = @"MoodyVidAds";
/// A single identifier reused for every probe compile: WebKit replaces the list
/// under an identifier, so probing leaves no pile of throwaway lists behind.
static NSString *const kProbeListID = @"MoodyVidAdsProbe";

/// Every host whose requests are blocked outright. Split into chunks when the
/// rules are built, so one bad entry can only cost its own chunk.
static NSArray<NSString *> *MVBlockedHosts(void) {
    return @[
        @"*doubleclick.net", @"*googlesyndication.com", @"*googleadservices.com",
        @"*adservice.google.com", @"*google-analytics.com", @"*googletagmanager.com",
        @"*googletagservices.com", @"*scorecardresearch.com", @"*outbrain.com",
        @"*taboola.com", @"*criteo.com", @"*criteo.net", @"*adnxs.com", @"*adsrvr.org",
        @"*rubiconproject.com", @"*pubmatic.com", @"*openx.net", @"*casalemedia.com",
        @"*smartadserver.com", @"*adcolony.com", @"*applovin.com", @"*unityads.unity3d.com",
        @"*chartboost.com", @"*vungle.com", @"*inmobi.com", @"*mopub.com", @"*adform.net",
        @"*media.net", @"*amazon-adsystem.com", @"*yieldmo.com", @"*sharethrough.com",
        @"*teads.tv", @"*spotxchange.com", @"*3lift.com", @"*bidswitch.net", @"*zedo.com",
        @"*propellerads.com", @"*popads.net", @"*popcash.net", @"*adcash.com",
        @"*onclickads.net", @"*adsterra.com", @"*hilltopads.net", @"*exoclick.com",
        @"*juicyads.com", @"*trafficjunky.com", @"*revcontent.com", @"*mgid.com",
    ];
}

/// Turns an ad host into a url-filter that matches a request to that host or any
/// of its subdomains.
///
/// This has to be a `url-filter` rather than an `if-domain`: WebKit maps
/// `if-domain` to the *top-level page* URL, so an `if-domain` list of ad hosts
/// only fires when the page itself is on one of them — the requests *to* the ad
/// hosts slip through. Matching the request URL is what actually blocks them.
static NSString *MVHostFilter(NSString *host) {
    NSString *bare = [host hasPrefix:@"*"] ? [host substringFromIndex:1] : host;
    NSMutableString *escaped = [NSMutableString string];
    for (NSUInteger i = 0; i < bare.length; i++) {
        unichar c = [bare characterAtIndex:i];
        if (c == '.') [escaped appendString:@"\\."];
        else [escaped appendFormat:@"%C", c];
    }
    return [NSString stringWithFormat:@"^https?://([a-z0-9-]+\\.)*%@(:[0-9]+)?/", escaped];
}

static NSArray<NSString *> *MVResourceTypes(void) {
    return @[@"document", @"script", @"image", @"style-sheet", @"font",
             @"media", @"raw", @"fetch", @"websocket", @"other"];
}

static NSString *const kAdSelector =
    @"iframe[src*='ads'],iframe[src*='doubleclick'],iframe[src*='googlesyndication'],"
    "iframe[src*='adservice'],iframe[id*='google_ads'],iframe[class*='ad-'],"
    "div[id^='div-gpt-ad'],div[class*='adsbygoogle'],div[class*='ad-container'],"
    "div[class*='ad-wrapper'],div[class*='sponsored'],div[id*='taboola'],"
    "div[id*='outbrain'],ins.adsbygoogle,.adsbygoogle";

static NSString *MVRuleJSON(NSDictionary *rule) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:rule options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

/// The rule list, as an ordered array of single-rule JSON strings.
///
/// Kept small and readable: the goal is to remove the common ad and popup
/// networks and the leftover empty frames, not to replicate a full filter
/// subscription. Each rule is a separate element so the blocker can drop the
/// ones WebKit refuses instead of losing the whole list (WebKit rejects an
/// entire list when any single rule fails to compile).
static NSArray<NSString *> *MVAdBlockRules(void) {
    static NSArray<NSString *> *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *out = [NSMutableArray array];

        // Host blocking, in small chunks so one rejected host only costs its
        // own chunk rather than every host in the list.
        NSArray<NSString *> *hosts = MVBlockedHosts();
        static const NSUInteger kChunk = 8;
        for (NSUInteger i = 0; i < hosts.count; i += kChunk) {
            NSUInteger length = MIN(kChunk, hosts.count - i);
            NSMutableArray<NSString *> *filters = [NSMutableArray array];
            for (NSString *host in [hosts subarrayWithRange:NSMakeRange(i, length)]) {
                [filters addObject:MVHostFilter(host)];
            }
            [out addObject:MVRuleJSON(@{
                @"trigger": @{@"url-filter": [filters componentsJoinedByString:@"|"],
                              @"resource-type": MVResourceTypes()},
                @"action": @{@"type": @"block"},
            })];
        }

        // URL patterns for the ad scripts and frames that do not live on a
        // dedicated host.
        NSArray<NSString *> *filters = @[
            @".*\\/(ad|ads|adv|advert|advertisement|banner|popup|popunder|sponsor)[-_0-9]*\\.(js|json|html?|php)(\\?.*)?$",
            @".*\\/(pagead|adframe|adserver|ad_banner|banner_ad|adsbygoogle)[^\\/]*\\/?",
        ];
        for (NSString *filter in filters) {
            [out addObject:MVRuleJSON(@{@"trigger": @{@"url-filter": filter},
                                        @"action": @{@"type": @"block"}})];
        }

        // Strip tracking parameters from requests.
        [out addObject:MVRuleJSON(@{
            @"trigger": @{@"url-filter": @".*[?&](utm_source|utm_medium|utm_campaign|utm_term|utm_content|gclid|fbclid)="},
            @"action": @{@"type": @"block-cookies"},
        })];

        // Hide the empty boxes the blocked requests leave behind.
        [out addObject:MVRuleJSON(@{
            @"trigger": @{@"url-filter": @".*"},
            @"action": @{@"type": @"css-display-none", @"selector": kAdSelector},
        })];

        rules = out;
    });
    return rules;
}

/// The one rule that is certain to compile. Used only when every other rule was
/// rejected, so the blocker never ends up with nothing at all.
static NSString *MVMinimalRule(void) {
    return MVRuleJSON(@{@"trigger": @{@"url-filter": @".*doubleclick.*"},
                        @"action": @{@"type": @"block"}});
}

@implementation MVAdBlocker {
    WKContentRuleList *_list;
    BOOL _compiling;
    NSMutableArray<void (^)(WKContentRuleList *)> *_waiters;
}

+ (instancetype)shared {
    static MVAdBlocker *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVAdBlocker new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _waiters = [NSMutableArray array];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // Default ON: the owner's main complaint about mobile browsing is ads,
        // and the rules are conservative enough to be safe by default.
        _enabled = [defaults objectForKey:kEnabledKey] ? [defaults boolForKey:kEnabledKey] : YES;
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
    if (enabled) [self prepare];
}

+ (NSString *)rulesJSON {
    return [NSString stringWithFormat:@"[%@]", [MVAdBlockRules() componentsJoinedByString:@","]];
}

- (void)prepare {
    if (_list || _compiling || !self.enabled) return;
    _compiling = YES;
    // Fast path: the whole list in one compile. Only if WebKit refuses it do we
    // pay to find which rule it disliked.
    [self compileRules:MVAdBlockRules() identifier:kRuleListID onFailure:^{
        [self probeRules:MVAdBlockRules() index:0 accepted:[NSMutableArray array]];
    }];
}

/// Compiles a list of rule strings. On success the list is kept and the waiters
/// are flushed; on failure `onFailure` runs.
- (void)compileRules:(NSArray<NSString *> *)rules
          identifier:(NSString *)identifier
           onFailure:(void (^)(void))onFailure {
    if (!rules.count) {
        if (onFailure) onFailure();
        return;
    }
    NSString *json = [NSString stringWithFormat:@"[%@]", [rules componentsJoinedByString:@","]];
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:identifier
                                                     encodedContentRuleList:json
                                                          completionHandler:^(WKContentRuleList *ruleList, NSError *error) {
        if (ruleList) {
            self->_compiling = NO;
            self->_list = ruleList;
            MVLogInfo(@"adblock: rule list %@ compiled (%lu rules)", identifier, (unsigned long)rules.count);
            [self flushWaiters:ruleList];
            return;
        }
        MVLogWarn(@"adblock: compile failed for %@ (%lu rules): %@",
                  identifier, (unsigned long)rules.count, error.localizedDescription);
        if (onFailure) onFailure();
    }];
}

/// Compiles each rule on its own and keeps the ones WebKit accepts. This is the
/// repair path: one bad rule used to disable every rule with it.
- (void)probeRules:(NSArray<NSString *> *)rules
             index:(NSUInteger)index
          accepted:(NSMutableArray<NSString *> *)accepted {
    if (index >= rules.count) {
        [self finishProbeWithAccepted:accepted];
        return;
    }
    NSString *json = [NSString stringWithFormat:@"[%@]", rules[index]];
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:kProbeListID
                                                     encodedContentRuleList:json
                                                          completionHandler:^(WKContentRuleList *ruleList, NSError *error) {
        if (ruleList) {
            [accepted addObject:rules[index]];
        } else {
            MVLogWarn(@"adblock: rule %lu rejected: %@", (unsigned long)index, rules[index]);
        }
        [self probeRules:rules index:index + 1 accepted:accepted];
    }];
}

- (void)finishProbeWithAccepted:(NSMutableArray<NSString *> *)accepted {
    if (!accepted.count) {
        // Nothing survived: use the one rule we know WebKit takes.
        [self compileRules:@[MVMinimalRule()] identifier:[kRuleListID stringByAppendingString:@"Min"] onFailure:^{
            self->_compiling = NO;
            [self flushWaiters:nil];
        }];
        return;
    }
    [self compileRules:accepted identifier:[kRuleListID stringByAppendingString:@"Good"] onFailure:^{
        // The accepted rules should combine cleanly; if they do not, keep the
        // first one so blocking still works at all.
        [self compileRules:@[accepted.firstObject] identifier:[kRuleListID stringByAppendingString:@"Min"] onFailure:^{
            self->_compiling = NO;
            [self flushWaiters:nil];
        }];
    }];
}

- (void)flushWaiters:(WKContentRuleList *)list {
    NSArray<void (^)(WKContentRuleList *)> *waiters = [_waiters copy];
    [_waiters removeAllObjects];
    for (void (^waiter)(WKContentRuleList *) in waiters) {
        dispatch_async(dispatch_get_main_queue(), ^{ waiter(list); });
    }
}

- (void)ruleListWithCompletion:(void (^)(WKContentRuleList *))completion {
    if (!self.enabled) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    if (_list) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(self->_list); });
        return;
    }
    if (completion) [_waiters addObject:[completion copy]];
    [self prepare];
}

- (void)applyToConfiguration:(WKWebViewConfiguration *)configuration {
    if (!self.enabled || !configuration) return;
    [self ruleListWithCompletion:^(WKContentRuleList *ruleList) {
        if (!ruleList) return;
        [configuration.userContentController addContentRuleList:ruleList];
    }];
}

@end
