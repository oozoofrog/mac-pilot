// Included at capture scope by operation.inc and by the Foundation-only policy test.
// One monotonic start-admission interval covers all hosts and both native stages.
struct MacCUSwiftUICaptureSchedule {
    double started;
    unsigned hosts = 0;
    void capture(NSMutableDictionary *host, double (^clock)(void), BOOL (^cancelled)(void),
                 NSString *(^renderPreflight)(void), void (^render)(void), void (^graph)(void)) {
        NSMutableDictionary *rendering = host[@"rendering"];
        auto refusal = [&]() -> NSString * {
            if (cancelled()) return @"cancelled";
            if (clock() - started >= 2) return @"shared start budget expired";
            return nil;
        };
        NSString *denied = ++hosts > 8 ? @"aggregate host budget" : refusal();
        if (denied) {
            host[@"graphStatus"] = @"overbudget"; host[@"reason"] = denied;
            rendering[@"status"] = @"overbudget"; rendering[@"reason"] = denied;
            return;
        }
        auto graphStage = [&]() {
            NSString *reason = refusal();
            if (reason) { host[@"graphStatus"] = @"overbudget"; host[@"reason"] = reason; return; }
            double begin = clock(); host[@"graphCallBegan"] = @YES;
            @try { graph(); }
            @catch (NSException *exception) {
                host[@"graphStatus"] = @"error"; host[@"reason"] = @"SwiftUI graph exception";
                [host removeObjectForKey:@"graphBase64"];
            } @finally { host[@"graphInterval"] = @[@(begin), @(clock())]; }
        };
        auto renderStage = [&]() {
            NSString *reason = refusal();
            @try { if (!reason) reason = renderPreflight(); }
            @catch (NSException *exception) {
                rendering[@"status"] = @"error"; rendering[@"reason"] = @"SwiftUI rendering preflight exception";
                return;
            }
            // Preflight may itself consume time or observe cancellation.
            if (!reason) reason = refusal();
            if (reason) { rendering[@"status"] = @"overbudget"; rendering[@"reason"] = reason; return; }
            double begin = clock(); rendering[@"callBegan"] = @YES;
            @try { render(); }
            @catch (NSException *exception) {
                rendering[@"status"] = @"error"; rendering[@"reason"] = @"SwiftUI rendering exception";
                [rendering removeObjectForKey:@"data"];
            } @finally { rendering[@"interval"] = @[@(begin), @(clock())]; }
        };
        renderStage();
        graphStage();
    }
};
