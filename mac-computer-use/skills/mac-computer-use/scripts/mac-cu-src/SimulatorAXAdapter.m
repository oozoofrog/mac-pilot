#import "SimulatorAXAdapter.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <math.h>

// Test class remapping is compile-time only and absent from the production binary.
#ifdef SAX_ADAPTER_TESTING
#define T "SAXFakeTranslator"
#define O "SAXFakeTranslation"
#define E "SAXFakeElement"
#define BASE "SAXFakeBase"
#else
#define T "AXPTranslator"
#define O "AXPTranslationObject"
#define E "AXPMacPlatformElement"
#define BASE "NSAccessibilityElement"
#endif

typedef struct { const char *root, *selector, *owner, *encoding; } Spec;
static const Spec specs[] = {
    {T, "frontmostApplicationWithDisplayId:bridgeDelegateToken:", T, "@28@0:8I16@20"},
    {T, "macPlatformElementFromTranslation:", T, "@24@0:8@16"},
    {T, "objectAtPoint:displayId:bridgeDelegateToken:", T, "@44@0:8{CGPoint=dd}16I32@36"},
    {T, "setBridgeTokenDelegate:", T, "v24@0:8@16"},
    {O, "bridgeDelegateToken", O, "@16@0:8"},
    {O, "setBridgeDelegateToken:", O, "v24@0:8@16"},
    {O, "pid", O, "i16@0:8"},
    {O, "objectID", O, "Q16@0:8"},
    {E, "translation", E, "@16@0:8"},
    {E, "accessibilityChildren", BASE, "@16@0:8"},
    {E, "accessibilityParent", E, "@16@0:8"},
    {E, "accessibilityRole", E, "@16@0:8"},
    {E, "accessibilitySubrole", BASE, "@16@0:8"},
    {E, "accessibilityRoleDescription", BASE, "@16@0:8"},
    {E, "accessibilityTitle", BASE, "@16@0:8"},
    {E, "accessibilityLabel", E, "@16@0:8"},
    {E, "accessibilityIdentifier", BASE, "@16@0:8"},
    {E, "accessibilityValue", BASE, "@16@0:8"},
    {E, "accessibilityHelp", BASE, "@16@0:8"},
    {E, "isAccessibilityEnabled", E, "B16@0:8"},
    {E, "accessibilityFrame", E, "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"},
    {E, "accessibilityActivationPoint", E, "{CGPoint=dd}16@0:8"},
    {E, "accessibilityActionNames", E, "@16@0:8"},
    {E, "accessibilityPerformPress", E, "B16@0:8"},
    {E, "performIncrementAction", E, "v16@0:8"},
    {E, "performDecrementAction", E, "v16@0:8"},
    {E, "performEscapeAction", E, "v16@0:8"},
    {E, "accessibilityPerformAction:", E, "v24@0:8@16"},
    {E, "accessibilityCustomActions", E, "@16@0:8"},
    {E, "accessibilityIsAttributeSettable:", E, "B24@0:8@16"},
    {E, "accessibilitySetValue:forAttribute:", E, "v32@0:8@16@24"},
    {E, "accessibilityAttributeNames", E, "@16@0:8"},
    {E, "accessibilityAttributeValue:", E, "@24@0:8@16"},
    {E, "isAccessibilityProtectedContent", BASE, "B16@0:8"},
    {"NSAccessibilityCustomAction", "name", "NSAccessibilityCustomAction", "@16@0:8"},
    {"NSAccessibilityCustomAction", "target", "NSAccessibilityCustomAction", "@16@0:8"},
    {"NSAccessibilityCustomAction", "selector", "NSAccessibilityCustomAction", ":16@0:8"},
    {"NSAccessibilityCustomAction", "handler", "NSAccessibilityCustomAction", "@?16@0:8"},
};

@interface SAXResult ()
@property(nonatomic) SAXStatus status;
@property(nonatomic, nullable, strong) id objectValue;
@property(nonatomic) SAXMutationOutcome mutationOutcome;
@property(nonatomic) BOOL setterEntered;
@property(nonatomic, copy) NSString *diagnostic;
@end
@implementation SAXResult
@end
static SAXResult *result(SAXStatus status, id value, NSString *diagnostic) {
    SAXResult *r = [SAXResult new]; r.status = status; r.objectValue = value;
    r.diagnostic = diagnostic ?: @""; return r;
}
static BOOL lineage(id object, const char *name) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c))
        if (!strcmp(class_getName(c), name)) return YES;
    return NO;
}
static Method defining(Class cls, SEL selector, Class *owner) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned count = 0; Method *methods = class_copyMethodList(c, &count);
        Method found = NULL;
        for (unsigned i = 0; i < count; ++i) if (method_getName(methods[i]) == selector) { found = methods[i]; break; }
        free(methods);
        if (found) { *owner = c; return found; }
    }
    return NULL; // Never resolve a forwarding IMP.
}
static BOOL sameType(const char *actual, const char *expected) {
    if (strcmp(actual, expected)) return NO; // Reject qualifiers/aliases as well as kind changes.
    if (!strcmp(actual, "v")) return YES;
    NSUInteger aSize = 0, aAlign = 0, eSize = 0, eAlign = 0;
    NSGetSizeAndAlignment(actual, &aSize, &aAlign);
    NSGetSizeAndAlignment(expected, &eSize, &eAlign);
    return aSize == eSize && aAlign == eAlign;
}
static BOOL compatible(Method method, const char *encoding) {
    NSMethodSignature *expected = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (method_getNumberOfArguments(method) != expected.numberOfArguments) return NO;
    char *ret = method_copyReturnType(method);
    BOOL valid = sameType(ret, expected.methodReturnType); free(ret);
    for (unsigned i = 0; valid && i < expected.numberOfArguments; ++i) {
        char *arg = method_copyArgumentType(method, i);
        valid = sameType(arg, [expected getArgumentTypeAtIndex:i]); free(arg);
    }
    return valid;
}
#ifdef SAX_ADAPTER_TESTING
BOOL SAXTestCompatible(Method method, const char *encoding) { return compatible(method, encoding); }
#endif
static IMP checked(id object, const char *root, const char *name, SAXResult **error) {
#if !defined(__arm64__)
    *error = result(SAXUnsupportedABI, nil, @"Installed profile qualified only for arm64"); return NULL;
#endif
    const Spec *spec = NULL;
    for (size_t i = 0; i < sizeof(specs)/sizeof(specs[0]); ++i)
        if (!strcmp(specs[i].root, root) && !strcmp(specs[i].selector, name)) { spec = &specs[i]; break; }
    if (!spec || !lineage(object, root)) {
        *error = result(SAXUnsupportedABI, nil, @"Unqualified receiver lineage"); return NULL;
    }
    Class owner = Nil; Method method = defining(object_getClass(object), sel_registerName(name), &owner);
    if (!method) { *error = result(SAXUnsupportedSelector, nil, @(name)); return NULL; }
    NSString *raw = [NSString stringWithFormat:@"%s owner=%s encoding=%s expected=%s", name,
                     class_getName(owner), method_getTypeEncoding(method), spec->encoding];
    if (strcmp(class_getName(owner), spec->owner) || !compatible(method, spec->encoding)) {
        *error = result(SAXUnsupportedABI, nil, raw); return NULL;
    }
    return method_getImplementation(method);
}
#define CHECK(obj, root, name) checked(obj, root, name, &error)
#define SELN(name) sel_registerName(name)
static id object0(id object, const char *root, const char *name, SAXResult **error) {
    IMP imp = checked(object, root, name, error);
    return imp ? ((id (*)(id, SEL))imp)(object, SELN(name)) : nil;
}
static SAXResult *exceptionResult(NSException *exception, BOOL entered, BOOL setter) {
    // Do not include exception reason/userInfo: a private getter may embed protected values.
    SAXResult *r = result(SAXException, nil, [NSString stringWithFormat:@"NSException %@; invalidate session", exception.name]);
    r.mutationOutcome = entered ? SAXUncertain : SAXNotEntered; r.setterEntered = setter; return r;
}
static SAXResult *validated(id value, const char *kind) {
    if (!value) return result(SAXNil, nil, nil);
    if (!strcmp(kind, "value")) {
        if ([value isKindOfClass:NSString.class]) {
            if ([value length] > 65536) return result(SAXLimitExceeded, nil, @"String exceeds bound");
            return result(SAXOK, [value copy], nil);
        }
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) return result(SAXOK, [value copy], nil);
        return result(SAXInvalidResult, nil, @"Expected finite typed scalar");
    }
    if (!strcmp(kind, "strings") || !strcmp(kind, "elements") || !strcmp(kind, "actions")) {
        if (![value isKindOfClass:NSArray.class]) return result(SAXInvalidResult, nil, @"Expected array");
        NSArray *array = value;
        if (array.count > 1024) return result(SAXLimitExceeded, nil, @"Collection exceeds bound");
        NSMutableArray *copy = [NSMutableArray new];
        for (id item in array) {
            BOOL valid = !strcmp(kind, "strings") ? [item isKindOfClass:NSString.class] :
                         lineage(item, !strcmp(kind, "elements") ? E : "NSAccessibilityCustomAction");
            if (!valid) return result(SAXInvalidResult, nil, @"Invalid collection member");
            if (!strcmp(kind, "strings")) {
                if ([item length] > 65536) return result(SAXLimitExceeded, nil, @"String exceeds bound");
                [copy addObject:[item copy]];
            } else [copy addObject:item];
        }
        return result(SAXOK, [copy copy], nil);
    }
    if (!strcmp(kind, "string")) {
        if (![value isKindOfClass:NSString.class]) return result(SAXInvalidResult, nil, @"Expected string");
        return validated(value, "value");
    }
    return lineage(value, kind) ? result(SAXOK, value, nil) : result(SAXInvalidResult, nil, @"Invalid returned class lineage");
}
static SAXResult *protectionCheck(id element, SAXProtection protection) {
    SAXResult *error = nil;
    IMP imp = CHECK(element, E, "isAccessibilityProtectedContent");
    if (!imp) return error;
    BOOL hostProtected = ((BOOL (*)(id, SEL))imp)(element, SELN("isAccessibilityProtectedContent"));
    if (hostProtected || protection != SAXProtectionClear) return result(SAXRedacted, nil, @"Protected or unknown guest protection");
    // A secure subrole overrides caller clear evidence. Getter failure cannot authorize disclosure.
    id subrole = object0(element, E, "accessibilitySubrole", &error);
    if (error) return error;
    SAXResult *r = validated(subrole, "string");
    if (r.status != SAXOK && r.status != SAXNil) return r;
    if ([subrole isEqualToString:@"AXSecureTextField"]) return result(SAXRedacted, nil, @"Secure subrole");
    return nil;
}
static SAXResult *enabledCheck(id element) {
    SAXResult *error = nil; IMP imp = CHECK(element, E, "isAccessibilityEnabled");
    if (!imp) return error;
    return ((BOOL (*)(id, SEL))imp)(element, SELN("isAccessibilityEnabled")) ? nil : result(SAXUnsupportedCapability, nil, @"Disabled element");
}
static SAXResult *advertisement(id element, const char *selector, NSString *name) {
    SAXResult *error = nil; id names = object0(element, E, selector, &error);
    if (error) return error;
    SAXResult *r = validated(names, "strings");
    if (r.status != SAXOK) return r;
    return [r.objectValue containsObject:name] ? nil : result(SAXUnsupportedCapability, nil, @"Not currently advertised");
}
static SAXResult *settable(id element, SAXProtection protection) {
    SAXResult *r = protectionCheck(element, protection); if (r) return r;
    r = enabledCheck(element); if (r) return r;
    r = advertisement(element, "accessibilityAttributeNames", @"AXValue"); if (r) return r;
    SAXResult *error = nil; IMP imp = CHECK(element, E, "accessibilityIsAttributeSettable:"); if (!imp) return error;
    BOOL yes = ((BOOL (*)(id, SEL, id))imp)(element, SELN("accessibilityIsAttributeSettable:"), @"AXValue");
    return result(yes ? SAXOK : SAXUnsupportedCapability, @(yes), nil);
}
@implementation SimulatorAXAdapter
+ (SAXResult *)customActionName:(NSAccessibilityCustomAction *)action {
    @try { SAXResult *error = nil; id name = object0(action, "NSAccessibilityCustomAction", "name", &error); return error ?: validated(name, "string"); }
    @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)sharedTranslator {
    @try {
        Class cls = NSClassFromString(@(T));
        Class owner = Nil;
        Method method = defining(object_getClass(cls), SELN("sharedInstance"), &owner);
        if (!method || owner != object_getClass(cls) || !compatible(method, "@16@0:8"))
            return result(SAXUnsupportedABI, nil, @"Unqualified singleton ABI");
        return validated(((id (*)(id, SEL))method_getImplementation(method))(cls, SELN("sharedInstance")), T);
    } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)sendRequest:(id)request device:(id)device queue:(dispatch_queue_t)queue completion:(void (^)(id))completion {
    @try {
        Class owner = Nil; SEL selector = SELN("sendAccessibilityRequestAsync:completionQueue:completionHandler:");
        Method method = defining(object_getClass(device), selector, &owner);
        if (!lineage(device, "SimDevice") || !method || strcmp(class_getName(owner), "SimDevice") || !compatible(method, "v40@0:8@16@24@?32"))
            return result(SAXUnsupportedABI, nil, @"Unqualified SimDevice bridge ABI");
        ((void (*)(id, SEL, id, dispatch_queue_t, void (^)(id)))method_getImplementation(method))(device, selector, request, queue, completion);
        return result(SAXOK, nil, nil);
    } @catch (NSException *e) { return exceptionResult(e, YES, NO); }
}
+ (SAXResult *)frontApplication:(id)t display:(uint32_t)d token:(NSString *)token {
    @try {
        if (![token isKindOfClass:NSString.class] || !token.length || token.length > 65536) return result(SAXInvalidInput, nil, @"Invalid token");
        SAXResult *error = nil; const char *n = "frontmostApplicationWithDisplayId:bridgeDelegateToken:";
        IMP imp = CHECK(t, T, n); if (!imp) return error;
        return validated(((id (*)(id, SEL, uint32_t, id))imp)(t, SELN(n), d, token), O);
    } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)platformElement:(id)t translation:(id)o {
    @try {
        if (!lineage(o, O)) return result(SAXInvalidInput, nil, @"Invalid translation");
        SAXResult *error = nil; const char *n = "macPlatformElementFromTranslation:";
        IMP imp = CHECK(t, T, n); if (!imp) return error;
        return validated(((id (*)(id, SEL, id))imp)(t, SELN(n), o), E);
    } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)elementAtPoint:(CGPoint)p translator:(id)t display:(uint32_t)d token:(NSString *)token {
    @try {
        if (!isfinite(p.x) || !isfinite(p.y) || ![token isKindOfClass:NSString.class] || !token.length || token.length > 65536)
            return result(SAXInvalidInput, nil, @"Invalid point/token");
        SAXResult *error = nil; const char *n = "objectAtPoint:displayId:bridgeDelegateToken:";
        IMP imp = CHECK(t, T, n); if (!imp) return error;
        return validated(((id (*)(id, SEL, CGPoint, uint32_t, id))imp)(t, SELN(n), p, d, token), O);
    } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)installBridgeDelegate:(id)delegate translator:(id)t {
    BOOL entered = NO;
    @try {
        SAXResult *error = nil; const char *n = "setBridgeTokenDelegate:";
        IMP imp = CHECK(t, T, n); if (!imp) return error;
        entered = YES; ((void (*)(id, SEL, id))imp)(t, SELN(n), delegate);
        SAXResult *r = result(SAXOK, nil, nil); r.mutationOutcome = SAXDispatched; return r;
    } @catch (NSException *e) { return exceptionResult(e, entered, NO); }
}
+ (SAXResult *)setToken:(NSString *)token translation:(id)o {
    BOOL entered = NO;
    @try {
        if (![token isKindOfClass:NSString.class] || !token.length || token.length > 65536) return result(SAXInvalidInput, nil, @"Invalid token");
        SAXResult *error = nil; const char *n = "setBridgeDelegateToken:";
        IMP imp = CHECK(o, O, n); if (!imp) return error;
        entered = YES; ((void (*)(id, SEL, id))imp)(o, SELN(n), token);
        SAXResult *r = result(SAXOK, nil, nil); r.mutationOutcome = SAXDispatched; return r;
    } @catch (NSException *e) { return exceptionResult(e, entered, NO); }
}
+ (SAXResult *)token:(id)o {
    @try { SAXResult *e = nil; id value = object0(o, O, "bridgeDelegateToken", &e); return e ?: validated(value, "string"); }
    @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)pid:(id)o {
    @try { SAXResult *error = nil; IMP imp = CHECK(o, O, "pid"); if (!imp) return error;
        return result(SAXOK, @(((int32_t (*)(id, SEL))imp)(o, @selector(pid))), nil); }
    @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)objectID:(id)o {
    @try { SAXResult *error = nil; IMP imp = CHECK(o, O, "objectID"); if (!imp) return error;
        return result(SAXOK, @(((uint64_t (*)(id, SEL))imp)(o, @selector(objectID))), nil); }
    @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)read:(SAXField)field element:(id)element protection:(SAXProtection)protection {
    @try {
        static const char *names[] = {"accessibilityChildren", "accessibilityParent", "accessibilityRole", "accessibilitySubrole",
            "accessibilityRoleDescription", "accessibilityTitle", "accessibilityLabel", "accessibilityIdentifier", "accessibilityValue",
            "accessibilityHelp", "isAccessibilityEnabled", "accessibilityFrame", "accessibilityActivationPoint", "accessibilityActionNames",
            "accessibilityCustomActions", "isAccessibilityProtectedContent", "accessibilityAttributeNames", "translation"};
        static const char *kinds[] = {"elements", E, "string", "string", "string", "string", "string", "string", "value",
            "string", "", "", "", "strings", "actions", "", "strings", O};
        if (field < SAXChildren || field > SAXSelectedTextRange) return result(SAXInvalidInput, nil, @"Invalid field");
        if (field == SAXFocused || field == SAXSelectedTextRange) {
            SAXResult *error = nil; const char *n = "accessibilityAttributeValue:";
            IMP imp = CHECK(element, E, n); if (!imp) return error;
            id value = ((id (*)(id, SEL, id))imp)(element, SELN(n), field == SAXFocused ? @"AXFocused" : @"AXSelectedTextRange");
            if (!value) return result(SAXNil, nil, nil);
            if (field == SAXFocused) return [value isKindOfClass:NSNumber.class] ? result(SAXOK, @([value boolValue]), nil) : result(SAXInvalidResult, nil, nil);
            if (![value isKindOfClass:NSValue.class] || strcmp([value objCType], @encode(NSRange))) return result(SAXInvalidResult, nil, @"Expected NSRange");
            return result(SAXOK, [value copy], nil);
        }
        if (field == SAXValue) { SAXResult *r = protectionCheck(element, protection); if (r) return r; }
        SAXResult *error = nil; const char *n = names[field]; IMP imp = CHECK(element, E, n); if (!imp) return error;
        if (field == SAXEnabled || field == SAXProtectedContent) return result(SAXOK, @(((BOOL (*)(id, SEL))imp)(element, SELN(n))), nil);
        if (field == SAXFrame) {
            CGRect rect = ((CGRect (*)(id, SEL))imp)(element, SELN(n));
            if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(rect.size.width) || !isfinite(rect.size.height)) return result(SAXInvalidResult, nil, @"Nonfinite frame");
            return result(SAXOK, [NSValue valueWithRect:rect], nil);
        }
        if (field == SAXActivationPoint) {
            CGPoint point = ((CGPoint (*)(id, SEL))imp)(element, SELN(n));
            if (!isfinite(point.x) || !isfinite(point.y)) return result(SAXInvalidResult, nil, @"Nonfinite point");
            return result(SAXOK, [NSValue valueWithPoint:point], nil);
        }
        return validated(((id (*)(id, SEL))imp)(element, SELN(n)), kinds[field]);
    } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)valueSettable:(id)e protection:(SAXProtection)p {
    @try { return settable(e, p); } @catch (NSException *e) { return exceptionResult(e, NO, NO); }
}
+ (SAXResult *)dispatch:(SAXAction)action element:(id)element qualified:(BOOL)qualified {
    BOOL entered = NO;
    @try {
        if (!qualified) return result(SAXUnsupportedCapability, nil, @"Guest behavior unqualified");
        static const char *names[] = {"accessibilityPerformPress", "performIncrementAction", "performDecrementAction", "performEscapeAction"};
        static NSString *const ads[] = {@"AXPress", @"AXIncrement", @"AXDecrement", @"AXCancel"};
        if (action < SAXPress || action > SAXEscape) return result(SAXInvalidInput, nil, @"Invalid action");
        SAXResult *r = enabledCheck(element); if (r) return r;
        r = advertisement(element, "accessibilityActionNames", ads[action]); if (r) return r;
        SAXResult *error = nil; IMP imp = CHECK(element, E, names[action]); if (!imp) return error;
        entered = YES;
        BOOL accepted = YES;
        if (action == SAXPress) accepted = ((BOOL (*)(id, SEL))imp)(element, SELN(names[action]));
        else ((void (*)(id, SEL))imp)(element, SELN(names[action]));
        r = result(SAXOK, action == SAXPress ? @(accepted) : nil, nil);
        r.mutationOutcome = accepted ? SAXDispatched : SAXRejected; return r;
    } @catch (NSException *e) { return exceptionResult(e, entered, NO); }
}
+ (SAXResult *)setValue:(id)value element:(id)element protection:(SAXProtection)p qualified:(BOOL)qualified {
    BOOL entered = NO;
    @try {
        if (!qualified) return result(SAXUnsupportedCapability, nil, @"Guest setter unqualified");
        SAXResult *v = validated(value, "value"); if (v.status != SAXOK) return result(SAXInvalidInput, nil, @"Unsupported value");
        SAXResult *r = settable(element, p); if (r.status != SAXOK) return r;
        SAXResult *error = nil; const char *n = "accessibilitySetValue:forAttribute:"; IMP imp = CHECK(element, E, n); if (!imp) return error;
        entered = YES; ((void (*)(id, SEL, id, id))imp)(element, SELN(n), v.objectValue, @"AXValue");
        r = result(SAXOK, nil, nil); r.setterEntered = YES; r.mutationOutcome = SAXDispatched; return r;
    } @catch (NSException *e) { return exceptionResult(e, entered, entered); }
}
+ (SAXResult *)invokeCustomAction:(NSAccessibilityCustomAction *)suppliedAction element:(id)element qualified:(BOOL)qualified {
    __attribute__((objc_precise_lifetime)) NSAccessibilityCustomAction *action = suppliedAction;
    BOOL entered = NO;
    @try {
        if (!qualified || !lineage(action, "NSAccessibilityCustomAction")) return result(SAXUnsupportedCapability, nil, @"Unqualified custom action");
        SAXResult *r = enabledCheck(element); if (r) return r;
        SAXResult *error = nil; id actions = object0(element, E, "accessibilityCustomActions", &error); if (error) return error;
        r = validated(actions, "actions"); if (r.status != SAXOK) return r;
        if ([r.objectValue indexOfObjectIdenticalTo:action] == NSNotFound) return result(SAXUnsupportedCapability, nil, @"Action absent from current element");
        // All action accessors must be system-defined, including block's @? encoding.
        const char *accessors[] = {"name", "handler", "target", "selector"};
        for (unsigned i = 0; i < 4; ++i) if (!CHECK(action, "NSAccessibilityCustomAction", accessors[i])) return error;
        if (validated(action.name, "string").status != SAXOK) return result(SAXInvalidResult, nil, @"Invalid action name");
        BOOL (^handler)(void) = [action.handler copy]; // AppKit header contract; not a caller block.
        BOOL accepted = NO;
        if (handler) { entered = YES; accepted = handler(); }
        else {
            __attribute__((objc_precise_lifetime)) id target = action.target; SEL selector = action.selector; // strong local promotes weak target
            if (!target || !selector) return result(SAXUnsupportedCapability, nil, @"Expired target");
            Class owner = Nil; Method method = defining(object_getClass(target), selector, &owner);
            if (!method) return result(SAXUnsupportedSelector, nil, @"Forwarding target rejected");
            BOOL zero = compatible(method, "B16@0:8"), one = compatible(method, "B24@0:8@16");
            if (!zero && !one) return result(SAXUnsupportedABI, nil, @(method_getTypeEncoding(method)));
            IMP imp = method_getImplementation(method);
            entered = YES;
            accepted = zero ? ((BOOL (*)(id, SEL))imp)(target, selector) : ((BOOL (*)(id, SEL, id))imp)(target, selector, action);
        }
        r = result(SAXOK, @(accepted), nil); r.mutationOutcome = accepted ? SAXDispatched : SAXRejected; return r;
    } @catch (NSException *e) { return exceptionResult(e, entered, NO); }
}
@end
