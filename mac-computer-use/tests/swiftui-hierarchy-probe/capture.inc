// Included only in the separately compiled resident helper. No user code/selector input.
@interface NSObject (ProbeDebugHub)
+ (id)sharedHub;
- (NSData *)performRequestWithRequestInBase64:(NSString *)request;
@end

static UIView *freshHosting(const ResidentRequest *r) {
    NSMutableArray *pending = [NSMutableArray array];
    NSUInteger scenes = 0, windows = 0, visited = 0;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (++scenes > 8) return nil;
        if (![scene isKindOfClass:[UIWindowScene class]] || scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene.session.persistentIdentifier isEqualToString:[NSString stringWithUTF8String:r->scene]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (++windows > 8) return nil;
            [pending addObject:@[window, @0]];
        }
    }
    UIView *found = nil;
    while (pending.count) {
        if (++visited > 256 || pending.count > 256) return nil;
        NSArray *row = [[[pending lastObject] retain] autorelease]; [pending removeLastObject];
        UIView *view = row[0]; NSUInteger depth = [row[1] unsignedIntegerValue];
        if (depth > 32) return nil;
        // The Swift runtime resolves the helper-owned generic conformance.
        if ([SwiftUIProbeBridge accepts:view]) { if (found) return nil; found = view; }
        if (view.subviews.count > 256 - pending.count) return nil;
        for (UIView *child in view.subviews) [pending addObject:@[child, @(depth + 1)]];
    }
    return found;
}

static BOOL writeData(int fd, const char *name, NSData *data) {
    return data && data.length > 0 && data.length <= 16777216 && publish(fd, name, data.bytes, data.length);
}
static BOOL writeJSON(int fd, const char *name, id value) {
    return writeData(fd, name, [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL]);
}

// Raw transport only. Host interpretation cannot prevent direct/image collection.
static BOOL stage(int fd, Operation *op, const char *action, const char *phase,
                  NSString *outcome, NSUInteger bytes, BOOL callBegan) {
    char name[96]; snprintf(name, sizeof(name), "%s-%s.json", action, phase);
    return writeJSON(fd, name, @{@"action": @(action), @"phase": @(phase),
        @"operationID": @(op->request.operationID), @"requestDigest": @(op->request.digest),
        @"monotonicNS": @(nanos()), @"outcome": outcome, @"bytes": @(bytes), @"callBegan": @(callBegan)});
}
static NSString *rawOutcome(NSData *data, BOOL saved) {
    if (!data) return @"nil";
    if (data.length > 16777216) return @"overbudget";
    return saved ? @"bytes" : @"unavailable";
}

static atomic_int sentinels;
@interface SwiftUIProbePoolSentinel : NSObject { @public int directory; }
@end
@implementation SwiftUIProbePoolSentinel
- (void)dealloc {
    char bytes[160]; int n = snprintf(bytes, sizeof(bytes), "{\"monotonicNS\":%llu,\"remaining\":%d}",
        (unsigned long long)nanos(), atomic_fetch_sub(&sentinels, 1) - 1);
    publish(directory, "pool-sentinel-deallocated.json", bytes, (size_t)n);
    [super dealloc];
}
@end

static const char *captureHosting(UIView *root, Operation *op, int fd) {
    SwiftUIProbePoolSentinel *sentinel = [[[SwiftUIProbePoolSentinel alloc] init] autorelease];
    sentinel->directory = fd; atomic_fetch_add(&sentinels, 1);
    uint64_t started = nanos();
    UIWindow *window = root.window; UIView *parent = root.superview;
    CGRect bounds = root.bounds; CGFloat scale = window.screen.scale;
    CGFloat width = ceil(bounds.size.width * scale), height = ceil(bounds.size.height * scale);
    if (!window || !parent || root.hidden || root.alpha != 1 || !isfinite(width) || !isfinite(height) ||
        width <= 0 || height <= 0 || width > 2048 || height > 4096 || width * height * 4 > 33554432) return "imageBudgetRefused";
    // FIRST graph call precedes libViewDebuggerSupport load, texture request and drawHierarchy.
    uint64_t graphStart = nanos();
    if (!stage(fd, op, "typed", "began", @"pending", 0, YES)) return "stagePublicationFailed";
    NSData *graph = [SwiftUIProbeBridge graph:root];
    uint64_t graphEnd = nanos();
    BOOL graphSaved = writeData(fd, "external-graph.json", graph);
    if (!stage(fd, op, "typed", "returned", rawOutcome(graph, graphSaved), graph.length, YES)) return "stagePublicationFailed";
    if (nanos() - started > 3000000000ULL) return "graphTimeBudgetExceeded";

    if (cancelled(fd, op->request.digest) != 0 || millis() > op->request.expiresUnixMS) return "cancelledBetweenStages";

    // Current-version RE identifies exactly this Objective-C getter. Validate its
    // zero-explicit-argument object ABI before the fixed message. Never accept a selector input.
    SEL directSelector = sel_registerName("makeViewDebugData");
    Method directMethod = class_getInstanceMethod(object_getClass(root), directSelector);
    BOOL responds = [root respondsToSelector:directSelector];
    char resultType[32] = {0}, receiverType[32] = {0}, selectorType[32] = {0};
    if (directMethod) {
        method_getReturnType(directMethod, resultType, sizeof(resultType));
        method_getArgumentType(directMethod, 0, receiverType, sizeof(receiverType));
        method_getArgumentType(directMethod, 1, selectorType, sizeof(selectorType));
    }
    BOOL directABI = responds && directMethod && method_getNumberOfArguments(directMethod) == 2 &&
        !strcmp(resultType, "@") && !strcmp(receiverType, "@") && !strcmp(selectorType, ":");
    NSData *direct = nil; NSString *directClass = @"unavailable";
    uint64_t directStart = nanos();
    if (!stage(fd, op, "direct", "began", @"pending", 0, directABI)) return "stagePublicationFailed";
    if (directABI) {
        id value = ((id (*)(id, SEL))objc_msgSend)(root, directSelector);
        directClass = value ? NSStringFromClass([value class]) : @"nil";
        if ([value isKindOfClass:[NSData class]]) direct = value;
    }
    uint64_t directEnd = nanos();
    BOOL directSaved = writeData(fd, "direct-makeViewDebugData.json", direct);
    if (!stage(fd, op, "direct", "returned", directABI ?
        ([directClass isEqualToString:@"nil"] ? @"nil" : (direct ? rawOutcome(direct, directSaved) : @"unsupported")) : @"unsupported",
        direct.length, directABI)) return "stagePublicationFailed";
    writeJSON(fd, "direct-capability.json", @{@"selector": @"makeViewDebugData", @"responds": @(responds),
        @"ABIValidated": @(directABI), @"returnEncoding": [NSString stringWithUTF8String:resultType],
        @"returnClass": directClass, @"bytes": @(direct.length), @"saved": @(directSaved),
        @"equalTypedBytes": @(direct && graph && [direct isEqualToData:graph]),
        @"intervalNS": @[@(directStart), @(directEnd)]});
    if (nanos() - started > 4000000000ULL) return "directGraphTimeBudgetExceeded";

    if (cancelled(fd, op->request.digest) != 0 || millis() > op->request.expiresUnixMS) return "cancelledBetweenStages";

    // Baseline A: current fixed snapshotImage request, unchanged options and property list.
    NSData *request = [@PROBE_TEXTURE_REQUEST dataUsingEncoding:NSUTF8StringEncoding];
    writeData(fd, "A-request.json", request);
    static void *textureLibrary;
    NSData *hierarchy = nil;
    uint64_t aStart = nanos();
    id hub = nil;
    if (textureLibrary || (textureLibrary = dlopen("/usr/lib/libViewDebuggerSupport.dylib", RTLD_NOW | RTLD_LOCAL))) {
        Class hubClass = NSClassFromString(@"DBGTargetHub");
        hub = hubClass ? [hubClass sharedHub] : nil;
    }
    if (!stage(fd, op, "A", "began", @"pending", 0, hub != nil)) return "stagePublicationFailed";
    hierarchy = hub ? [hub performRequestWithRequestInBase64:[request base64EncodedStringWithOptions:0]] : nil;
    uint64_t aEnd = nanos();
    BOOL aSaved = writeData(fd, "A-hierarchy.json", hierarchy);
    if (!stage(fd, op, "A", "returned", hub ? rawOutcome(hierarchy, aSaved) : @"unsupported", hierarchy.length, hub != nil)) return "stagePublicationFailed";
    if (nanos() - started > 5000000000ULL) return "baselineTimeBudgetExceeded";

    if (cancelled(fd, op->request.digest) != 0 || millis() > op->request.expiresUnixMS) return "cancelledBetweenStages";

    // B is exactly one hosting-subtree composite; it is never copied onto declarative children.
    uint64_t bStart = nanos(); BOOL drawn = NO; NSData *png = nil;
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    @try {
        if (!stage(fd, op, "B", "began", @"pending", 0, YES)) return "stagePublicationFailed";
        drawn = [root drawViewHierarchyInRect:(CGRect){CGPointZero, bounds.size} afterScreenUpdates:NO];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        png = image ? UIImagePNGRepresentation(image) : nil;
    } @finally { UIGraphicsEndImageContext(); }
    uint64_t bEnd = nanos();
    BOOL bSaved = writeData(fd, "B-hosting-composite.png", png);
    if (!stage(fd, op, "B", "returned", rawOutcome(png, bSaved), png.length, YES)) return "stagePublicationFailed";
    BOOL stable = root.window == window && root.superview == parent && CGRectEqualToRect(root.bounds, bounds)
        && !root.hidden && root.alpha == 1 && freshHosting(&op->request) == root;
    CGPoint fixed = [root convertPoint:bounds.origin toView:window];
    fixed = [window convertPoint:fixed toCoordinateSpace:window.screen.fixedCoordinateSpace];
    NSDictionary *join = @{@"captureID": [NSString stringWithUTF8String:op->request.operationID],
        @"hostingNodeToken": [NSString stringWithUTF8String:op->request.generation],
        @"pid": @(getpid()), @"start": @[@(op->request.startSec), @(op->request.startUsec)],
        @"sceneID": [NSString stringWithUTF8String:op->request.scene],
        @"hostingAddress": [NSString stringWithFormat:@"%p", root], @"hostingClass": NSStringFromClass(root.class),
        @"parentAddress": [NSString stringWithFormat:@"%p", parent],
        @"windowAddress": [NSString stringWithFormat:@"%p", window],
        @"bounds": @[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)],
        @"fixedSpaceOrigin": @[@(fixed.x), @(fixed.y)], @"scale": @(scale),
        @"pixelSize": @[@(width), @(height)], @"orientation": @(window.windowScene.interfaceOrientation),
        @"dynamicConformance": @YES, @"graphSaved": @(graphSaved), @"graphBytes": @(graph.length),
        @"directGraph": @{@"ABIValidated": @(directABI), @"saved": @(directSaved), @"bytes": @(direct.length)},
        @"A": @{@"saved": @(aSaved), @"bytes": @(hierarchy.length), @"representation": @"snapshotImage"},
        @"B": @{@"saved": @(bSaved), @"bytes": @(png.length), @"drawHierarchyReturned": @(drawn),
            @"representation": @"hostingSubtreeComposite", @"includesDescendants": @YES},
        @"intervalsNS": @{@"graph": @[@(graphStart), @(graphEnd)], @"A": @[@(aStart), @(aEnd)], @"B": @[@(bStart), @(bEnd)]},
        @"hostingAssociationRevalidated": @(stable), @"editableProperties": @[], @"withinTimeBudget": @(nanos() - started <= 8000000000ULL)};
    if (!writeJSON(fd, "association.json", join)) return "associationPublicationFailed";
    return stable && graphSaved && bSaved && drawn && nanos() - started <= 8000000000ULL ? "captured" : "incomplete";
}
