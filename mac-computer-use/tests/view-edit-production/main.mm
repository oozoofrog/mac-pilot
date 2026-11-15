// run.py inserts the complete canonical expression into ExecuteExpression.
#import "UIKitShim.h"
#include <unistd.h>
static NSUInteger Assertions;
static void Check(BOOL value, NSString *why) { Assertions++; if (!value) { fprintf(stderr, "FAIL %s\n", [why UTF8String]); exit(1); } }
static BOOL ExecuteExpression(NSData *requestData, NSString *answerPath);
static NSString *Output;
static id State(void) { return objc_getAssociatedObject((id)objc_getClass("NSObject"), (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1")); }
static NSString *ID(void) { return [[NSUUID UUID] UUIDString]; }
static NSMutableDictionary *Call(NSDictionary *q) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:q options:0 error:NULL];
    Check(ExecuteExpression(data, Output), @"production expression wrote receipt");
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Output] options:NSJSONReadingMutableContainers error:NULL];
}
static void Reset(void) {
    objc_setAssociatedObject((id)objc_getClass("NSObject"), (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1"), nil, OBJC_ASSOCIATION_RETAIN);
    [TestView release]; TestView = nil; [TestWindow release]; TestWindow = [UIWindow new];
    TestView = [UIView new]; [TestWindow addSubview:TestView]; ReentrantBusyObserved = NO;
}
static NSMutableDictionary *Capture(void) {
    return [NSMutableDictionary dictionaryWithDictionary:@{@"kind": @"capture", @"operationID": ID(), @"requestDigest": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        @"ownerID": ID(), @"inspectionID": ID(), @"targetEpoch": ID(), @"sequence": @1,
        @"textureRequestBase64": TEST_TEXTURE_REQUEST,
        @"newCaptureID": ID(), @"expiresAt": @([[NSDate date] timeIntervalSince1970] + 120),
        @"replaceCaptureID": [NSNull null], @"replaceAttemptedCaptureID": [NSNull null]}];
}
static NSMutableDictionary *Edit(NSDictionary *q, NSDictionary *cap) {
    NSDictionary *node = nil;
    for (NSDictionary *n in cap[@"editableNodes"]) if (![n[@"editToken"] isEqual:n[@"windowToken"]]) node = n;
    Check(node != nil, @"owned child token captured");
    NSMutableDictionary *r = [[q mutableCopy] autorelease];
    r[@"kind"] = @"edit"; r[@"operationID"] = ID(); r[@"requestDigest"] = @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; r[@"sequence"] = @2;
    r[@"captureID"] = cap[@"captureID"]; r[@"nodeToken"] = node[@"editToken"];
    r[@"expectedParentToken"] = node[@"parentToken"]; r[@"expectedWindowToken"] = node[@"windowToken"];
    r[@"expectedClass"] = node[@"className"]; r[@"property"] = @"hidden"; r[@"expectedValue"] = @NO; r[@"value"] = @YES;
    return r;
}
static void Status(NSDictionary *r, NSString *status, NSString *reason) {
    Check([r[@"status"] isEqual:status], [NSString stringWithFormat:@"status %@ actual %@ (%@)", status, r[@"status"], r[@"reasonCode"]]);
    if (reason) Check([r[@"reasonCode"] isEqual:reason], [NSString stringWithFormat:@"reason %@ actual %@", reason, r[@"reasonCode"]]);
}
static NSMutableDictionary *Release(NSDictionary *q, NSDictionary *cap, NSUInteger sequence) {
    NSMutableDictionary *r = [[q mutableCopy] autorelease];
    [r removeObjectForKey:@"transition"];
    r[@"kind"] = @"release"; r[@"captureID"] = cap[@"captureID"]; r[@"operationID"] = ID(); r[@"sequence"] = @(sequence);
    r[@"releaseCaptureIDs"] = @[cap[@"captureID"]];
    return r;
}
static NSMutableDictionary *Successor(void) {
    NSMutableDictionary *q = Capture();
    q[@"transition"] = [NSMutableDictionary dictionaryWithDictionary:@{@"transitionID": ID(),
        @"predecessor": State()[@"releaseProof"], @"retired": [[State()[@"retired"] copy] autorelease]}];
    return q;
}
static void RolloverTests(void) {
    for (NSNumber *differentOwner in @[@NO, @YES]) {
        Reset(); NSMutableDictionary *q = Capture(); NSDictionary *cap = Call(q);
        NSMutableDictionary *e = Edit(q, cap); NSDictionary *applied = Call(e);
        NSMutableDictionary *release = Release(q, cap, 3);
        NSDictionary *released = Call(release); Status(released, @"success", @"released");
        Check([released[@"releaseProof"] isEqual:State()[@"releaseProof"]], @"release returns exact target retirement receipt");
        Check(TestView->_hidden && TestView->_setterCalls == 1, @"release has no inverse mutation");
        NSMutableDictionary *next = Successor();
        if (![differentOwner boolValue]) next[@"ownerID"] = q[@"ownerID"];
        NSDictionary *newCapture = Call(next); Status(newCapture, @"success", @"captured");
        Check([State()[@"retired"] count] == 1 && [State()[@"ownerID"] isEqual:next[@"ownerID"]], @"released predecessor permits same/different-owner inspection");
        Check([State()[@"retired"][0] isEqual:released[@"releaseProof"]], @"old epoch proof is retained");
        NSMutableDictionary *undo = [[e mutableCopy] autorelease]; undo[@"kind"] = @"revert";
        undo[@"undoToken"] = applied[@"undoToken"]; undo[@"undoReceipt"] = applied[@"undoReceipt"];
        undo[@"operationID"] = ID(); undo[@"sequence"] = @4;
        id current = State();
        for (NSDictionary *stale in @[q, e, undo, release]) {
            Status(Call(stale), @"expired", @"retiredInspectionOrEpoch");
            NSMutableDictionary *delayed = [[stale mutableCopy] autorelease]; delayed[@"operationID"] = ID();
            Status(Call(delayed), @"expired", @"retiredInspectionOrEpoch");
            Check(State() == current && [State()[@"registryState"] isEqual:@"active"], @"old capture/edit/undo/release cannot clear new ownership");
        }
        Check(TestView->_setterCalls == 1, @"stale replays invoke no setters");
        Status(Call(next), @"resultUnavailable", @"capturePayloadNotCached");
        Check(State() == current, @"duplicate transition returns receipt without replacement");
        NSMutableDictionary *conflict = [[next mutableCopy] autorelease];
        conflict[@"transition"] = [[next[@"transition"] mutableCopy] autorelease]; conflict[@"transition"][@"transitionID"] = ID();
        Status(Call(conflict), @"conflict", @"transitionConflict");
        NSMutableDictionary *freshEdit = Edit(next, newCapture);
        freshEdit[@"expectedValue"] = @YES; freshEdit[@"value"] = @NO;
        Status(Call(freshEdit), @"success", @"readbackMatched");
        Check(TestView->_setterCalls == 2 && !TestView->_hidden, @"successor tokens perform a new guarded edit");
        // Explicit exact replacement remains in this epoch and invalidates its old token graph.
        NSMutableDictionary *refresh = [[next mutableCopy] autorelease]; [refresh removeObjectForKey:@"transition"];
        refresh[@"operationID"] = ID(); refresh[@"sequence"] = @3; refresh[@"newCaptureID"] = ID();
        refresh[@"replaceCaptureID"] = newCapture[@"captureID"];
        Status(Call(refresh), @"success", @"captured"); Check([State()[@"retired"] count] == 1, @"exact replacement keeps retirement history");
        Status(Call(Release(next, newCapture, 4)), @"expired", @"captureChanged");
    }
    for (NSString *mode in @[@"active", @"quarantined", @"busy", @"unfinished", @"proofMismatch", @"historyMismatch", @"missingProof", @"malformedHistory", @"legacy", @"malformedOperation"]) {
        Reset(); NSMutableDictionary *q = Capture(); NSDictionary *cap = Call(q);
        NSDictionary *release = Release(q, cap, 2); Status(Call(release), @"success", @"released");
        NSMutableDictionary *next = Successor(); id current = State();
        NSString *status = @"ownershipConflict", *reason = @"predecessorNotVerifiedReleased";
        if ([mode isEqual:@"active"] || [mode isEqual:@"quarantined"]) State()[@"registryState"] = mode;
        if ([mode isEqual:@"busy"]) { State()[@"busy"] = @YES; status = @"busy"; reason = @"interruptedOrReentrant"; }
        if ([mode isEqual:@"unfinished"]) State()[@"operations"][q[@"operationID"]][@"phase"] = @"reserved";
        if ([mode isEqual:@"proofMismatch"]) {
            next[@"transition"][@"predecessor"] = [[next[@"transition"][@"predecessor"] mutableCopy] autorelease];
            next[@"transition"][@"predecessor"][@"operationID"] = ID();
        }
        if ([mode isEqual:@"historyMismatch"]) next[@"transition"][@"retired"] = @[State()[@"releaseProof"]];
        if ([mode isEqual:@"missingProof"]) { [next removeObjectForKey:@"transition"]; reason = @"transitionRequired"; }
        if ([mode isEqual:@"malformedHistory"]) { State()[@"retired"] = @[@{}]; status = @"keyCollision"; reason = @"foreignRegistryShape"; }
        if ([mode isEqual:@"legacy"]) { [State() removeObjectForKey:@"lifecycleVersion"]; status = @"keyCollision"; reason = @"foreignRegistryShape"; }
        if ([mode isEqual:@"malformedOperation"]) { State()[@"operations"][ID()] = @"unknown"; status = @"keyCollision"; reason = @"foreignRegistryShape"; }
        Status(Call(next), status, reason);
        Check(State() == current && [State()[@"ownerID"] isEqual:q[@"ownerID"]], @"unsafe predecessor cannot transfer ownership");
        Check(TestView->_setterCalls == 0, @"refused rollover invokes no setter");
        if ([mode isEqual:@"busy"]) Check([State()[@"busy"] boolValue], @"transition never resets busy");
    }
    Reset(); NSMutableDictionary *q = Capture(); NSDictionary *cap = Call(q);
    Status(Call(Release(q, cap, 2)), @"success", @"released");
    NSMutableDictionary *next = Successor();
    // Host/target disagreement: a claimed released predecessor cannot be recreated
    // if its anchor disappeared. This test erases only its owned host fixture state.
    objc_setAssociatedObject((id)objc_getClass("NSObject"), (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1"), nil, OBJC_ASSOCIATION_RETAIN);
    Status(Call(next), @"expired", @"registryMissing"); Check(State() == nil, @"missing predecessor is not manufactured");

    Reset(); q = Capture(); cap = Call(q); Status(Call(Release(q, cap, 2)), @"success", @"released");
    next = Successor(); NSDictionary *newCap = Call(next); Status(newCap, @"success", @"captured");
    // Simulate interruption at the already-published reserved successor. A missing
    // result and stuck busy must not authorize replay or a later owner's transition.
    [State()[@"results"] removeObjectForKey:next[@"operationID"]];
    State()[@"operations"][next[@"operationID"]][@"phase"] = @"reserved"; State()[@"busy"] = @YES;
    id current = State(); Status(Call(next), @"resultUnavailable", @"reservedOrEvicted");
    Status(Call(Release(next, newCap, 2)), @"busy", @"interruptedOrReentrant");
    Status(Call(q), @"expired", @"retiredInspectionOrEpoch");
    Check(State() == current && [State()[@"busy"] boolValue], @"interrupted successor fence and busy remain intact");

    Reset(); q = Capture(); cap = Call(q); Status(Call(Release(q, cap, 2)), @"success", @"released");
    next = Successor(); newCap = Call(next); Status(newCap, @"success", @"captured");
    Status(Call(Release(next, newCap, 2)), @"success", @"released");
    NSMutableDictionary *reusedID = Successor(); reusedID[@"transition"][@"transitionID"] = next[@"transition"][@"transitionID"];
    Status(Call(reusedID), @"conflict", @"transitionIdentityReused");
    // A repeated old transition cannot take a different successor, even after release.
    NSMutableDictionary *late = [[next mutableCopy] autorelease]; late[@"ownerID"] = ID(); late[@"inspectionID"] = ID(); late[@"targetEpoch"] = ID();
    Status(Call(late), @"ownershipConflict", @"predecessorNotVerifiedReleased");

    Reset(); q = Capture(); cap = Call(q);
    for (NSUInteger i = 0; i < 64; i++) {
        Status(Call(Release(q, cap, 2)), @"success", @"released");
        q = Successor(); cap = Call(q); Status(cap, @"success", @"captured");
        Check([State()[@"retired"] count] == i + 1, @"retirement records grow only to the explicit finite bound");
    }
    Status(Call(Release(q, cap, 2)), @"success", @"released"); current = State();
    Status(Call(Successor()), @"capacityExceeded", @"retiredEpochCapacity");
    Check(State() == current && [State()[@"retired"] count] == 64, @"capacity refuses without evicting replay fences");
    Check(TestView->_setterCalls == 0, @"capture/release cycles never inverse-edit");
}
static void Tests(void) {
    Reset(); NSMutableDictionary *q = Capture(); NSDictionary *cap = Call(q); Status(cap, @"success", @"captured");
    Check([cap[@"editableNodes"] count] == 2 && [State()[@"map"] count] == 2, @"exact bounded capture map");
    Check([cap[@"textureJoins"] count] == 2 && [cap[@"textureCapture"][@"sameOperationIdentity"] boolValue]
          && cap[@"hierarchy"] != nil, @"production same-operation texture join");
    Check(!State()[@"results"][q[@"operationID"]][@"hierarchy"] && !State()[@"results"][q[@"operationID"]][@"textureJoins"], @"target journal retains no image payload");
    Check([State()[@"map"] objectForKey:cap[@"editableNodes"][0][@"editToken"]] != nil, @"live weak lookup");
    NSMutableDictionary *e = Edit(q, cap); NSDictionary *applied = Call(e); Status(applied, @"success", @"readbackMatched");
    Check(TestView->_hidden && TestView->_setterCalls == 1 && [applied[@"setterEntered"] boolValue], @"one entered setter");
    Check([applied[@"mutationOutcome"] isEqual:@"appliedObserved"], @"applied readback separate outcome");
    Status(Call(e), @"success", @"readbackMatched"); Check(TestView->_setterCalls == 1, @"duplicate never sets twice");
    NSMutableDictionary *bad = [[e mutableCopy] autorelease]; bad[@"requestDigest"] = @"changed";
    Status(Call(bad), @"conflict", @"digestConflict"); Check(TestView->_setterCalls == 1, @"changed digest refuses setter");
    NSMutableDictionary *undo = [[e mutableCopy] autorelease]; undo[@"kind"] = @"revert"; undo[@"operationID"] = ID();
    undo[@"requestDigest"] = @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"; undo[@"sequence"] = @3; undo[@"undoToken"] = applied[@"undoToken"]; undo[@"undoReceipt"] = applied[@"undoReceipt"];
    Status(Call(undo), @"success", @"readbackMatched"); Check(!TestView->_hidden && TestView->_setterCalls == 2, @"server-owned guarded revert");
    undo[@"operationID"] = ID(); undo[@"sequence"] = @4;
    Status(Call(undo), @"undoConflict", @"missingUndoReceipt"); Check(TestView->_setterCalls == 2, @"consumed undo refused");
    Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap); applied = Call(e);
    NSDictionary *firstUndo = [[applied copy] autorelease];
    e[@"operationID"] = ID(); e[@"sequence"] = @3; e[@"expectedValue"] = @YES; e[@"value"] = @NO;
    Status(Call(e), @"success", @"readbackMatched");
    undo = [[e mutableCopy] autorelease]; undo[@"kind"] = @"revert"; undo[@"operationID"] = ID(); undo[@"sequence"] = @4;
    undo[@"undoToken"] = firstUndo[@"undoToken"]; undo[@"undoReceipt"] = firstUndo[@"undoReceipt"];
    Status(Call(undo), @"undoConflict", @"missingUndoReceipt");
    Check(TestView->_setterCalls == 2, @"later same-property revision supersedes older undo");

    for (NSString *mode in @[@"noChange", @"expected", @"weakNil", @"detached", @"reparented", @"class", @"expired", @"uptimeExpired", @"busy", @"foreign", @"foreignOwner"]) {
        @autoreleasepool {
            Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap);
            NSString *status = @"conflict", *reason = nil;
            if ([mode isEqual:@"noChange"]) { e[@"value"] = @NO; status = @"noChange"; reason = @"alreadyEqual"; }
            if ([mode isEqual:@"expected"]) { e[@"expectedValue"] = @YES; reason = @"expectedValueChanged"; }
            if ([mode isEqual:@"weakNil"]) {
                NSString *token = e[@"nodeToken"];
                [TestView removeFromSuperview]; [TestView release]; TestView = nil;
                Check([State()[@"map"] objectForKey:token] == nil, @"production weak map zeroes after deallocation");
                TestView = [UIView new]; [TestWindow addSubview:TestView];
                Check([State()[@"map"] objectForKey:token] == nil, @"replacement cannot inherit old key"); reason = @"weakNil";
            }
            if ([mode isEqual:@"detached"]) { [TestView removeFromSuperview]; reason = @"staleGraph"; }
            if ([mode isEqual:@"reparented"]) { UIView *parent = [[[UIView alloc] init] autorelease]; [TestWindow addSubview:parent]; [parent addSubview:TestView]; reason = @"staleGraph"; }
            if ([mode isEqual:@"class"]) { e[@"expectedClass"] = @"ReplacementClass"; reason = @"captureIdentityMismatch"; }
            if ([mode isEqual:@"expired"]) { State()[@"expiresAt"] = @0; status = @"expired"; reason = @"expiredOrQuarantined"; }
            if ([mode isEqual:@"uptimeExpired"]) { State()[@"expiresUptime"] = @0; status = @"expired"; reason = @"expiredOrQuarantined"; }
            if ([mode isEqual:@"busy"]) { State()[@"busy"] = @YES; status = @"busy"; reason = @"interruptedOrReentrant"; }
            if ([mode isEqual:@"foreign"]) { objc_setAssociatedObject((id)objc_getClass("NSObject"), (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1"), @"foreign", OBJC_ASSOCIATION_RETAIN); status = @"keyCollision"; reason = @"foreignRegistryShape"; }
            if ([mode isEqual:@"foreignOwner"]) { e[@"ownerID"] = ID(); status = @"ownershipConflict"; reason = @"foreignOwnerOrEpoch"; }
            NSDictionary *r = Call(e); Status(r, status, reason); Check(TestView->_setterCalls == 0, @"admission rejects with zero setters");
            if ([mode isEqual:@"busy"]) Check([State()[@"busy"] boolValue], @"stuck busy is not reset");
            if ([mode isEqual:@"foreign"]) Check([State() isEqual:@"foreign"], @"foreign association preserved");
        }
    }
    for (NSString *mode in @[@"throwBefore", @"throwAfter", @"mismatch", @"detach", @"reentrant"]) {
        @autoreleasepool {
            Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap); TestView->_mode = [mode copy];
            State()[@"testOperation"] = e[@"operationID"];
            NSDictionary *r = Call(e);
            Check(TestView->_setterCalls == 1 && [r[@"setterEntered"] boolValue], @"setter entry journal survives failure");
            if ([mode isEqual:@"throwAfter"]) Check(TestView->_hidden, @"write survived the thrown exception");
            if ([mode isEqual:@"throwBefore"]) Check(!TestView->_hidden, @"throw-before-write still remains uncertain after entry");
            if ([mode isEqual:@"reentrant"]) { Status(r, @"success", nil); Check(ReentrantBusyObserved, @"setter sees busy plus entry journal"); }
            else {
                Status(r, @"outcomeUncertain", nil); Check([r[@"mutationOutcome"] isEqual:@"uncertain"], @"exception/readback failure never notApplied");
                Status(Call(e), @"outcomeUncertain", nil); Check(TestView->_setterCalls == 1, @"uncertain duplicate never re-enters");
                e[@"operationID"] = ID(); e[@"sequence"] = @3; Status(Call(e), @"expired", @"expiredOrQuarantined");
            }
        }
    }
    Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap); e[@"property"] = @"alpha"; e[@"expectedValue"] = @1.0;
    for (NSNumber *n in @[@0.0, @0.5, @1.0]) {
        e[@"operationID"] = ID(); e[@"sequence"] = @([e[@"sequence"] unsignedIntegerValue] + 1); e[@"value"] = n;
        NSDictionary *r = Call(e); Status(r, @"success", @"readbackMatched"); Check([r[@"observed"] isEqual:n], @"alpha exact readback"); e[@"expectedValue"] = n;
    }
    // Eviction is tested through 257 real production dispatches, not a substitute model.
    Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap); e[@"value"] = @NO;
    NSDictionary *oldRequest = [[e copy] autorelease]; Status(Call(e), @"noChange", nil);
    for (NSUInteger i = 3; i <= 260; i++) { e[@"operationID"] = ID(); e[@"sequence"] = @(i); Status(Call(e), @"noChange", nil); }
    Check([State()[@"results"] count] == 256, @"bounded result cache");
    Status(Call(oldRequest), @"resultUnavailable", @"reservedOrEvicted");
    e[@"operationID"] = ID(); e[@"sequence"] = @2; Status(Call(e), @"resultUnavailable", @"highWater");
    Check(TestView->_setterCalls == 0, @"evicted/high-water never re-executes");

    Reset(); q = Capture(); cap = Call(q); e = Edit(q, cap); applied = Call(e);
    // Independent app change must defeat guarded undo.
    TestView->_hidden = NO; undo = [[e mutableCopy] autorelease]; undo[@"kind"] = @"revert"; undo[@"operationID"] = ID(); undo[@"sequence"] = @3;
    undo[@"undoToken"] = applied[@"undoToken"]; undo[@"undoReceipt"] = applied[@"undoReceipt"];
    Status(Call(undo), @"conflict", @"expectedValueChanged"); Check(TestView->_setterCalls == 1, @"undo never overwrites app drift");
    NSMutableDictionary *release = [[e mutableCopy] autorelease]; release[@"kind"] = @"release"; release[@"operationID"] = ID(); release[@"sequence"] = @4;
    Status(Call(release), @"success", @"released"); Check(!State()[@"map"] && !State()[@"nodes"] && !State()[@"undo"], @"release drops payload only");
    Check(TestView->_setterCalls == 1, @"release never inverse-edits");
    Status(Call(release), @"success", @"released");
    // Owned refresh replaces map without resetting sequence history.
    NSMutableDictionary *refresh = [[q mutableCopy] autorelease]; refresh[@"operationID"] = ID(); refresh[@"sequence"] = @5;
    refresh[@"newCaptureID"] = ID(); refresh[@"replaceCaptureID"] = cap[@"captureID"];
    Status(Call(refresh), @"success", @"captured"); Check([State()[@"highWater"] unsignedIntegerValue] == 5, @"refresh retains high-water");
    e[@"operationID"] = ID(); e[@"sequence"] = @6; Status(Call(e), @"expired", @"captureChanged");
    for (NSString *bound in @[@"nodes", @"depth"]) {
        @autoreleasepool {
            Reset(); UIView *parent = TestWindow;
            NSUInteger count = [bound isEqual:@"nodes"] ? 20000 : 513;
            for (NSUInteger i = 0; i < count; i++) {
                UIView *view = [[[UIView alloc] init] autorelease]; [parent addSubview:view];
                if ([bound isEqual:@"depth"]) parent = view;
            }
            q = Capture(); NSDictionary *r = Call(q);
            Status(r, @"conflict", @"graphBoundsOrOwnership");
            Check(!r[@"editableNodes"] && !State()[@"map"], @"over-budget capture grants no tokens");
        }
    }
    Reset();
    const void *unrelated = (const void *)sel_registerName("fixture.unrelated.association");
    objc_setAssociatedObject((id)objc_getClass("NSObject"), unrelated, @"preserve", OBJC_ASSOCIATION_RETAIN);
    q = Capture(); cap = Call(q); e = Edit(q, cap);
    release = [[e mutableCopy] autorelease]; release[@"kind"] = @"release";
    Status(Call(release), @"success", @"released");
    Check([objc_getAssociatedObject((id)objc_getClass("NSObject"), unrelated) isEqual:@"preserve"], @"owned release preserves unrelated association");
    objc_setAssociatedObject((id)objc_getClass("NSObject"), unrelated, nil, OBJC_ASSOCIATION_RETAIN);
    Reset();
}
int main(int argc, const char **argv) {
    if (argc != 3 || strcmp(argv[1], "--native-check") || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    @autoreleasepool {
        Output = [NSString stringWithUTF8String:argv[2]];
        Tests(); RolloverTests(); printf("PASS production edit expression: %lu assertions\n", (unsigned long)Assertions);
    }
    return 0;
}
