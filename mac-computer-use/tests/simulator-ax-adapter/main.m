#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "SimulatorAXAdapter.h"
#include <stdlib.h>

extern BOOL SAXTestCompatible(Method method, const char *encoding);
static NSUInteger assertions, calls, valueReads, setterCalls;
static void expect(BOOL condition, const char *message) {
    ++assertions; if (!condition) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}
static void boom(void) { @throw [NSException exceptionWithName:@"FakeFailure" reason:@"sensitive reason" userInfo:nil]; }
@interface SAXFakeTranslation : NSObject
@property(nonatomic, copy) NSString *bridgeDelegateToken;
- (int32_t)pid;
- (uint64_t)objectID;
@end
@implementation SAXFakeTranslation
- (int32_t)pid { return -17; }
- (uint64_t)objectID { return UINT64_MAX - 7; }
@end
@interface SAXFakeBase : NSObject
@property(nonatomic, strong) id payload;
@property(nonatomic) BOOL secure, secureSubrole;
- (id)accessibilitySubrole;
- (id)accessibilityValue;
- (BOOL)isAccessibilityProtectedContent;
- (id)accessibilityChildren;
@end
@implementation SAXFakeBase
- (id)accessibilitySubrole { return (self.secure || self.secureSubrole) ? @"AXSecureTextField" : @""; }
- (id)accessibilityValue { ++valueReads; return self.payload; }
- (BOOL)isAccessibilityProtectedContent { return self.secure; }
- (id)accessibilityChildren { return self.payload; }
@end
@interface SAXFakeElement : SAXFakeBase
@property(nonatomic) BOOL enabled, settable, throwBefore, throwAfter, pressAnswer;
@property(nonatomic, strong) NSArray *ads, *custom;
- (id)accessibilityActionNames;
- (id)accessibilityAttributeNames;
- (BOOL)isAccessibilityEnabled;
- (BOOL)accessibilityIsAttributeSettable:(id)attribute;
- (void)accessibilitySetValue:(id)value forAttribute:(id)attribute;
- (BOOL)accessibilityPerformPress;
- (void)performIncrementAction;
- (void)performDecrementAction;
- (void)performEscapeAction;
- (CGRect)accessibilityFrame;
- (CGPoint)accessibilityActivationPoint;
- (id)accessibilityCustomActions;
@end
@implementation SAXFakeElement
- (id)accessibilityActionNames { if (self.throwBefore) boom(); return self.ads; }
- (id)accessibilityAttributeNames { if (self.throwBefore) boom(); return self.ads; }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
- (BOOL)accessibilityIsAttributeSettable:(id)a { expect([a isEqual:@"AXValue"], "settable AXValue"); return self.settable; }
- (void)accessibilitySetValue:(id)v forAttribute:(id)a { ++setterCalls; expect([a isEqual:@"AXValue"], "value-first attribute-second"); self.payload = v; if (self.throwAfter) boom(); }
- (BOOL)accessibilityPerformPress { ++calls; if (self.throwAfter) boom(); return self.pressAnswer; }
- (void)performIncrementAction { ++calls; }
- (void)performDecrementAction { ++calls; }
- (void)performEscapeAction { ++calls; }
- (CGRect)accessibilityFrame { ++calls; return CGRectMake(1,2,3,4); }
- (CGPoint)accessibilityActivationPoint { return CGPointMake(5,6); }
- (id)accessibilityCustomActions { return self.custom; }
@end
@interface SAXFakeTranslator : NSObject
@property(nonatomic, strong) id answer;
- (id)frontmostApplicationWithDisplayId:(uint32_t)d bridgeDelegateToken:(id)t;
- (id)macPlatformElementFromTranslation:(id)t;
- (id)objectAtPoint:(CGPoint)p displayId:(uint32_t)d bridgeDelegateToken:(id)t;
- (void)setBridgeTokenDelegate:(id)d;
@end
@implementation SAXFakeTranslator
- (id)frontmostApplicationWithDisplayId:(uint32_t)d bridgeDelegateToken:(id)t { expect(d == UINT32_MAX && [t isEqual:@"token"], "front widths"); return self.answer; }
- (id)macPlatformElementFromTranslation:(id)t { expect([t isKindOfClass:SAXFakeTranslation.class], "translation argument"); return self.answer; }
- (id)objectAtPoint:(CGPoint)p displayId:(uint32_t)d bridgeDelegateToken:(id)t { expect(CGPointEqualToPoint(p, CGPointMake(7,8)) && d == UINT32_MAX && [t isEqual:@"token"], "point ABI"); return self.answer; }
- (void)setBridgeTokenDelegate:(id)d { (void)d; ++calls; }
@end
@interface CustomTarget : NSObject
- (BOOL)zero;
- (BOOL)one:(id)action;
- (void)wrong;
@end
@implementation CustomTarget
- (BOOL)zero { ++calls; return YES; }
- (BOOL)one:(id)action { expect([action isKindOfClass:NSAccessibilityCustomAction.class], "custom action object"); ++calls; return NO; }
- (void)wrong { ++calls; }
@end
@interface UnqualifiedSubclass : SAXFakeElement
@end
@implementation UnqualifiedSubclass
- (BOOL)accessibilityPerformPress { ++calls; return YES; }
@end
static void mismatches(SAXFakeElement *e, SEL selector, SAXField field, const char *wrong) {
    Method m = class_getInstanceMethod(SAXFakeElement.class, selector);
    IMP imp = method_getImplementation(m); char *original = strdup(method_getTypeEncoding(m));
    // Replacement cannot update an existing encoding. Remove via a fresh dynamic subclass instead.
    static unsigned serial;
    NSString *name = [NSString stringWithFormat:@"Mismatch%u", ++serial];
    Class c = objc_allocateClassPair(SAXFakeElement.class, name.UTF8String, 0);
    class_addMethod(c, selector, imp, wrong); objc_registerClassPair(c);
    id other = [c new]; NSUInteger before = calls;
    SAXResult *r = [SimulatorAXAdapter read:field element:other protection:SAXProtectionClear];
    expect(r.status == SAXUnsupportedABI && calls == before, "ABI/owner mismatch zero calls");
    expect([r.diagnostic containsString:@"encoding="], "raw encoding preserved");
    free(original); (void)e;
}
int main(int argc, const char **argv) {
    // CLI-only selfcheck semantics, before any AppKit application construction.
    if (argc != 2 || strcmp(argv[1], "--native-check") || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1);
    @autoreleasepool {
        expect(SAXTestCompatible(class_getInstanceMethod(SAXFakeElement.class, @selector(accessibilityFrame)), "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"), "parsed CGRect ABI");
        expect(!SAXTestCompatible(class_getInstanceMethod(SAXFakeElement.class, @selector(accessibilityFrame)), "@16@0:8"), "struct versus object rejected");
        expect(!SAXTestCompatible(class_getInstanceMethod(SAXFakeElement.class, @selector(performIncrementAction)), "B16@0:8"), "void versus BOOL rejected");
        expect(!SAXTestCompatible(class_getInstanceMethod(SAXFakeElement.class, @selector(accessibilitySetValue:forAttribute:)), "v24@0:8@16"), "argument count rejected");
        expect(!SAXTestCompatible(class_getInstanceMethod(SAXFakeTranslation.class, @selector(pid)), "Q16@0:8"), "integer width rejected");
        SAXFakeElement *e = [SAXFakeElement new]; e.enabled = YES; e.settable = YES; e.pressAnswer = YES;
        e.ads = @[@"AXValue", @"AXPress", @"AXIncrement", @"AXDecrement", @"AXCancel"];
        SAXFakeTranslation *o = [SAXFakeTranslation new]; SAXFakeTranslator *t = [SAXFakeTranslator new]; t.answer = o;
        expect([SimulatorAXAdapter frontApplication:t display:UINT32_MAX token:@"token"].objectValue == o, "front object");
        expect([SimulatorAXAdapter elementAtPoint:CGPointMake(7,8) translator:t display:UINT32_MAX token:@"token"].objectValue == o, "point returns translation");
        expect([[SimulatorAXAdapter pid:o].objectValue intValue] == -17, "signed PID");
        expect([[SimulatorAXAdapter objectID:o].objectValue unsignedLongLongValue] == UINT64_MAX-7, "64-bit object ID");
        expect([SimulatorAXAdapter setToken:@"token" translation:o].mutationOutcome == SAXDispatched, "token void");
        expect([[SimulatorAXAdapter token:o].objectValue isEqual:@"token"], "token read");
        t.answer = e; expect([SimulatorAXAdapter platformElement:t translation:o].objectValue == e, "conversion");
        expect([SimulatorAXAdapter frontApplication:t display:UINT32_MAX token:@"token"].status == SAXInvalidResult, "wrong returned lineage");
        expect([SimulatorAXAdapter installBridgeDelegate:o translator:t].mutationOutcome == SAXDispatched, "delegate void");
        expect([SimulatorAXAdapter read:SAXRole element:e protection:SAXProtectionUnknown].status == SAXUnsupportedSelector, "absent method");
        expect([SimulatorAXAdapter read:SAXFrame element:e protection:SAXProtectionUnknown].status == SAXOK, "CGRect return");
        expect(CGPointEqualToPoint([[SimulatorAXAdapter read:SAXActivationPoint element:e protection:SAXProtectionUnknown].objectValue pointValue], CGPointMake(5,6)), "CGPoint return");
        mismatches(e, @selector(accessibilityFrame), SAXFrame, "@16@0:8");
        mismatches(e, @selector(accessibilityFrame), SAXFrame, "v16@0:8");
        e.payload = @"secret"; NSUInteger before = valueReads;
        expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionUnknown].status == SAXRedacted && valueReads == before, "unknown redacted before value read");
        e.secure = YES;
        expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].status == SAXRedacted && valueReads == before, "secure redacted");
        expect([SimulatorAXAdapter setValue:@"x" element:e protection:SAXProtectionClear qualified:YES].status == SAXRedacted && setterCalls == 0, "secure zero writes");
        e.secure = NO; e.secureSubrole = YES;
        expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].status == SAXRedacted && valueReads == before, "secure subrole overrides host clear");
        e.secureSubrole = NO;
        expect([[SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].objectValue isEqual:@"secret"], "clear typed string");
        e.payload = nil; expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].status == SAXNil, "nil value");
        e.payload = @""; expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].status == SAXOK, "empty value");
        e.payload = @[]; expect([SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear].status == SAXInvalidResult, "invalid typed value");
        e.payload = @[@"wrong"]; expect([SimulatorAXAdapter read:SAXChildren element:e protection:SAXProtectionUnknown].status == SAXInvalidResult, "invalid array member");
        NSMutableArray *oversized = [NSMutableArray new]; for (NSUInteger i = 0; i < 1025; ++i) [oversized addObject:e];
        e.payload = oversized; expect([SimulatorAXAdapter read:SAXChildren element:e protection:SAXProtectionUnknown].status == SAXLimitExceeded, "collection bound");
        e.payload = @[]; expect([SimulatorAXAdapter read:SAXChildren element:e protection:SAXProtectionUnknown].status == SAXOK, "empty array");
        before = calls;
        expect([SimulatorAXAdapter dispatch:SAXPress element:e qualified:NO].status == SAXUnsupportedCapability && calls == before, "unqualified zero dispatch");
        e.enabled = NO; expect([SimulatorAXAdapter dispatch:SAXPress element:e qualified:YES].status == SAXUnsupportedCapability && calls == before, "disabled zero dispatch"); e.enabled = YES;
        NSArray *ads = e.ads; e.ads = @[];
        expect([SimulatorAXAdapter dispatch:SAXPress element:e qualified:YES].status == SAXUnsupportedCapability && calls == before, "unadvertised zero dispatch");
        expect([SimulatorAXAdapter setValue:@"x" element:e protection:SAXProtectionClear qualified:YES].status == SAXUnsupportedCapability && setterCalls == 0, "unadvertised zero setter"); e.ads = ads;
        e.settable = NO; expect([SimulatorAXAdapter setValue:@"x" element:e protection:SAXProtectionClear qualified:YES].status == SAXUnsupportedCapability && setterCalls == 0, "not settable zero setter"); e.settable = YES;
        expect([SimulatorAXAdapter dispatch:SAXPress element:e qualified:YES].mutationOutcome == SAXDispatched && calls == before+1, "BOOL press");
        e.pressAnswer = NO; expect([SimulatorAXAdapter dispatch:SAXPress element:e qualified:YES].mutationOutcome == SAXRejected, "BOOL rejected");
        for (SAXAction a = SAXIncrement; a <= SAXEscape; ++a) expect([SimulatorAXAdapter dispatch:a element:e qualified:YES].mutationOutcome == SAXDispatched, "void dispatch");
        UnqualifiedSubclass *sub = [UnqualifiedSubclass new]; sub.enabled = YES; sub.ads = ads; before = calls;
        expect([SimulatorAXAdapter dispatch:SAXPress element:sub qualified:YES].status == SAXUnsupportedABI && calls == before, "defining owner override rejected");
        e.throwBefore = YES;
        SAXResult *r = [SimulatorAXAdapter setValue:@42 element:e protection:SAXProtectionClear qualified:YES];
        expect(r.status == SAXException && !r.setterEntered && r.mutationOutcome == SAXNotEntered && setterCalls == 0, "exception before setter");
        expect(![r.diagnostic containsString:@"sensitive"], "exception reason redacted"); e.throwBefore = NO; e.throwAfter = YES;
        r = [SimulatorAXAdapter setValue:@42 element:e protection:SAXProtectionClear qualified:YES];
        expect(r.status == SAXException && r.setterEntered && r.mutationOutcome == SAXUncertain && setterCalls == 1, "setter entry exception uncertain");
        expect([e.payload isEqual:@42], "mutation occurred before exception"); e.throwAfter = NO;
        r = [SimulatorAXAdapter setValue:@YES element:e protection:SAXProtectionClear qualified:YES];
        expect(r.setterEntered && r.mutationOutcome == SAXDispatched && setterCalls == 2, "typed boolean setter");
        before = setterCalls; expect([SimulatorAXAdapter setValue:@(NAN) element:e protection:SAXProtectionClear qualified:YES].status == SAXInvalidInput && setterCalls == before, "nonfinite rejected");
        __block NSUInteger first = 0, second = 0;
        NSAccessibilityCustomAction *a = [[NSAccessibilityCustomAction alloc] initWithName:@"same" handler:^BOOL { ++first; return YES; }];
        NSAccessibilityCustomAction *b = [[NSAccessibilityCustomAction alloc] initWithName:@"same" handler:^BOOL { ++second; return NO; }];
        e.custom = @[a,b];
        expect([SimulatorAXAdapter invokeCustomAction:b element:e qualified:YES].mutationOutcome == SAXRejected && first == 0 && second == 1, "duplicate names distinct identity");
        expect([SimulatorAXAdapter invokeCustomAction:a element:e qualified:YES].mutationOutcome == SAXDispatched && first == 1, "system block BOOL");
        e.custom = @[a]; expect([SimulatorAXAdapter invokeCustomAction:b element:e qualified:YES].status == SAXUnsupportedCapability && second == 1, "stale action zero calls");
        CustomTarget *target = [CustomTarget new];
        for (NSString *name in @[@"zero", @"one:", @"wrong", @"missing"]) {
            NSAccessibilityCustomAction *c = [[NSAccessibilityCustomAction alloc] initWithName:@"target" target:target selector:NSSelectorFromString(name)]; e.custom = @[c]; before = calls;
            r = [SimulatorAXAdapter invokeCustomAction:c element:e qualified:YES];
            if ([name isEqual:@"zero"]) expect(r.mutationOutcome == SAXDispatched && calls == before+1, "target BOOL zero args");
            else if ([name isEqual:@"one:"]) expect(r.mutationOutcome == SAXRejected && calls == before+1, "target BOOL action arg");
            else expect(r.status == ([name isEqual:@"wrong"] ? SAXUnsupportedABI : SAXUnsupportedSelector) && calls == before, "bad custom target zero calls");
        }
        NSAccessibilityCustomAction *throwing = [[NSAccessibilityCustomAction alloc] initWithName:@"throw" handler:^BOOL { boom(); return NO; }]; e.custom = @[throwing];
        expect([SimulatorAXAdapter invokeCustomAction:throwing element:e qualified:YES].mutationOutcome == SAXUncertain, "custom entered exception uncertain");
        SAXResult *held; __weak id weak;
        @autoreleasepool { NSMutableString *s = [@"owned" mutableCopy]; e.payload = s; held = [SimulatorAXAdapter read:SAXValue element:e protection:SAXProtectionClear]; weak = held.objectValue; [s appendString:@"changed"]; e.payload = nil; }
        expect(weak && [held.objectValue isEqual:@"owned"], "owned immutable result survives pool");
        __weak id retainedElement;
        @autoreleasepool { SAXFakeElement *child = [SAXFakeElement new]; retainedElement = child; e.payload = @[child]; held = [SimulatorAXAdapter read:SAXChildren element:e protection:SAXProtectionUnknown]; e.payload = nil; }
        expect(retainedElement && [held.objectValue count] == 1, "opaque array member survives pool");
        held = nil; expect(retainedElement == nil, "opaque member released with result");
        before = setterCalls; expect(before == 2 && second == 1 && first == 1, "no late retry");
        printf("PASS %lu assertions; CLI only; no AXP load or singleton\n", (unsigned long)assertions);
    }
    return 0;
}
