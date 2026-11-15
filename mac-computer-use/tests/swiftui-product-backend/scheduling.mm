#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "swiftui-scheduling.h"
static void require(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL %s\n", message); exit(1); }
}
static NSMutableDictionary *host(void) {
    return [NSMutableDictionary dictionaryWithDictionary:@{@"graphStatus": @"notCalled",
        @"rendering": [NSMutableDictionary dictionaryWithDictionary:@{@"status": @"unavailable"}]}];
}
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--native-check") || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1);
    @autoreleasepool {
        __block double now = 100; __block BOOL cancel = NO;
        double (^clock)(void) = ^double { return now; };
        BOOL (^cancelled)(void) = ^BOOL { return cancel; };
        NSString *(^valid)(void) = ^NSString * { return nil; };
        NSMutableArray *order = [NSMutableArray array];
        MacCUSwiftUICaptureSchedule schedule{now};
        NSMutableDictionary *first = host();
        schedule.capture(first, clock, cancelled, valid,
            ^{ [order addObject:@"render"]; first[@"rendering"][@"status"] = @"available"; now += .05; },
            ^{ [order addObject:@"graph"]; first[@"graphStatus"] = @"returned"; first[@"graphBase64"] = @"graph"; now += 2.8980679167434573; });
        require([order isEqual:@[@"render", @"graph"]], "2.898s graph must follow visual work; both admitted outputs retained");
        require([first[@"rendering"][@"status"] isEqual:@"available"] && first[@"graphBase64"], "both outputs");
        require([first[@"graphInterval"][1] doubleValue] - [first[@"graphInterval"][0] doubleValue] > 2.898, "truthful nonpreemptible graph interval");
        __block int calls = 0;
        schedule.capture(host(), clock, cancelled, valid, ^{ calls++; }, ^{ calls++; });
        require(calls == 0, "no new host after expiration");
        now = 200; MacCUSwiftUICaptureSchedule longRender{now}; NSMutableDictionary *second = host();
        longRender.capture(second, clock, cancelled, valid, ^{ now += 2; }, ^{ calls++; });
        require(calls == 0 && !second[@"graphCallBegan"], "no second phase at exact deadline, clock never resets");
        now = 300; MacCUSwiftUICaptureSchedule cancellation{now}; NSMutableDictionary *third = host();
        cancellation.capture(third, clock, cancelled, valid, ^{ cancel = YES; }, ^{ calls++; });
        require(calls == 0 && [third[@"reason"] isEqual:@"cancelled"], "cancel between phases");
        cancel = NO; now = 400; MacCUSwiftUICaptureSchedule preflight{now}; NSMutableDictionary *fourth = host();
        preflight.capture(fourth, clock, cancelled, ^NSString * { return @"invalid image"; },
            ^{ calls++; }, ^{ fourth[@"graphStatus"] = @"returned"; });
        require(calls == 0 && !fourth[@"rendering"][@"callBegan"] && [fourth[@"graphStatus"] isEqual:@"returned"], "render refusal preserves valid graph");
        now = 500; MacCUSwiftUICaptureSchedule errors{now}; NSMutableDictionary *fifth = host();
        errors.capture(fifth, clock, cancelled, valid,
            ^{ @throw [NSException exceptionWithName:@"render" reason:nil userInfo:nil]; },
            ^{ fifth[@"graphStatus"] = @"returned"; fifth[@"graphBase64"] = @"graph"; });
        require([fifth[@"rendering"][@"status"] isEqual:@"error"] && fifth[@"graphBase64"] && fifth[@"rendering"][@"interval"], "render exception independent of graph");
        NSMutableDictionary *sixth = host();
        errors.capture(sixth, clock, cancelled, valid,
            ^{ sixth[@"rendering"][@"status"] = @"available"; sixth[@"rendering"][@"data"] = @"PNG"; },
            ^{ @throw [NSException exceptionWithName:@"graph" reason:nil userInfo:nil]; });
        require([sixth[@"graphStatus"] isEqual:@"error"] && sixth[@"rendering"][@"data"] && sixth[@"graphInterval"], "graph exception preserves composite");
        now = 600; MacCUSwiftUICaptureSchedule hosts{now}; calls = 0;
        for (int i=0;i<9;i++) hosts.capture(host(), clock, cancelled, valid, ^{ calls++; }, ^{ calls++; });
        require(calls == 16, "eight admitted hosts");
        now = 700; MacCUSwiftUICaptureSchedule duringPreflight{now}; calls = 0;
        duringPreflight.capture(host(), clock, cancelled, ^NSString * { cancel = YES; return nil; }, ^{ calls++; }, ^{ calls++; });
        require(calls == 0, "cancellation rechecked after preflight before native call");
        cancel = NO; now = 800; MacCUSwiftUICaptureSchedule preflightError{now}; NSMutableDictionary *seventh = host();
        preflightError.capture(seventh, clock, cancelled,
            ^NSString * { @throw [NSException exceptionWithName:@"preflight" reason:nil userInfo:nil]; },
            ^{ calls++; }, ^{ seventh[@"graphStatus"] = @"returned"; });
        require(calls == 0 && [seventh[@"rendering"][@"status"] isEqual:@"error"] && [seventh[@"graphStatus"] isEqual:@"returned"], "preflight exception preserves graph");
        puts("PASS actual production scheduling: visual first, long graph, deadline, host cap, cancellation, preflight, independent exceptions");
    }
    return 0;
}
