#import "fault-target.h"
#import <time.h>
#import <unistd.h>
#import <errno.h>

#if __has_feature(objc_arc)
#error Fixture sentinel requires explicit MRC autorelease semantics
#endif

static NSMutableArray *events;
static NSString *eventPath;
static NSUInteger eventSequence;

static void record(NSString *phase, NSString *generation, NSString *requestID, NSDictionary *detail) {
    @autoreleasepool {
        if (!events) events = [[NSMutableArray alloc] init];
        if (!eventPath) {
            NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            eventPath = [[directory stringByAppendingPathComponent:@"fault-events.json"] copy];
        }
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        NSDictionary *entry = @{@"sequence": @(++eventSequence), @"phase": phase,
            @"nodeGeneration": generation ?: @"", @"requestID": requestID ?: @"", @"pid": @(getpid()),
            @"unixSeconds": @([[NSDate date] timeIntervalSince1970]),
            @"monotonicSeconds": @(now.tv_sec + now.tv_nsec / 1e9), @"detail": detail ?: @{}};
        [events addObject:entry];
        if (events.count > 256) [events removeObjectAtIndex:0];
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"events": events}
            options:NSJSONWritingSortedKeys error:nil];
        if (!data || data.length > 262144 || ![data writeToFile:eventPath atomically:YES]) {
            NSLog(@"fixture fault event persistence failed");
        }
    }
}

@interface MacCUFixtureDeallocSentinel : NSObject {
    NSString *_generation;
    NSString *_requestID;
}
- (instancetype)initWithGeneration:(NSString *)generation requestID:(NSString *)requestID;
@end
@implementation MacCUFixtureDeallocSentinel
- (instancetype)initWithGeneration:(NSString *)generation requestID:(NSString *)requestID {
    if ((self = [super init])) {
        _generation = [generation copy]; _requestID = [requestID copy];
        record(@"sentinelCreated", _generation, _requestID, nil);
    }
    return self;
}
- (void)dealloc {
    record(@"sentinelDeallocated", _generation, _requestID, nil);
    [_generation release]; [_requestID release]; [super dealloc];
}
@end

@implementation MacCUQualificationEditTarget {
    NSString *_generation;
    NSUInteger _hiddenSetterCount;
    NSUInteger _alphaSetterCount;
    NSString *_faultMode;
    NSString *_faultRequestID;
}
@synthesize generation = _generation, hiddenSetterCount = _hiddenSetterCount, alphaSetterCount = _alphaSetterCount;
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _generation = [[[NSUUID UUID] UUIDString] copy];
        record(@"targetCreated", _generation, nil, @{@"address": [NSString stringWithFormat:@"%p", self]});
    }
    return self;
}
- (BOOL)armFault:(NSString *)mode requestID:(NSString *)requestID {
    if (_faultMode || ![@[@"throwAfterWrite", @"slowAfterWrite"] containsObject:mode] || requestID.length != 36) return NO;
    _faultMode = [mode copy]; _faultRequestID = [requestID copy];
    record(@"armed", _generation, _faultRequestID, @{@"mode": _faultMode});
    return YES;
}
- (NSDictionary *)model {
    return @{@"hidden": @([super isHidden]), @"alpha": @([super alpha]),
        @"setterCounts": @{@"hidden": @(_hiddenSetterCount), @"alpha": @(_alphaSetterCount)}};
}
- (void)setHidden:(BOOL)hidden {
    ++_hiddenSetterCount;
    NSString *mode = [[_faultMode retain] autorelease];
    NSString *requestID = [[_faultRequestID retain] autorelease];
    [_faultMode release]; _faultMode = nil;
    [_faultRequestID release]; _faultRequestID = nil;
    record(@"hiddenSetterEntered", _generation, requestID, [self model]);
    // This object belongs to the caller's autorelease pool, not record()'s pool.
    if (mode) [[[MacCUFixtureDeallocSentinel alloc] initWithGeneration:_generation requestID:requestID] autorelease];
    [super setHidden:hidden];
    record(@"hiddenApplied", _generation, requestID, [self model]);
    if ([mode isEqual:@"throwAfterWrite"]) {
        record(@"throwing", _generation, requestID, [self model]);
        [NSException raise:@"MacCUFixtureWriteThenThrow" format:@"Owned fixture setter applied hidden before throwing"];
    } else if ([mode isEqual:@"slowAfterWrite"]) {
        record(@"finiteDelayEntered", _generation, requestID, @{@"maximumSeconds": @4});
        // Finite fixture work only. No run-loop pumping, callback, or unbounded wait.
        struct timespec remaining = {4, 0};
        while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}
        record(@"finiteDelayReturned", _generation, requestID, [self model]);
    }
    record(@"hiddenSetterReturned", _generation, requestID, [self model]);
}
- (void)setAlpha:(CGFloat)alpha {
    ++_alphaSetterCount; [super setAlpha:alpha];
    record(@"alphaApplied", _generation, nil, [self model]);
}
+ (NSDictionary *)eventSnapshot {
    return @{@"schemaVersion": @1, @"events": events ? [[events copy] autorelease] : @[]};
}
- (void)dealloc {
    record(@"targetDeallocated", _generation, nil, @{@"address": [NSString stringWithFormat:@"%p", self]});
    [_generation release]; [_faultMode release]; [_faultRequestID release]; [super dealloc];
}
@end
