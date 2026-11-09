#import "MVAdBlocker.h"
#import "MVLog.h"

static NSString *const kEnabledKey = @"MVAdBlockEnabled";
static NSString *const kRuleListID = @"MoodyVidAds";

/// The rule list.
///
/// Kept deliberately small and readable: the goal is to remove the common ad and
/// popup networks and the leftover empty frames, not to replicate a full filter
/// subscription. Every rule is a plain host/URL filter so it compiles fast and
/// stays correct as WebKit's engine evolves.
static NSString *const kRulesTemplate = @""
"[\n"
"{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*doubleclick.net\",\"*googlesyndication.com\",\"*googleadservices.com\",\"*adservice.google.com\",\"*google-analytics.com\",\"*googletagmanager.com\",\"*googletagservices.com\",\"*scorecardresearch.com\",\"*outbrain.com\",\"*taboola.com\",\"*criteo.com\",\"*criteo.net\",\"*adnxs.com\",\"*adsrvr.org\",\"*rubiconproject.com\",\"*pubmatic.com\",\"*openx.net\",\"*casalemedia.com\",\"*smartadserver.com\",\"*adcolony.com\",\"*applovin.com\",\"*unityads.unity3d.com\",\"*chartboost.com\",\"*vungle.com\",\"*inmobi.com\",\"*mopub.com\",\"*adform.net\",\"*media.net\",\"*amazon-adsystem.com\",\"*yieldmo.com\",\"*sharethrough.com\",\"*teads.tv\",\"*spotxchange.com\",\"*3lift.com\",\"*bidswitch.net\",\"*zedo.com\",\"*propellerads.com\",\"*popads.net\",\"*popcash.net\",\"*adcash.com\",\"*onclickads.net\",\"*adsterra.com\",\"*hilltopads.net\",\"*exoclick.com\",\"*juicyads.com\",\"*trafficjunky.com\",\"*revcontent.com\",\"*mgid.com\"],\"resource-type\":[\"document\",\"script\",\"image\",\"style-sheet\",\"font\",\"media\",\"raw\",\"fetch\",\"websocket\",\"other\"]},\"action\":{\"type\":\"block\"}},\n"
"{\"trigger\":{\"url-filter\":\".*\\\\/(ad|ads|adv|advert|advertisement|banner|popup|popunder|sponsor)[-_0-9]*\\\\.(js|json|html?|php)(\\\\?.*)?$\"},\"action\":{\"type\":\"block\"}},\n"
"{\"trigger\":{\"url-filter\":\".*[?&](utm_source|utm_medium|utm_campaign|utm_term|utm_content|gclid|fbclid)=\"},\"action\":{\"type\":\"block-cookies\"}},\n"
"{\"trigger\":{\"url-filter\":\".*\\\\/(pagead|adframe|adserver|ad_banner|banner_ad|adsbygoogle)[^\\\\/]*\\\\/?\"},\"action\":{\"type\":\"block\"}},\n"
"{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":\"iframe[src*='ads'],iframe[src*='doubleclick'],iframe[src*='googlesyndication'],iframe[src*='adservice'],iframe[id*='google_ads'],iframe[class*='ad-'],div[id^='div-gpt-ad'],div[class*='adsbygoogle'],div[class*='ad-container'],div[class*='ad-wrapper'],div[class*='sponsored'],div[id*='taboola'],div[id*='outbrain'],ins.adsbygoogle,.adsbygoogle\"}}\n"
"]\n";

/// A second, deliberately tiny list. WebKit rejects a whole list when any single
/// rule fails to compile, so when the full list is refused the blocker falls back
/// to these rules instead of leaving the browser with no blocking at all.
static NSString *const kRulesFallback = @""
"[\n"
"{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*doubleclick.net\",\"*googlesyndication.com\",\"*googleadservices.com\",\"*google-analytics.com\",\"*googletagmanager.com\",\"*outbrain.com\",\"*taboola.com\",\"*criteo.com\",\"*adnxs.com\",\"*amazon-adsystem.com\",\"*propellerads.com\",\"*onclickads.net\",\"*adsterra.com\"]},\"action\":{\"type\":\"block\"}},\n"
"{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":\"ins.adsbygoogle,.adsbygoogle,iframe[src*='doubleclick'],iframe[src*='googlesyndication']\"}}\n"
"]\n";

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

+ (NSString *)rulesJSON { return kRulesTemplate; }

- (void)prepare {
    if (_list || _compiling || !self.enabled) return;
    _compiling = YES;
    [self compileRules:kRulesTemplate identifier:kRuleListID fallback:YES];
}

/// WebKit refuses a whole list when one rule does not compile. A rejected list is
/// retried once with a minimal, known-good set, so a bad rule degrades blocking
/// instead of disabling it.
- (void)compileRules:(NSString *)rules identifier:(NSString *)identifier fallback:(BOOL)allowFallback {
    // A fresh compile is needed after a WebKit data reset, so the list is always
    // built from source rather than assumed to be in the store.
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:identifier
                                                      encodedContentRuleList:rules
                                                           completionHandler:^(WKContentRuleList *ruleList, NSError *error) {
        if (error || !ruleList) {
            MVLogWarn(@"adblock: compile failed (%@): %@", identifier, error.localizedDescription);
            if (allowFallback) {
                [self compileRules:kRulesFallback
                        identifier:[kRuleListID stringByAppendingString:@"Basic"]
                          fallback:NO];
                return;
            }
            self->_compiling = NO;
            [self flushWaiters:nil];
            return;
        }
        self->_compiling = NO;
        self->_list = ruleList;
        MVLogInfo(@"adblock: rule list %@ compiled", ruleList.identifier);
        [self flushWaiters:ruleList];
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
