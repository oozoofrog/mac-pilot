#include <objc/runtime.h>
#include <objc/message.h>
#include <stdint.h>

// Pure C runtime shim: no Objective-C image metadata or persistent callbacks.
// All state is Foundation-owned, installed by the ARC CLI before loading us.
static const void *key(void) {
    return (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1");
}
static id string(const char *text) {
    return ((id (*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), text);
}
static id field(id state, const char *name) {
    return ((id (*)(id, SEL, id))objc_msgSend)(state, sel_registerName("objectForKey:"), string(name));
}
static int kind(id object, const char *name) {
    return ((BOOL (*)(id, SEL, Class))objc_msgSend)(object, sel_registerName("isKindOfClass:"), objc_getClass(name));
}
__attribute__((visibility("default"))) uintptr_t registry_key(void) { return (uintptr_t)key(); }
__attribute__((visibility("default"))) int registry_visit(int unused) {
    (void)unused;
    id state = objc_getAssociatedObject((id)objc_getClass("NSObject"), key());
    if (!state) return 1;
    if (!kind(state, "NSDictionary")) return 2;
    id schema = field(state, "schema");
    if (!kind(schema, "NSNumber") || ((int (*)(id, SEL))objc_msgSend)(schema, sel_registerName("intValue")) != 1
        || !kind(field(state, "map"), "NSMapTable")) return 2;
    if (!((BOOL (*)(id, SEL, id))objc_msgSend)(field(state, "owner"), sel_registerName("isEqual:"), string("lifetime-harness"))) return 3;
    return 0;
}
