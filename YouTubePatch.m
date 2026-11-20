#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

typedef NS_OPTIONS(uint32_t, WorkshopOptions) {
    WorkshopFewerAds = 1 << 0,
    WorkshopBackgroundAudio = 1 << 1,
    WorkshopHideShortsTab = 1 << 2,
    WorkshopCleanShareLinks = 1 << 3,
    WorkshopSponsorBlock = 1 << 4
};

static IMP originalFeed, originalTabs, originalShare;
static IMP originalActivate, originalTime, originalMutatedTime;

static BOOL signatureMatches(Method method, const char *result, const char *args) {
    if (!method || method_getNumberOfArguments(method) != strlen(args) + 2) return NO;
    char actual[16] = {0};
    method_getReturnType(method, actual, sizeof(actual));
    if (!strchr(result, actual[0])) return NO;
    for (unsigned int index = 0; args[index]; index++) {
        method_getArgumentType(method, index + 2, actual, sizeof(actual));
        if (actual[0] != args[index]) return NO;
    }
    return YES;
}

static void install(Class cls, SEL sel, const char *result, const char *args, IMP hook, IMP *original) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!signatureMatches(method, result, args)) return;
    IMP current = method_getImplementation(method);
    if (current == hook) return;
    if (original) *original = current;
    class_replaceMethod(cls, sel, hook, method_getTypeEncoding(method));
}

static id objectValue(id object, NSString *property) {
    SEL selector = NSSelectorFromString(property);
    if (!signatureMatches(class_getInstanceMethod(object_getClass(object), selector), "@", "")) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL boolValue(id object, NSString *property) {
    SEL selector = NSSelectorFromString(property);
    if (!signatureMatches(class_getInstanceMethod(object_getClass(object), selector), "Bc", "")) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL alwaysYes(__unused id receiver, __unused SEL selector) { return YES; }
static BOOL alwaysNo(__unused id receiver, __unused SEL selector) { return NO; }

static void filterFeed(id receiver, SEL selector, id model) {
    id sections = objectValue(model, @"contentsArray");
    if ([sections isKindOfClass:NSMutableArray.class]) {
        NSMutableArray *list = sections;
        for (NSInteger index = (NSInteger)list.count - 1; index >= 0; index--) {
            id items = objectValue(objectValue(list[(NSUInteger)index], @"itemSectionRenderer"), @"contentsArray");
            if (![items isKindOfClass:NSArray.class] || [items count] != 1) continue;
            id item = [items firstObject];
            if (boolValue(item, @"hasPromotedVideoRenderer") ||
                boolValue(item, @"hasCompactPromotedVideoRenderer") ||
                boolValue(item, @"hasPromotedVideoInlineMutedRenderer")) {
                [list removeObjectAtIndex:(NSUInteger)index];
            }
        }
    }
    ((void (*)(id, SEL, id))originalFeed)(receiver, selector, model);
}

static void filterTabs(id receiver, SEL selector, id renderer) {
    id value = objectValue(renderer, @"itemsArray");
    if ([value isKindOfClass:NSMutableArray.class] && [value count] > 1) {
        NSMutableArray *tabs = value;
        NSUInteger shortTab = [tabs indexOfObjectPassingTest:^BOOL(id tab, NSUInteger index, BOOL *stop) {
            id item = objectValue(tab, @"pivotBarItemRenderer") ?: objectValue(tab, @"pivotBarIconOnlyItemRenderer");
            return [objectValue(item, @"pivotIdentifier") isEqual:@"FEshorts"];
        }];
        if (shortTab != NSNotFound) [tabs removeObjectAtIndex:shortTab];
    }
    ((void (*)(id, SEL, id))originalTabs)(receiver, selector, renderer);
}

static id cleanLink(id item) {
    BOOL isString = [item isKindOfClass:NSString.class];
    NSURL *url = isString ? [NSURL URLWithString:item] : ([item isKindOfClass:NSURL.class] ? item : nil);
    if (!url) return item;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *host = parts.host.lowercaseString;
    if (![parts.scheme.lowercaseString isEqual:@"https"] ||
        (! [host isEqual:@"youtu.be"] && ! [host isEqual:@"youtube.com"] &&
         ! [host hasSuffix:@".youtube.com"])) return item;
    NSSet *tracking = [NSSet setWithArray:@[@"si", @"feature", @"app", @"embeds_referring_euri"]];
    NSArray<NSURLQueryItem *> *original = parts.queryItems;
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *parameter in original) {
        NSString *name = parameter.name.lowercaseString;
        if (![tracking containsObject:name] && ![name hasPrefix:@"utm_"]) [kept addObject:parameter];
    }
    if (kept.count == original.count) return item;
    parts.queryItems = kept.count ? kept : nil;
    NSURL *clean = parts.URL;
    return clean ? (isString ? clean.absoluteString : clean) : item;
}

typedef id (*ActivityInitializer)(id __attribute__((ns_consumed)) receiver, SEL selector, id items, id activities)
    __attribute__((ns_returns_retained));

static id __attribute__((ns_returns_retained)) share(id __attribute__((ns_consumed)) receiver,
                                                       SEL selector, NSArray *items, NSArray *activities) {
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) [cleaned addObject:cleanLink(item)];
    return ((ActivityInitializer)originalShare)(receiver, selector, cleaned, activities);
}

@interface WorkshopSegments : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *segments;
@property (nonatomic, strong) NSMutableIndexSet *skipped;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end
@implementation WorkshopSegments
@end

static char segmentsKey;

static NSString *videoIdentifier(id object) {
    for (NSString *property in @[@"videoID", @"videoId", @"currentVideoID"]) {
        id value = objectValue(object, property);
        if ([value isKindOfClass:NSString.class] && [value length] == 11) return value;
    }
    return nil;
}

static NSArray *sponsorRanges(NSData *data, NSString *videoID) {
    if (!data.length || data.length > 500000) return @[];
    id entries = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![entries isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *ranges = [NSMutableArray array];
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"videoID"] isEqual:videoID]) continue;
        id segments = entry[@"segments"];
        if (![segments isKindOfClass:NSArray.class]) continue;
        for (id segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class] || ![segment[@"category"] isEqual:@"sponsor"]) continue;
            id range = segment[@"segment"];
            if (![range isKindOfClass:NSArray.class] || [range count] != 2 ||
                ![range[0] isKindOfClass:NSNumber.class] || ![range[1] isKindOfClass:NSNumber.class]) continue;
            double start = [range[0] doubleValue], end = [range[1] doubleValue];
            if (isfinite(start) && isfinite(end) && start >= 0 && end > start) [ranges addObject:range];
        }
    }
    return ranges;
}

static void requestSegments(id controller, NSString *videoID) {
    WorkshopSegments *previous = objc_getAssociatedObject(controller, &segmentsKey);
    if ([previous.videoID isEqual:videoID]) return;
    [previous.task cancel];
    objc_setAssociatedObject(controller, &segmentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!videoID) return;

    NSData *identifier = [videoID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identifier.bytes, (CC_LONG)identifier.length, digest);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/skipSegments/%02x%02x?category=sponsor", (unsigned)digest[0], (unsigned)digest[1]]];
    WorkshopSegments *state = [WorkshopSegments new];
    state.videoID = videoID;
    state.skipped = [NSMutableIndexSet indexSet];
    objc_setAssociatedObject(controller, &segmentsKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakController = controller;
    __weak WorkshopSegments *weakState = state;
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
    state.task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 200) return;
        NSArray *ranges = sponsorRanges(data, videoID);
        dispatch_async(dispatch_get_main_queue(), ^{
            WorkshopSegments *current = weakState;
            id active = weakController;
            if (active && current && current == objc_getAssociatedObject(active, &segmentsKey)) current.segments = ranges;
        });
    }];
    [state.task resume];
}

static void activate(id receiver, SEL selector, id controller, id video, id data) {
    ((void (*)(id, SEL, id, id, id))originalActivate)(receiver, selector, controller, video, data);
    NSString *videoID = videoIdentifier(video) ?: videoIdentifier(data) ?: videoIdentifier(receiver);
    if (NSThread.isMainThread) requestSegments(receiver, videoID);
    else dispatch_async(dispatch_get_main_queue(), ^{ requestSegments(receiver, videoID); });
}

static void maybeSkip(id receiver, id video, double playbackTime) {
    if (!NSThread.isMainThread || !isfinite(playbackTime) || playbackTime < 0) return;
    WorkshopSegments *state = objc_getAssociatedObject(receiver, &segmentsKey);
    if (!state.segments.count) return;
    NSString *videoID = videoIdentifier(video) ?: videoIdentifier(receiver);
    if (!videoID || ![videoID isEqual:state.videoID]) return;
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (!signatureMatches(class_getInstanceMethod(object_getClass(receiver), seek), "v", "d")) return;
    for (NSUInteger index = 0; index < state.segments.count; index++) {
        NSArray<NSNumber *> *range = state.segments[index];
        double end = range[1].doubleValue;
        if (![state.skipped containsIndex:index] && playbackTime >= range[0].doubleValue && playbackTime < end - 0.15) {
            [state.skipped addIndex:index];
            ((void (*)(id, SEL, double))objc_msgSend)(receiver, seek, end);
            return;
        }
    }
}

static void updateTime(id receiver, SEL selector, id video, double time) {
    ((void (*)(id, SEL, id, double))originalTime)(receiver, selector, video, time);
    maybeSkip(receiver, video, time);
}
static void updateMutatedTime(id receiver, SEL selector, id video, double time) {
    ((void (*)(id, SEL, id, double))originalMutatedTime)(receiver, selector, video, time);
    maybeSkip(receiver, video, time);
}

static void applyOptions(WorkshopOptions options) {
    if (options & WorkshopFewerAds) {
        install(NSClassFromString(@"YTIPlayerResponse"), @selector(isMonetized), "Bc", "", (IMP)alwaysNo, NULL);
        install(NSClassFromString(@"YTSectionListViewController"), @selector(loadWithModel:), "v", "@", (IMP)filterFeed, &originalFeed);
    }
    if (options & WorkshopBackgroundAudio) {
        install(NSClassFromString(@"YTIPlayabilityStatus"), @selector(isPlayableInBackground), "Bc", "", (IMP)alwaysYes, NULL);
        install(NSClassFromString(@"MLVideo"), @selector(playableInBackground), "Bc", "", (IMP)alwaysYes, NULL);
    }
    if (options & WorkshopHideShortsTab) {
        install(NSClassFromString(@"YTPivotBarView"), @selector(setRenderer:), "v", "@", (IMP)filterTabs, &originalTabs);
    }
    if (options & WorkshopCleanShareLinks) {
        install(UIActivityViewController.class, @selector(initWithActivityItems:applicationActivities:), "@", "@@", (IMP)share, &originalShare);
    }
    if (options & WorkshopSponsorBlock) {
        Class player = NSClassFromString(@"YTPlayerViewController");
        install(player, @selector(playbackController:didActivateVideo:withPlaybackData:), "v", "@@@", (IMP)activate, &originalActivate);
        install(player, @selector(singleVideo:currentVideoTimeDidChange:), "v", "@d", (IMP)updateTime, &originalTime);
        install(player, @selector(potentiallyMutatedSingleVideo:currentVideoTimeDidChange:), "v", "@d", (IMP)updateMutatedTime, &originalMutatedTime);
    }
}

__attribute__((constructor)) static void startWorkshopPatch(void) {
    @autoreleasepool {
        WorkshopOptions options = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAWorkshopYouTubeOptions"] unsignedIntValue];
        if (!options) return;
        // Register after the app's Objective-C classes become available.
        dispatch_async(dispatch_get_main_queue(), ^{ applyOptions(options); });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(__unused NSNotification *note) { applyOptions(options); }];
    }
}
