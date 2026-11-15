#import "Operation.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static NSUInteger checks;
static void check(BOOL condition, const char *name) {
    checks++; printf("%s %s\n", condition ? "PASS" : "FAIL", name); fflush(stdout);
    if (!condition) exit(1);
}
static const void *key(void) { return (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1"); }
static NSDictionary *edit(OperationDriver *driver, NSString *op, NSUInteger seq, NSString *prop, id old, id value) {
    return [driver request:op sequence:seq property:prop expected:old value:value generation:driver.generation
                     token:@"node" parent:@"parent" window:@"window" klass:@"FakeView" now:1];
}
static OperationDriver *fixture(FakeView **output) {
    FakeView *root = [FakeView new], *parent = [FakeView new], *node = [FakeView new];
    [root.children addObject:parent]; [parent.children addObject:node]; parent.parent = root;
    node.parent = parent; node.window = root; *output = node;
    return [[OperationDriver alloc] initWithRoot:root node:node];
}
static BOOL status(NSDictionary *value, NSString *expected) { return [value[@"status"] isEqual:expected]; }
static void lifetime(void) {
    NSMapTable *map = [NSMapTable strongToWeakObjectsMapTable];
    __weak FakeView *weak;
    @autoreleasepool {
        FakeView *node = [FakeView new]; weak = node;
        [map setObject:node forKey:@"old"];
        check([map objectForKey:@"old"] == node, "weak lookup original");
    }
    check(weak == nil && [map objectForKey:@"old"] == nil, "last strong release zeros old token");
    @autoreleasepool {
        FakeView *replacement = [FakeView new];
        check([map objectForKey:@"old"] == nil, "same class/default properties cannot inherit token");
        [map setObject:replacement forKey:@"new"];
        __strong FakeView *local;
        @autoreleasepool { local = [map objectForKey:@"new"]; replacement = nil; }
        check(local != nil, "strong operation local preserves object");
        local = nil;
    }
    check([map objectForKey:@"new"] == nil, "operation local release zeros entry");
    __weak NSObject *weakKey;
    FakeView *alive = [FakeView new];
    @autoreleasepool {
        NSObject *token = [NSObject new]; weakKey = token; [map setObject:alive forKey:token];
    }
    check(weakKey != nil, "map owns object key");
    @autoreleasepool { map = nil; }
    check(weakKey == nil, "dropping map releases key while view lives");
    const void *third = sel_registerName("org.oozoofrog.macCu.lifetimeHarness.thirdParty");
    objc_setAssociatedObject(alive, third, @"keep", OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(alive, key(), @"ours", OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(alive, key(), nil, OBJC_ASSOCIATION_RETAIN);
    check([objc_getAssociatedObject(alive, third) isEqual:@"keep"], "clear owned association preserves third party");
    __weak NSObject *weakAssociation;
    @autoreleasepool {
        NSObject *owner = [NSObject new], *value = [NSObject new]; weakAssociation = value;
        objc_setAssociatedObject(owner, key(), value, OBJC_ASSOCIATION_RETAIN);
    }
    check(weakAssociation == nil, "normal owner destruction releases association");

    // Ordinary, sound alloc/dealloc: retain numeric observations, never cast back.
    NSMutableDictionary *addresses = [NSMutableDictionary new];
    NSMapTable *history = [NSMapTable strongToWeakObjectsMapTable];
    FakeView *sameParent = [FakeView new]; BOOL reused = NO;
    for (NSUInteger i = 0; i < 20000 && !reused; i++) @autoreleasepool {
        FakeView *node = [FakeView new]; node.parent = sameParent; node.window = sameParent;
        NSNumber *address = @((uintptr_t)(__bridge void *)node);
        NSString *prior = addresses[address];
        if (prior) {
            check([history objectForKey:prior] == nil, "observed same-address replacement cannot resolve old token");
            check(objc_getAssociatedObject(node, key()) == nil, "same-address replacement has no old association");
            printf("REUSE address=0x%llx allocation=%lu class=FakeView sameParent=true hidden=false alpha=1\n", address.unsignedLongLongValue, (unsigned long)i + 1);
            reused = YES;
        }
        NSString *token = NSUUID.UUID.UUIDString;
        [history setObject:node forKey:token]; addresses[address] = token;
        objc_setAssociatedObject(node, key(), @"old-lifetime", OBJC_ASSOCIATION_RETAIN);
    }
    printf("REUSE_SUMMARY observed=%s allocationLimit=20000 deterministicConstructDestruct=not_exercised\n", reused ? "true" : "false");
}
static void modules(void) {
    Class anchor = objc_getClass("NSObject");
    const void *third = sel_registerName("org.oozoofrog.macCu.lifetimeHarness.thirdParty");
    objc_setAssociatedObject(anchor, third, @"keep", OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(anchor, key(), @{@"schema":@1, @"owner":@"lifetime-harness", @"map":[NSMapTable strongToWeakObjectsMapTable]}, OBJC_ASSOCIATION_RETAIN);
    uintptr_t first = 0;
    for (int i = 0; i < 2; i++) @autoreleasepool {
        NSString *path = [NSString stringWithFormat:@"%s/module%d.dylib", getenv("LIFETIME_MODULE_DIR"), i];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) fprintf(stderr, "dlopen: %s\n", dlerror());
        check(handle != NULL, "dlopen independently compiled module");
        uintptr_t (*getKey)(void) = dlsym(handle, "registry_key");
        int (*visit)(int) = dlsym(handle, "registry_visit");
        check(getKey && visit, "module exports");
        uintptr_t current = getKey(); if (!i) first = current;
        check(current == first && current == (uintptr_t)key(), "process registered selector identity stable");
        check(visit(i == 0) == 0, "Foundation state shared across modules");
        if (i == 1) {
            objc_setAssociatedObject(anchor, key(), @"foreign", OBJC_ASSOCIATION_RETAIN);
            check(visit(1) == 2, "foreign shape collision refused");
            check([objc_getAssociatedObject(anchor, key()) isEqual:@"foreign"], "collision not overwritten");
            objc_setAssociatedObject(anchor, key(), @{@"schema":@2, @"owner":@"lifetime-harness", @"map":[NSMapTable strongToWeakObjectsMapTable]}, OBJC_ASSOCIATION_RETAIN);
            check(visit(1) == 2, "schema collision refused");
            objc_setAssociatedObject(anchor, key(), @{@"schema":@1, @"owner":@"another", @"map":[NSMapTable strongToWeakObjectsMapTable]}, OBJC_ASSOCIATION_RETAIN);
            check(visit(1) == 3, "owner collision refused");
        }
        getKey = NULL; visit = NULL;
        check(dlclose(handle) == 0, "dlclose module");
        check(dlopen(path.fileSystemRepresentation, RTLD_NOLOAD | RTLD_NOW) == NULL, "module actually unloaded");
        check(objc_getAssociatedObject(anchor, key()) != nil, "state survives code module unload");
    }
    objc_setAssociatedObject(anchor, key(), nil, OBJC_ASSOCIATION_RETAIN);
    check([objc_getAssociatedObject(anchor, third) isEqual:@"keep"], "anchor cleanup preserves third party");
    objc_setAssociatedObject(anchor, third, nil, OBJC_ASSOCIATION_RETAIN);
}
static void operations(void) {
    FakeView *node; OperationDriver *d = fixture(&node);
    NSData *json = [@"[true, false, 1, 0, 0.5, \"true\", null]" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *values = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    check(status(edit(d,@"badBool",1,@"hidden",@NO,values[2]),@"type"), "hidden rejects JSON numeric one");
    check(status(edit(d,@"badAlpha",1,@"alpha",@1,values[0]),@"type"), "alpha rejects JSON Boolean");
    for (id bad in @[@(NAN), @(INFINITY), @(-0.1), @1.1, values[5], values[6]])
        check(status(edit(d,@"bad",1,@"alpha",@1,bad),@"type"), "alpha rejects nonfinite/range/string/null");
    check(status(edit(d,@"skip",1,@"alpha",@1,@1),@"noChange") && node.setters == 0, "no-change skips setter");
    NSDictionary *applied = edit(d,@"a",2,@"alpha",@1,@0.5);
    check(status(applied,@"applied") && node.setters == 1, "one setter and exact readback");
    check([edit(d,@"a",2,@"alpha",@1,@0.5) isEqual:applied] && node.setters == 1, "duplicate operation reuses result");
    check(status(edit(d,@"a",2,@"alpha",@1,@0),@"payloadConflict"), "duplicate payload conflict");
    node.alpha = 0.75;
    check(status([d revert:applied[@"undo"] operation:@"revertConflict" sequence:3],@"valueConflict") && node.setters == 1, "guarded revert refuses changed value");
    node.alpha = 0.5;
    check(status([d revert:applied[@"undo"] operation:@"revert" sequence:3],@"applied") && node.alpha == 1, "guarded revert applies original");
    check(status([d revert:applied[@"undo"] operation:@"again" sequence:4],@"undoUnavailable"), "undo consumed");
    [d.journal removeAllObjects];
    check(status(edit(d,@"evicted",2,@"alpha",@1,@0),@"resultUnavailable"), "eviction preserves stale sequence fence");
    for (NSNumber *value in @[@0, @0.5, @1]) {
        d = fixture(&node); check(status(edit(d,@"boundary",1,@"alpha",@1,value), value.doubleValue == 1 ? @"noChange" : @"applied"), "alpha boundaries and exact 0.5");
    }
    d = fixture(&node);
    check(status(edit(d,@"bool",1,@"hidden",values[1],values[0]),@"applied") && node.hidden, "JSON Boolean setter");
    d = fixture(&node);
    check(status([d request:@"expiry" sequence:1 property:@"alpha" expected:@1 value:@0 generation:d.generation token:@"node" parent:@"parent" window:@"window" klass:@"FakeView" now:120],@"expired"), "capture expiry boundary");
    for (NSString *part in @[@"generation",@"token",@"parent",@"window",@"class"]) {
        d = fixture(&node);
        check(status([d request:@"identity" sequence:1 property:@"alpha" expected:@1 value:@0
                    generation:[part isEqual:@"generation"] ? @"old" : d.generation
                    token:[part isEqual:@"token"] ? @"missing" : @"node" parent:[part isEqual:@"parent"] ? @"missing" : @"parent"
                    window:[part isEqual:@"window"] ? @"missing" : @"window" klass:[part isEqual:@"class"] ? @"NSObject" : @"FakeView" now:1], [part isEqual:@"generation"] ? @"generation" : @"identity") && node.setters == 0, "generation/token/parent/window/class admission");
    }
    d = fixture(&node); [node.parent.children removeObjectIdenticalTo:node];
    check(status(edit(d,@"detach",1,@"alpha",@1,@0),@"identity") && node.setters == 0, "still-live detached view refused");
    d = fixture(&node); node.parent = d.root;
    check(status(edit(d,@"reparent",1,@"alpha",@1,@0),@"identity"), "still-live reparented view refused");
    for (NSString *behavior in @[@"throwBefore", @"throwAfter", @"mismatch", @"detach"]) {
        d = fixture(&node); node.behavior = behavior;
        NSDictionary *r = edit(d,@"uncertain",1,@"alpha",@1,@0);
        check(status(r,@"uncertain") && [r[@"entered"] boolValue] && node.setters == 1, "throw/readback/detach after setter entry is uncertain");
        check(status(edit(d,@"uncertain",1,@"alpha",@1,@0),@"uncertain") && node.setters == 1, "ambiguous duplicate never retries");
        check(status(edit(d,@"newAttempt",2,@"alpha",@(node.alpha),@1),@"quarantined") && node.setters == 1, "new operation cannot retry quarantined capture");
    }
    d = fixture(&node); __weak OperationDriver *weakDriver = d;
    __block NSDictionary *reentrant;
    node.hook = ^{ OperationDriver *driver = weakDriver; reentrant = edit(driver,@"inner",2,@"alpha",@0,@1); };
    check(status(edit(d,@"outer",1,@"alpha",@1,@0),@"applied") && status(reentrant,@"busy") && node.setters == 1, "reentrant setter admission blocked");
    node.hook = nil;
    // A durable host reservation/lost response is modeled explicitly, not implemented.
    d.quarantined = YES;
    check(status(edit(d,@"lostResponse",3,@"alpha",@0,@1),@"quarantined"), "simulated lost response blocks new dispatch");
    [d releaseCapture]; [d releaseCapture];
    check(d.map == nil && d.undo.count == 0 && d.released, "capture release idempotent");
}
int main(int argc, const char *argv[]) {
    // Match native-selfcheck-entry semantics BEFORE autorelease/Foundation test work.
    if (argc != 2 || strcmp(argv[1], "--native-check") != 0 || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1);
    @autoreleasepool {
        lifetime(); modules(); operations();
        printf("SUMMARY checks=%lu failed=0 FoundationOnly=true\n", (unsigned long)checks);
    }
    return 0;
}
