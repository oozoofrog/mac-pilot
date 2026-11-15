#import "Fixture.h"
// Test-only result construction. Never linked into the production executable.
SAXResult *SAXInspectionResult(SAXStatus status, id value, SAXMutationOutcome outcome) {
    SAXResult *r = [SAXResult new];
    [r setValue:@(status) forKey:@"status"];
    [r setValue:value forKey:@"objectValue"];
    [r setValue:@(outcome) forKey:@"mutationOutcome"];
    [r setValue:@"fake" forKey:@"diagnostic"];
    return r;
}
// ABI-shaped fake only. CoreSimulator is not linked or loaded.
@interface SimDevice : NSObject
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id))completion;
@end
@implementation SimDevice
- (void)sendAccessibilityRequestAsync:(id)request completionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(id))completion {
    (void)request;
    dispatch_async(queue, ^{ completion(@1); completion(@2); });
}
@end
id SAXInspectionDevice(void) { return [SimDevice new]; }
