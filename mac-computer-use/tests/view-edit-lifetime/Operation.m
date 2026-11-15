#import "Operation.h"
#import <objc/runtime.h>
#import <math.h>

@implementation FakeView
- (instancetype)init { if ((self = [super init])) { _children = [NSMutableArray new]; _alpha = 1; } return self; }
- (void)apply:(NSString *)property value:(NSNumber *)value {
    self.setters++;
    if ([self.behavior isEqual:@"throwBefore"]) @throw [NSException exceptionWithName:@"fixture" reason:@"before write" userInfo:nil];
    if ([property isEqual:@"hidden"]) self.hidden = value.boolValue; else self.alpha = value.doubleValue;
    if (self.hook) self.hook();
    if ([self.behavior isEqual:@"detach"]) [self.parent.children removeObjectIdenticalTo:self];
    if ([self.behavior isEqual:@"mismatch"]) self.alpha = 0.25;
    if ([self.behavior isEqual:@"throwAfter"]) @throw [NSException exceptionWithName:@"fixture" reason:@"after write" userInfo:nil];
}
@end

static BOOL typed(NSString *property, id value) {
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    // Foundation JSON booleans use the runtime class of the NSNumber Boolean singletons.
    // This host-runtime fixture does not generalize that check to an untested runtime.
    BOOL boolean = object_getClass(value) == object_getClass(@YES);
    if ([property isEqual:@"hidden"]) return boolean;
    return [property isEqual:@"alpha"] && !boolean && isfinite([value doubleValue]) && [value doubleValue] >= 0 && [value doubleValue] <= 1;
}
static NSDictionary *result(NSString *status, BOOL entered) { return @{@"status": status, @"entered": @(entered)}; }
@implementation OperationDriver
- (instancetype)initWithRoot:(FakeView *)root node:(FakeView *)node {
    if ((self = [super init])) {
        _root = root; _map = [NSMapTable strongToWeakObjectsMapTable];
        [_map setObject:node forKey:@"node"]; [_map setObject:node.parent forKey:@"parent"]; [_map setObject:root forKey:@"window"];
        _journal = [NSMutableDictionary new]; _undo = [NSMutableDictionary new];
        _generation = NSUUID.UUID.UUIDString; _expires = 120;
    } return self;
}
- (BOOL)reachable:(FakeView *)node {
    if (!node) return NO;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:self.root];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger count = 0;
    while (queue.count && count++ < 20000) {
        FakeView *item = queue.lastObject; [queue removeLastObject];
        if ([seen containsObject:item]) return NO;
        [seen addObject:item];
        if (item == node) return YES;
        [queue addObjectsFromArray:item.children];
    } return NO;
}
- (BOOL)matches:(FakeView *)node parent:(NSString *)parent window:(NSString *)window klass:(NSString *)klass {
    return node && [self reachable:node] && object_getClass(node) == NSClassFromString(klass)
        && node.parent == [self.map objectForKey:parent] && node.parent != nil
        && node.window == [self.map objectForKey:window] && node.window == self.root;
}
- (NSDictionary *)request:(NSString *)op sequence:(NSUInteger)sequence property:(NSString *)property
                 expected:(id)expected value:(id)value generation:(NSString *)generation
                    token:(NSString *)token parent:(NSString *)parent window:(NSString *)window
                    klass:(NSString *)klass now:(double)now {
    // Complete payload equality stands in for a canonical digest; no lossy string hashing.
    NSArray *payload = @[@(sequence), property, expected, value, generation, token, parent, window, klass];
    NSDictionary *old = self.journal[op];
    if (old) return [old[@"payload"] isEqual:payload] ? old[@"result"] : result(@"payloadConflict", NO);
    if (!sequence || sequence <= self.highWater) return result(@"resultUnavailable", NO);
    if (self.busy) return result(@"busy", NO);
    if (self.quarantined) return result(@"quarantined", NO);
    if (self.released || ![generation isEqual:self.generation]) return result(@"generation", NO);
    if (!isfinite(now) || now >= self.expires) return result(@"expired", NO);
    if (!typed(property, expected) || !typed(property, value)) return result(@"type", NO);
    // Strong local is held only for this operation. Registry never retains the node.
    FakeView *node = [self.map objectForKey:token];
    if (![self matches:node parent:parent window:window klass:klass]) return result(@"identity", NO);
    NSNumber *before = [property isEqual:@"hidden"] ? @(node.hidden) : @(node.alpha);
    if (![before isEqual:expected]) return result(@"valueConflict", NO);
    self.highWater = sequence;
    self.busy = YES;
    self.journal[op] = @{@"payload":payload, @"result":result(@"inFlight", NO)};
    NSDictionary *outcome;
    @try {
        if ([before isEqual:value]) outcome = result(@"noChange", NO);
        else {
            self.journal[op] = @{@"payload":payload, @"result":result(@"uncertain", YES)};
            [node apply:property value:value];
            NSNumber *observed = [property isEqual:@"hidden"] ? @(node.hidden) : @(node.alpha);
            if (![observed isEqual:value] || ![self matches:node parent:parent window:window klass:klass]) {
                self.quarantined = YES; outcome = result(@"uncertain", YES);
            } else {
                self.revision++;
                NSString *undoID = NSUUID.UUID.UUIDString;
                [self.undo removeAllObjects]; // Fixture supports the latest revision only.
                self.undo[undoID] = @{@"before":before, @"applied":value, @"property":property,
                                     @"generation":generation, @"revision":@(self.revision)};
                outcome = @{@"status":@"applied", @"entered":@YES, @"undo":undoID};
            }
        }
    } @catch (NSException *exception) { self.quarantined = YES; outcome = result(@"uncertain", YES); }
    @finally { self.busy = NO; }
    if (self.quarantined) [self.undo removeAllObjects];
    self.journal[op] = @{@"payload":payload, @"result":outcome};
    return outcome;
}
- (NSDictionary *)revert:(NSString *)undoID operation:(NSString *)op sequence:(NSUInteger)sequence {
    NSDictionary *record = self.undo[undoID];
    if (!record || [record[@"revision"] unsignedIntegerValue] != self.revision) return result(@"undoUnavailable", NO);
    NSDictionary *outcome = [self request:op sequence:sequence property:record[@"property"] expected:record[@"applied"] value:record[@"before"]
                              generation:record[@"generation"] token:@"node" parent:@"parent" window:@"window" klass:@"FakeView" now:1];
    if ([outcome[@"status"] isEqual:@"applied"]) [self.undo removeAllObjects];
    return outcome;
}
- (void)releaseCapture { self.released = YES; self.map = nil; [self.undo removeAllObjects]; }
@end
