// Shared schema-2 implementation: included by the compiled resident and headless shim.
        NSString *kind = q[@"kind"], *op = q[@"operationID"], *digest = q[@"requestDigest"];
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
            @"schemaVersion": @2, @"operationID": op, @"requestDigest": digest,
            @"ownerID": q[@"ownerID"], @"inspectionID": q[@"inspectionID"], @"targetEpoch": q[@"targetEpoch"],
            @"captureID": (BOOL)[kind isEqual:@"capture"] ? q[@"newCaptureID"] : q[@"captureID"],
            @"status": @"rejected", @"reasonCode": @"notAdmitted", @"phase": @"admission",
            @"mutationOutcome": @"notEntered", @"setterEntered": @NO, @"needsRefresh": @YES,
            @"postcondition": @"unavailable",
            @"before": [NSNull null], @"requested": q[@"value"] ?: (id)[NSNull null],
            @"observed": [NSNull null], @"undoToken": [NSNull null]}];
        id anchor = (id)objc_getClass("NSObject");
        const void *key = (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1");
        NSMutableDictionary *macCURegistry = nil;
        BOOL reserved = NO;
        BOOL entered __attribute__((unused)) = NO;
        auto reject = [&](NSString *status, NSString *reason) {
            out[@"status"] = status; out[@"reasonCode"] = reason;
        };
        // All captures/operations use the same bounded traversal. Objects are retained
        // ONLY by these autoreleased local collections until the local pool drains
        // on normal completion. External debugger unwind does not establish release.
        auto graph = [&]() -> NSArray * {
            NSMutableArray *windows = [NSMutableArray array];
            NSSet *scenes = [[UIApplication sharedApplication] connectedScenes];
            if ((NSUInteger)[scenes count] > 64) return nil;
            for (UIScene *scene in scenes) if ((BOOL)[scene isKindOfClass:[UIWindowScene class]]) {
                NSArray *items = [(UIWindowScene *)scene windows];
                if ((NSUInteger)[items count] > 64 || (NSUInteger)[windows count] + (NSUInteger)[items count] > 64) return nil;
                for (UIWindow *window in items) if ([windows indexOfObjectIdenticalTo:window] == NSNotFound) [windows addObject:window];
            }
            NSArray *legacy = [[UIApplication sharedApplication] windows];
            if ((NSUInteger)[legacy count] > 64) return nil;
            for (UIWindow *window in legacy) if ([windows indexOfObjectIdenticalTo:window] == NSNotFound) [windows addObject:window];
            if ((NSUInteger)[windows count] > 64) return nil;
            NSMutableArray *pending = [NSMutableArray array], *rows = [NSMutableArray array];
            NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
            for (UIWindow *window in windows) [pending addObject:@{@"view": window, @"parent": [NSNull null], @"window": window, @"depth": @0, @"order": @((NSUInteger)[pending count])}];
            while ((NSUInteger)[pending count]) {
                if (operationCancelled()) return nil;
                NSDictionary *row = (id)[(id)[(id)[pending lastObject] retain] autorelease]; [pending removeLastObject];
                UIView *view = row[@"view"];
                if ((BOOL)[seen containsObject:view] || (NSUInteger)[rows count] >= 20000 || (NSUInteger)[row[@"depth"] unsignedIntegerValue] > 512) return nil;
                [seen addObject:view]; [rows addObject:row];
                UIView *parent = row[@"parent"] == [NSNull null] ? nil : row[@"parent"];
                if ([view superview] != parent || (view != row[@"window"] && [view window] != row[@"window"])) return nil;
                NSArray *children = [view subviews];
                if ((NSUInteger)[children count] > 20000 || (NSUInteger)[pending count] + (NSUInteger)[children count] + (NSUInteger)[rows count] > 20000) return nil;
                NSUInteger index = 0;
                for (UIView *child in children) [pending addObject:@{@"view": child, @"parent": view, @"window": row[@"window"],
                    @"depth": @((NSUInteger)[row[@"depth"] unsignedIntegerValue] + 1), @"order": @(index++)}];
            }
            return rows;
        };
        // The compiled resident always enables Objective-C exceptions.
        // Legacy syntax harnesses may disable ObjC exceptions. In that mode its exception
        // trap aborts evaluation: no receipt is written, the busy journal is not
        // reset, and run_engine preserves dispatchResultLost/uncertain. Never
        // manufacture a successful readback or retry after that external trap.
#if defined(OBJC_ZEROCOST_EXCEPTIONS)
        @try {
#endif
            do {
                if (operationCancelled()) { reject(@"failed", @"cancelledBeforeEntry"); break; }
                if (![NSThread isMainThread] || sizeof(CGFloat) != 8) { reject(@"unsupported", @"mainThreadOrCGFloat"); break; }
                auto uuidString = [&](NSString *value) -> BOOL {
                    return (BOOL)[value isKindOfClass:[NSString class]] && (NSUInteger)[value length] == 36
                        && (BOOL)[[(id)[(id)[[NSUUID alloc] initWithUUIDString:value] autorelease] UUIDString] isEqual:value];
                };
                auto proofValid = [&](NSDictionary *proof) -> BOOL {
                    if (!(BOOL)[proof isKindOfClass:[NSDictionary class]] || (NSUInteger)[proof count] != 8) return NO;
                    for (NSString *field in @[@"ownerID", @"inspectionID", @"targetEpoch", @"captureID", @"operationID"])
                        if (!uuidString(proof[field])) return NO;
                    if (!(BOOL)[proof[@"entryTransitionID"] isEqual:[NSNull null]] && !uuidString(proof[@"entryTransitionID"])) return NO;
                    NSString *hash = proof[@"requestDigest"]; NSNumber *sequence = proof[@"sequence"];
                    return (BOOL)[hash isKindOfClass:[NSString class]] && (NSUInteger)[hash length] == 64
                        && [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound
                        && (BOOL)[sequence isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)sequence) != CFBooleanGetTypeID()
                        && (double)[sequence doubleValue] == (unsigned long long)[sequence unsignedLongLongValue]
                        && (unsigned long long)[sequence unsignedLongLongValue] >= 1 && (unsigned long long)[sequence unsignedLongLongValue] <= 4096;
                };
                auto historyValid = [&](NSArray *history) -> BOOL {
                    if (!(BOOL)[history isKindOfClass:[NSArray class]] || (NSUInteger)[history count] > 64) return NO;
                    NSMutableSet *epochs = [NSMutableSet set], *inspections = [NSMutableSet set], *transitions = [NSMutableSet set];
                    for (NSDictionary *proof in history) {
                        if (!proofValid(proof) || (BOOL)[epochs containsObject:proof[@"targetEpoch"]]
                            || (BOOL)[inspections containsObject:proof[@"inspectionID"]]) return NO;
                        if (proof[@"entryTransitionID"] != [NSNull null]) {
                            if ((BOOL)[transitions containsObject:proof[@"entryTransitionID"]]) return NO;
                            [transitions addObject:proof[@"entryTransitionID"]];
                        }
                        [epochs addObject:proof[@"targetEpoch"]]; [inspections addObject:proof[@"inspectionID"]];
                    }
                    return YES;
                };
                auto makeState = [&](NSArray *history) -> NSMutableDictionary * {
                    return [NSMutableDictionary dictionaryWithDictionary:@{@"magic": @"mac-cu.weak-registry", @"schema": @2,
                        @"lifecycleVersion": @1, @"retired": history,
                        @"ownerID": q[@"ownerID"], @"inspectionID": q[@"inspectionID"], @"epoch": q[@"targetEpoch"],
                        @"highWater": @0, @"busy": @NO, @"expiresAt": @0, @"expiresUptime": @0, @"registryState": @"reserved",
                        @"operations": [NSMutableDictionary dictionary], @"results": [NSMutableDictionary dictionary],
                        @"resultOrder": [NSMutableArray array]}];
                };
                NSMutableDictionary *prior = (id)[(id)[(id)objc_getAssociatedObject(anchor, key) retain] autorelease];
                NSDictionary *transition = q[@"transition"];
                BOOL rollover = NO;
                if (prior) {
                    if (!(BOOL)[prior isKindOfClass:[NSMutableDictionary class]] || !(BOOL)[prior[@"magic"] isEqual:@"mac-cu.weak-registry"]
                        || !(BOOL)[prior[@"schema"] isEqual:@2] || !(BOOL)[prior[@"lifecycleVersion"] isEqual:@1]
                        || CFGetTypeID((CFTypeRef)prior[@"lifecycleVersion"]) == CFBooleanGetTypeID()
                        || !historyValid(prior[@"retired"])
                        || !(BOOL)[prior[@"operations"] isKindOfClass:[NSMutableDictionary class]]
                        || (NSUInteger)[prior[@"operations"] count] > 4096
                        || !uuidString(prior[@"ownerID"]) || !uuidString(prior[@"inspectionID"]) || !uuidString(prior[@"epoch"])
                        || !(BOOL)[prior[@"results"] isKindOfClass:[NSMutableDictionary class]] || (NSUInteger)[prior[@"results"] count] > 256
                        || !(BOOL)[prior[@"resultOrder"] isKindOfClass:[NSMutableArray class]] || (NSUInteger)[prior[@"resultOrder"] count] > 256
                        || !(BOOL)[prior[@"highWater"] isKindOfClass:[NSNumber class]]
                        || !(BOOL)[prior[@"busy"] isKindOfClass:[NSNumber class]]
                        || !(BOOL)[prior[@"expiresAt"] isKindOfClass:[NSNumber class]] || !(BOOL)[prior[@"expiresUptime"] isKindOfClass:[NSNumber class]]) {
                        reject(@"keyCollision", @"foreignRegistryShape"); break;
                    }
                    macCURegistry = prior;
                    NSDictionary *entry = macCURegistry[@"transition"], *released = macCURegistry[@"releaseProof"];
                    BOOL malformed = (CFGetTypeID((CFTypeRef)macCURegistry[@"busy"]) != CFBooleanGetTypeID()
                        || CFGetTypeID((CFTypeRef)macCURegistry[@"highWater"]) == CFBooleanGetTypeID()
                        || (double)[macCURegistry[@"highWater"] doubleValue] != (unsigned long long)[macCURegistry[@"highWater"] unsignedLongLongValue]
                        || (unsigned long long)[macCURegistry[@"highWater"] unsignedLongLongValue] > 4096
                        || !(BOOL)[@[@"reserved", @"capturing", @"active", @"quarantined", @"released"] containsObject:macCURegistry[@"registryState"] ?: @""]);
                    if (((NSUInteger)[macCURegistry[@"retired"] count] != 0) != (entry != nil)) malformed = YES;
                    if (entry) {
                        if (!(BOOL)[entry isKindOfClass:[NSDictionary class]] || (NSUInteger)[entry count] != 3
                            || !uuidString(entry[@"transitionID"]) || !proofValid(entry[@"predecessor"])
                            || !historyValid(entry[@"retired"])) malformed = YES;
                        else if (!(BOOL)[[entry[@"retired"] arrayByAddingObject:entry[@"predecessor"]] isEqual:macCURegistry[@"retired"]]) malformed = YES;
                        else for (NSDictionary *item in macCURegistry[@"retired"])
                            if ((BOOL)[item[@"entryTransitionID"] isEqual:entry[@"transitionID"]]) malformed = YES;
                    }
                    for (NSDictionary *operation in (NSArray *)[macCURegistry[@"operations"] allValues]) {
                        if (!(BOOL)[operation isKindOfClass:[NSDictionary class]] || !(BOOL)[operation[@"digest"] isKindOfClass:[NSString class]]
                            || !(BOOL)[@[@"reserved", @"setterEntering", @"finished"] containsObject:operation[@"phase"] ?: @""]) malformed = YES;
                    }
                    if (released && (!proofValid(released) || !(BOOL)[released[@"ownerID"] isEqual:macCURegistry[@"ownerID"]]
                        || !(BOOL)[released[@"inspectionID"] isEqual:macCURegistry[@"inspectionID"]] || !(BOOL)[released[@"targetEpoch"] isEqual:macCURegistry[@"epoch"]]
                        || !(BOOL)[released[@"captureID"] isEqual:macCURegistry[@"captureID"]] || !(BOOL)[released[@"sequence"] isEqual:macCURegistry[@"highWater"]])) malformed = YES;
                    if (malformed) { reject(@"keyCollision", @"foreignRegistryShape"); break; }
                    BOOL retired = NO;
                    for (NSDictionary *proof in macCURegistry[@"retired"]) {
                        if ((BOOL)[proof[@"targetEpoch"] isEqual:macCURegistry[@"epoch"]] || (BOOL)[proof[@"inspectionID"] isEqual:macCURegistry[@"inspectionID"]]) malformed = YES;
                        if ((BOOL)[proof[@"targetEpoch"] isEqual:q[@"targetEpoch"]] || (BOOL)[proof[@"inspectionID"] isEqual:q[@"inspectionID"]]) retired = YES;
                    }
                    if (malformed) { reject(@"keyCollision", @"foreignRegistryShape"); break; }
                    if (retired) { reject(@"expired", @"retiredInspectionOrEpoch"); break; }
                    if (!(BOOL)[macCURegistry[@"ownerID"] isEqual:q[@"ownerID"]] || !(BOOL)[macCURegistry[@"inspectionID"] isEqual:q[@"inspectionID"]]
                        || !(BOOL)[macCURegistry[@"epoch"] isEqual:q[@"targetEpoch"]]) {
                        if (!(BOOL)[kind isEqual:@"capture"] || !(BOOL)[q[@"replaceCaptureID"] isEqual:[NSNull null]]
                            || !(BOOL)[q[@"sequence"] isEqual:@1] || (BOOL)[q[@"inspectionID"] isEqual:macCURegistry[@"inspectionID"]]
                            || (BOOL)[q[@"targetEpoch"] isEqual:macCURegistry[@"epoch"]]) { reject(@"ownershipConflict", @"foreignOwnerOrEpoch"); break; }
                        if (!(BOOL)[transition isKindOfClass:[NSDictionary class]] || (NSUInteger)[transition count] != 3
                            || !uuidString(transition[@"transitionID"]) || !proofValid(transition[@"predecessor"])
                            || !historyValid(transition[@"retired"])) { reject(@"ownershipConflict", @"transitionRequired"); break; }
                        if ((BOOL)[macCURegistry[@"busy"] boolValue]) { reject(@"busy", @"interruptedOrReentrant"); break; }
                        NSDictionary *proof = macCURegistry[@"releaseProof"];
                        BOOL finished = YES;
                        for (NSDictionary *operation in (NSArray *)[macCURegistry[@"operations"] allValues]) {
                            if (!(BOOL)[operation isKindOfClass:[NSDictionary class]] || !(BOOL)[operation[@"phase"] isEqual:@"finished"]) finished = NO;
                        }
                        if (!(BOOL)[macCURegistry[@"registryState"] isEqual:@"released"] || !proofValid(proof) || !finished
                            || macCURegistry[@"map"] || macCURegistry[@"nodes"] || macCURegistry[@"undo"] || macCURegistry[@"undoOrder"] || macCURegistry[@"revisions"]
                            || !(BOOL)[proof[@"ownerID"] isEqual:macCURegistry[@"ownerID"]] || !(BOOL)[proof[@"inspectionID"] isEqual:macCURegistry[@"inspectionID"]]
                            || !(BOOL)[proof[@"targetEpoch"] isEqual:macCURegistry[@"epoch"]] || !(BOOL)[proof[@"captureID"] isEqual:macCURegistry[@"captureID"]]
                            || !(BOOL)[proof[@"sequence"] isEqual:macCURegistry[@"highWater"]]
                            || !(BOOL)[proof[@"entryTransitionID"] isEqual:((NSMutableDictionary *)macCURegistry[@"transition"])[@"transitionID"] ?: (id)[NSNull null]]
                            || !(BOOL)[((NSDictionary *)((NSMutableDictionary *)macCURegistry[@"operations"])[proof[@"operationID"]])[@"digest"] isEqual:proof[@"requestDigest"]]
                            || !(BOOL)[transition[@"predecessor"] isEqual:proof] || !(BOOL)[transition[@"retired"] isEqual:macCURegistry[@"retired"]]) {
                            reject(@"ownershipConflict", @"predecessorNotVerifiedReleased"); break;
                        }
                        if ((NSUInteger)[macCURegistry[@"retired"] count] >= 64) { reject(@"capacityExceeded", @"retiredEpochCapacity"); break; }
                        NSMutableArray *history = (id)[(id)[macCURegistry[@"retired"] mutableCopy] autorelease]; [history addObject:proof];
                        BOOL repeatedTransition = NO;
                        for (NSDictionary *entry in history) if ((BOOL)[entry[@"entryTransitionID"] isEqual:transition[@"transitionID"]]) repeatedTransition = YES;
                        if (repeatedTransition) { reject(@"conflict", @"transitionIdentityReused"); break; }
                        // Build the complete successor with its in-flight journal before
                        // publishing. Interruption cannot expose an unreserved new epoch.
                        macCURegistry = makeState(history); macCURegistry[@"transition"] = transition; rollover = YES;
                    } else if (transition && !(BOOL)[transition isEqual:macCURegistry[@"transition"]]) {
                        reject(@"conflict", @"transitionConflict"); break;
                    }
                } else {
                    if (!(BOOL)[kind isEqual:@"capture"] || !(BOOL)[q[@"replaceCaptureID"] isEqual:[NSNull null]]
                        || !(BOOL)[q[@"sequence"] isEqual:@1] || transition) { reject(@"expired", @"registryMissing"); break; }
                    macCURegistry = makeState(@[]);
                }
                NSDictionary *old = ((NSMutableDictionary *)macCURegistry[@"operations"])[op];
                if (old) {
                    if (!(BOOL)[old[@"digest"] isEqual:digest]) reject(@"conflict", @"digestConflict");
                    else if (((NSMutableDictionary *)macCURegistry[@"results"])[op]) [out addEntriesFromDictionary:((NSMutableDictionary *)macCURegistry[@"results"])[op]];
                    else { reject(@"resultUnavailable", @"reservedOrEvicted"); out[@"mutationOutcome"] = @"uncertain"; }
                    break;
                }
                if ((unsigned long long)[q[@"sequence"] unsignedLongLongValue] <= (unsigned long long)[macCURegistry[@"highWater"] unsignedLongLongValue]) { reject(@"resultUnavailable", @"highWater"); break; }
                if ((BOOL)[macCURegistry[@"busy"] boolValue]) { reject(@"busy", @"interruptedOrReentrant"); out[@"mutationOutcome"] = @"uncertain"; break; }
                if ((NSUInteger)[macCURegistry[@"operations"] count] >= 4096) { reject(@"capacityExceeded", @"operationCapacity"); break; }
                if ((BOOL)[kind isEqual:@"capture"]) {
                    if (macCURegistry[@"captureID"] && !(BOOL)[macCURegistry[@"captureID"] isEqual:q[@"replaceCaptureID"]]
                        && !(BOOL)[macCURegistry[@"captureID"] isEqual:q[@"replaceAttemptedCaptureID"]]) { reject(@"conflict", @"replacementCapture"); break; }
                } else if (!(BOOL)[macCURegistry[@"captureID"] isEqual:q[@"captureID"]]
                    && !((BOOL)[kind isEqual:@"release"] && (BOOL)[q[@"releaseCaptureIDs"] containsObject:macCURegistry[@"captureID"]])) {
                    reject(@"expired", @"captureChanged"); break;
                }
                [macCURegistry removeObjectForKey:@"releaseProof"];
                macCURegistry[@"highWater"] = q[@"sequence"];
                ((NSMutableDictionary *)macCURegistry[@"operations"])[op] = [NSMutableDictionary dictionaryWithDictionary:@{@"digest": digest, @"phase": @"reserved"}];
                macCURegistry[@"busy"] = @YES;
                if (!prior || rollover) {
                    objc_setAssociatedObject(anchor, key, macCURegistry, OBJC_ASSOCIATION_RETAIN);
                    if (objc_getAssociatedObject(anchor, key) != macCURegistry) { reject(@"ownershipConflict", @"associationNotOwned"); break; }
                }
                reserved = YES;
                if ((BOOL)[kind isEqual:@"release"]) {
                    [macCURegistry removeObjectForKey:@"map"]; [macCURegistry removeObjectForKey:@"nodes"];
                    [macCURegistry removeObjectForKey:@"undo"]; [macCURegistry removeObjectForKey:@"undoOrder"]; [macCURegistry removeObjectForKey:@"revisions"];
                    macCURegistry[@"registryState"] = @"released";
                    NSDictionary *proof = @{@"ownerID": macCURegistry[@"ownerID"], @"inspectionID": macCURegistry[@"inspectionID"],
                        @"targetEpoch": macCURegistry[@"epoch"], @"captureID": macCURegistry[@"captureID"],
                        @"operationID": op, @"requestDigest": digest, @"sequence": q[@"sequence"],
                        @"entryTransitionID": ((NSMutableDictionary *)macCURegistry[@"transition"])[@"transitionID"] ?: (id)[NSNull null]};
                    macCURegistry[@"releaseProof"] = proof; out[@"releaseProof"] = proof;
                    out[@"status"] = @"success"; out[@"reasonCode"] = @"released"; out[@"mutationOutcome"] = @"notApplicable";
                    out[@"authorityRevoked"] = @YES; out[@"registryReleased"] = @YES; out[@"remainingOwnedEntries"] = @0;
                    out[@"residualState"] = @"tombstone";
                    break;
                }
                if (!(BOOL)[kind isEqual:@"capture"] && ((double)[macCURegistry[@"expiresAt"] doubleValue] <= [[NSDate date] timeIntervalSince1970]
                    || (double)[macCURegistry[@"expiresUptime"] doubleValue] <= [[NSProcessInfo processInfo] systemUptime]
                    || !(BOOL)[macCURegistry[@"registryState"] isEqual:@"active"])) { reject(@"expired", @"expiredOrQuarantined"); break; }
                if ((BOOL)[kind isEqual:@"capture"]) {
                    // Revoke first; failure cannot restore old tokens or undo authority.
                    [macCURegistry removeObjectForKey:@"map"]; [macCURegistry removeObjectForKey:@"nodes"];
                    macCURegistry[@"registryState"] = @"capturing"; macCURegistry[@"captureID"] = q[@"newCaptureID"];
                    macCURegistry[@"undo"] = [NSMutableDictionary dictionary]; macCURegistry[@"undoOrder"] = [NSMutableArray array];
                    macCURegistry[@"revisions"] = [NSMutableDictionary dictionary];
                    NSArray *rows = graph();
                    if (!rows || !(NSUInteger)[rows count]) { reject(@"conflict", @"graphBoundsOrOwnership"); break; }
                    NSMapTable *map = [NSMapTable strongToWeakObjectsMapTable];
                    NSMapTable *tokens = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
                    for (NSDictionary *row in rows) {
                        NSString *token = [[NSUUID UUID] UUIDString];
                        [map setObject:row[@"view"] forKey:token]; [tokens setObject:token forKey:row[@"view"]];
                    }
                    NSMutableArray *nodes = [NSMutableArray array]; NSMutableDictionary *records = [NSMutableDictionary dictionary];
                    NSMutableDictionary *snapshots = [NSMutableDictionary dictionary], *textureJoins = [NSMutableDictionary dictionary];
                    BOOL texturePreflight = (NSUInteger)[rows count] <= 64; unsigned long long estimatedImageBytes = 0;
                    double started = [[NSDate date] timeIntervalSince1970]; NSUInteger bytes = 0;
                    for (NSDictionary *row in rows) {
                        if (operationCancelled()) { nodes = nil; break; }
                        UIView *view = row[@"view"]; UIWindow *window = row[@"window"];
                        NSString *token = [tokens objectForKey:view], *className = NSStringFromClass([view class]);
                        if ([className lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512) { nodes = nil; break; }
                        id parentToken = row[@"parent"] == [NSNull null] ? (id)[NSNull null] : [tokens objectForKey:row[@"parent"]];
                        NSDictionary *record = @{@"parentToken": parentToken, @"windowToken": [tokens objectForKey:window], @"className": className, @"sceneID": [[window windowScene] session].persistentIdentifier ?: @"legacy"};
                        records[token] = record;
                        CGRect frame = [view frame], bounds = [view bounds];
                        CGFloat alpha = [view alpha]; BOOL hidden = [view isHidden];
                        if (!__builtin_isfinite(alpha) || alpha < 0 || alpha > 1) { nodes = nil; break; }
                        CGFloat x1 = CGRectGetMaxX(bounds), y0 = CGRectGetMinY(bounds), y1 = CGRectGetMaxY(bounds), x0 = CGRectGetMinX(bounds);
                        CGPoint points[4] = {bounds.origin, {x1, y0}, {x1, y1}, {x0, y1}};
                        NSMutableArray *corners = [NSMutableArray array]; UIScreen *screen = [window screen];
                        double scale = screen ? [screen scale] : 0;
                        double pixelWidth = ceil(fabs(bounds.size.width) * scale), pixelHeight = ceil(fabs(bounds.size.height) * scale);
                        if (!__builtin_isfinite(scale) || scale <= 0 || !__builtin_isfinite(pixelWidth) || !__builtin_isfinite(pixelHeight)
                            || pixelWidth > 4096 || pixelHeight > 4096) texturePreflight = NO;
                        else {
                            unsigned long long imageBytes = (unsigned long long)pixelWidth * (unsigned long long)pixelHeight * 4;
                            if (imageBytes > 134217728ULL - estimatedImageBytes) texturePreflight = NO;
                            else estimatedImageBytes += imageBytes;
                        }
                        if (screen) for (unsigned i = 0; i < 4; i++) {
                            CGPoint w = [view convertPoint:points[i] toView:window];
                            CGPoint s = [window convertPoint:w toCoordinateSpace:[screen fixedCoordinateSpace]];
                            if (!__builtin_isfinite(s.x) || !__builtin_isfinite(s.y)) { corners = nil; break; }
                            [corners addObject:@[@(s.x), @(s.y)]];
                        }
                        NSDictionary *node = @{@"id": token, @"editToken": token, @"parentToken": parentToken,
                            @"sceneID": record[@"sceneID"], @"windowToken": record[@"windowToken"], @"className": className, @"siblingIndex": row[@"order"],
                            @"hidden": @(hidden), @"alpha": @(alpha), @"frame": @[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)],
                            @"geometry": @{@"corners": corners ?: (id)@[], @"windowID": record[@"windowToken"],
                                @"coordinateSpace": @"UIScreen.fixedCoordinateSpace points", @"verified": @NO, @"overlayEnabled": @NO}};
                        NSData *encoded = [NSJSONSerialization dataWithJSONObject:node options:0 error:NULL];
                        if (!encoded || (NSUInteger)[encoded length] > 16777216 - bytes) { nodes = nil; break; }
                        bytes += (NSUInteger)[encoded length]; [nodes addObject:node]; snapshots[token] = node;
                        // Addresses are ONLY a same-operation texture join, never edit
                        // identity. rows/tokens hold every view alive through collection
                        // and final graph checks, preventing storage reuse in this interval.
                        NSString *address = [NSString stringWithFormat:@"%p", (void *)view];
                        id parentAddress = row[@"parent"] == [NSNull null] ? (id)[NSNull null]
                            : [NSString stringWithFormat:@"%p", (void *)row[@"parent"]];
                        textureJoins[address] = @{@"nodeToken": token, @"className": className, @"parentAddress": parentAddress};
                    }
                    if (!nodes) { reject(@"capacityExceeded", @"captureBytesOrTypedValues"); break; }
                    NSDictionary *hierarchy = nil;
                    NSString *textureReason = texturePreflight ? @"Runtime texture collector unavailable" : @"Target texture estimate exceeds the fixed budget";
                    static void *textureLibrary = NULL;
                    if (texturePreflight && (textureLibrary || (textureLibrary = dlopen("/usr/lib/libViewDebuggerSupport.dylib", 2)))) {
                        id hubClass = NSClassFromString(@"DBGTargetHub"); id hub = hubClass ? (id)[hubClass sharedHub] : nil;
                        NSData *raw = hub ? (NSData *)[hub performRequestWithRequestInBase64:q[@"textureRequestBase64"]] : nil;
                        if (raw && (NSUInteger)[raw length] <= 16777216) {
                            NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
                            if ((BOOL)[decoded isKindOfClass:[NSDictionary class]] && (BOOL)[decoded[@"topLevelGroups"] isKindOfClass:[NSDictionary class]]) hierarchy = decoded;
                        }
                        if (!hierarchy) textureReason = @"Texture collector returned no bounded hierarchy";
                    }
#if MAC_CU_SWIFTUI_BRIDGE
                    NSMutableArray *swiftHosts = [NSMutableArray array];
                    __block NSUInteger swiftBytes = 0, graphBytes = 0;
#include "swiftui-scheduling.h"
                    double swiftStarted = [[NSProcessInfo processInfo] systemUptime];
                    MacCUSwiftUICaptureSchedule swiftSchedule{swiftStarted};
                    if (q[@"inspectionScope"]) for (NSDictionary *row in rows) {
                        UIView *view = row[@"view"];
                        if (![MacCUSwiftUIBridge accepts:view]) continue;
                        NSString *token = [tokens objectForKey:view];
                        NSMutableDictionary *host = [NSMutableDictionary dictionaryWithDictionary:@{
                            @"hostingNodeID": token, @"sceneID": records[token][@"sceneID"],
                            @"captureID": q[@"newCaptureID"], @"graphStatus": @"notCalled",
                            @"rendering": [NSMutableDictionary dictionaryWithDictionary:@{@"status": @"unavailable",
                                @"drawHierarchyReturned": [NSNull null], @"reason": @"notCalled"}]}];
                        if (swiftHosts.count >= 64) { swiftHosts = nil; break; }
                        [swiftHosts addObject:host];
                        __block CGRect bounds = CGRectZero; __block CGFloat scale = 0;
                        swiftSchedule.capture(host,
                            ^double { return [[NSProcessInfo processInfo] systemUptime]; },
                            ^BOOL { return operationCancelled(); },
                            ^NSString * {
                                bounds = view.bounds; scale = view.window.screen.scale;
                                double width = ceil(bounds.size.width * scale), height = ceil(bounds.size.height * scale);
                                if (!texturePreflight || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0
                                    || width > 4096 || height > 4096) return @"image preflight budget";
                                return nil;
                            }, ^{
                                NSMutableDictionary *rendering = host[@"rendering"];
                                UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
                                @try {
                                    BOOL drawn = [view drawViewHierarchyInRect:(CGRect){CGPointZero, bounds.size} afterScreenUpdates:NO];
                                    rendering[@"drawHierarchyReturned"] = @(drawn);
                                    NSData *png = drawn ? UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) : nil;
                                    if (png && png.length <= 2097152 && swiftBytes + ((png.length + 2) / 3) * 4 <= 8388608) {
                                        NSString *encoded = [png base64EncodedStringWithOptions:0]; swiftBytes += encoded.length;
                                        rendering[@"status"] = @"available"; rendering[@"reason"] = [NSNull null];
                                        rendering[@"data"] = encoded; rendering[@"pointWidth"] = @(bounds.size.width);
                                        rendering[@"pointHeight"] = @(bounds.size.height);
                                    } else { rendering[@"status"] = png ? @"overbudget" : @"error"; rendering[@"reason"] = @"draw/PNG unavailable or budget exceeded"; }
                                } @finally { UIGraphicsEndImageContext(); }
                            }, ^{
                                NSData *rawGraph = [MacCUSwiftUIBridge graph:view];
                                host[@"graphStatus"] = rawGraph ? @"returned" : @"nil";
                                if (rawGraph) {
                                    if (graphBytes >= 4194304 || rawGraph.length > (4194304 - graphBytes) * 3 / 4
                                        || ((rawGraph.length + 2) / 3) * 4 > 4194304 - graphBytes
                                        || ((rawGraph.length + 2) / 3) * 4 > 8388608 - swiftBytes) host[@"graphStatus"] = @"overbudget";
                                    else { NSString *encoded = [rawGraph base64EncodedStringWithOptions:0];
                                        graphBytes += encoded.length; swiftBytes += encoded.length; host[@"graphBase64"] = encoded; }
                                }
                            });
                    }
                    if (q[@"inspectionScope"]) {
                        if (!swiftHosts) { reject(@"capacityExceeded", @"swiftUIHostListBudget"); break; }
                        out[@"inspectionScope"] = q[@"inspectionScope"]; out[@"swiftUIRaw"] = swiftHosts;
                        // Keep the existing 16 MiB response bound. Reserve space for receipts.
                        NSData *combined = [NSJSONSerialization dataWithJSONObject:@[hierarchy ?: @{}, swiftHosts] options:0 error:NULL];
                        if (!combined || combined.length > 12582912) { hierarchy = nil; textureReason = @"Combined capture response budget"; }
                    }
#endif
                    // Getters can mutate hierarchy; recheck exact object/parent/window after metadata reads.
                    NSArray *fresh = graph(); BOOL stable = fresh && (NSUInteger)[fresh count] == (NSUInteger)[rows count];
                    for (NSDictionary *row in fresh) {
                        NSString *token = [tokens objectForKey:row[@"view"]]; NSDictionary *record = token ? records[token] : nil;
                        id parent = row[@"parent"] == [NSNull null] ? (id)[NSNull null] : [tokens objectForKey:row[@"parent"]];
                        UIView *view = row[@"view"]; NSDictionary *snapshot = token ? snapshots[token] : nil;
                        if (!record || !(BOOL)[record[@"parentToken"] isEqual:parent] || [map objectForKey:record[@"windowToken"]] != row[@"window"]
                            || !(BOOL)[record[@"sceneID"] isEqual:([[(UIWindow *)row[@"window"] windowScene] session].persistentIdentifier ?: @"legacy")]
                            || !(BOOL)[record[@"className"] isEqual:NSStringFromClass([view class])]
                            || !(BOOL)[snapshot[@"hidden"] isEqual:@([view isHidden])] || !(BOOL)[snapshot[@"alpha"] isEqual:@([view alpha])]) stable = NO;
                    }
                    if (!stable || objc_getAssociatedObject(anchor, key) != macCURegistry) { reject(@"conflict", @"captureGraphChanged"); break; }
                    macCURegistry[@"map"] = map; macCURegistry[@"nodes"] = records; macCURegistry[@"expiresAt"] = q[@"expiresAt"];
                    macCURegistry[@"expiresUptime"] = @([[NSProcessInfo processInfo] systemUptime] + 120); macCURegistry[@"registryState"] = @"active";
                    out[@"editableNodes"] = nodes; out[@"status"] = @"success"; out[@"reasonCode"] = @"captured";
                    if (hierarchy) { out[@"hierarchy"] = hierarchy; out[@"textureJoins"] = textureJoins; }
                    out[@"textureCapture"] = @{@"status": hierarchy ? @"collected" : @"unavailable",
                        @"reason": hierarchy ? (id)[NSNull null] : textureReason,
                        @"sameOperationIdentity": @YES, @"estimatedImageBytes": @(estimatedImageBytes), @"viewCount": @((NSUInteger)[rows count])};
                    out[@"mutationOutcome"] = @"notApplicable"; out[@"needsRefresh"] = @NO;
                    out[@"captureTime"] = (NSString *)[(id)[(id)[[NSISO8601DateFormatter alloc] init] autorelease] stringFromDate:[NSDate date]];
                    out[@"captureIntervalUnixSeconds"] = @[@(started), @([[NSDate date] timeIntervalSince1970])];
                    out[@"editing"] = @{@"inspectionID": q[@"inspectionID"], @"ownerID": q[@"ownerID"], @"targetEpoch": q[@"targetEpoch"],
                        @"expiresAt": q[@"expiresAt"], @"registryState": @"active"};
                    break;
                }
                NSMapTable *map = (id)[(id)[(id)macCURegistry[@"map"] retain] autorelease];
                if (!(BOOL)[map isKindOfClass:[NSMapTable class]] || !(BOOL)[macCURegistry[@"nodes"] isKindOfClass:[NSDictionary class]]
                    || !(BOOL)[macCURegistry[@"undo"] isKindOfClass:[NSMutableDictionary class]] || !(BOOL)[macCURegistry[@"revisions"] isKindOfClass:[NSMutableDictionary class]]) {
                    reject(@"keyCollision", @"invalidCapturePayload"); break;
                }
                NSDictionary *undo = nil;
                if ((BOOL)[kind isEqual:@"revert"]) {
                    undo = (id)[(id)[(id)((NSMutableDictionary *)macCURegistry[@"undo"])[q[@"undoToken"]] retain] autorelease];
                    if (!undo || !(BOOL)[undo isEqual:q[@"undoReceipt"]]) { reject(@"undoConflict", @"missingUndoReceipt"); break; }
                    for (NSString *field in @[@"nodeToken", @"property", @"expectedParentToken", @"expectedWindowToken", @"expectedClass"])
                        q[field] = undo[field];
                    q[@"expectedValue"] = undo[@"applied"]; q[@"value"] = undo[@"before"];
                    NSString *revisionKey = (NSString *)[q[@"nodeToken"] stringByAppendingString:q[@"property"]];
                    if (!(BOOL)[((NSMutableDictionary *)macCURegistry[@"revisions"])[revisionKey] isEqual:undo[@"revision"]]) { reject(@"undoConflict", @"supersededRevision"); break; }
                }
                NSString *token = q[@"nodeToken"], *prop = q[@"property"];
                NSDictionary *record = ((NSMutableDictionary *)macCURegistry[@"nodes"])[token];
                if (!record || !(BOOL)[record[@"parentToken"] isEqual:q[@"expectedParentToken"]]
                    || !(BOOL)[record[@"windowToken"] isEqual:q[@"expectedWindowToken"]] || !(BOOL)[record[@"className"] isEqual:q[@"expectedClass"]]) {
                    reject(@"conflict", @"captureIdentityMismatch"); break;
                }
                UIView *view = (id)[(id)[(id)[map objectForKey:token] retain] autorelease];
                UIView *parent = q[@"expectedParentToken"] == [NSNull null] ? nil : (id)[(id)[(id)[map objectForKey:q[@"expectedParentToken"]] retain] autorelease];
                UIWindow *window = (id)[(id)[(id)[map objectForKey:q[@"expectedWindowToken"]] retain] autorelease];
                if (!view || !window || (q[@"expectedParentToken"] != [NSNull null] && !parent)) { reject(@"conflict", @"weakNil"); break; }
                auto identity = [&]() -> BOOL {
                    if (objc_getAssociatedObject(anchor, key) != macCURegistry || !(BOOL)[macCURegistry[@"registryState"] isEqual:@"active"]
                        || !(BOOL)[macCURegistry[@"captureID"] isEqual:q[@"captureID"]] || !(BOOL)[macCURegistry[@"epoch"] isEqual:q[@"targetEpoch"]]
                        || [map objectForKey:token] != view || [map objectForKey:q[@"expectedWindowToken"]] != window
                        || (parent && [map objectForKey:q[@"expectedParentToken"]] != parent)
                        || [view superview] != parent || (view != window && [view window] != window)
                        || !(BOOL)[NSStringFromClass([view class]) isEqual:q[@"expectedClass"]]) return NO;
                    NSArray *rows = graph(); if (!rows) return NO;
                    NSUInteger found = 0;
                    for (NSDictionary *row in rows) if (row[@"view"] == view && row[@"window"] == window
                        && (parent ? row[@"parent"] == parent : row[@"parent"] == [NSNull null])) found++;
                    return found == 1 && objc_getAssociatedObject(anchor, key) == macCURegistry
                        && [map objectForKey:token] == view && [view superview] == parent
                        && (view == window || [view window] == window)
                        && (BOOL)[NSStringFromClass([view class]) isEqual:q[@"expectedClass"]];
                };
                if (!identity()) { reject(@"conflict", @"staleGraph"); break; }
                BOOL isHidden = (BOOL)[prop isEqual:@"hidden"];
                NSNumber *before = isHidden ? @([view isHidden]) : @([view alpha]);
                out[@"nodeToken"] = token; out[@"property"] = prop; out[@"before"] = before; out[@"requested"] = q[@"value"];
                if (!(BOOL)[before isEqual:q[@"expectedValue"]]) { reject(@"conflict", @"expectedValueChanged"); out[@"observed"] = before; break; }
                if (!identity()) { reject(@"conflict", @"getterChangedIdentity"); break; }
                if ((BOOL)[before isEqual:q[@"value"]]) {
                    out[@"status"] = @"noChange"; out[@"reasonCode"] = @"alreadyEqual"; out[@"observed"] = before;
                    out[@"needsRefresh"] = @NO; out[@"postcondition"] = @"matched"; break;
                }
                if (operationCancelled()) { reject(@"failed", @"cancelledBeforeEntry"); break; }
                // Journal the entry BEFORE invoking exactly one typed setter. Interrupted
                // evaluation may leave busy=YES; no future expression resets it blindly.
                ((NSMutableDictionary *)((NSMutableDictionary *)macCURegistry[@"operations"])[op])[@"phase"] = @"setterEntering";
                out[@"phase"] = @"setterEntering"; out[@"setterEntered"] = @YES; entered = YES;
                out[@"mutationOutcome"] = @"uncertain";
                operationEntering();
                if (isHidden) [view setHidden:(BOOL)[q[@"value"] boolValue]]; else [view setAlpha:(double)[q[@"value"] doubleValue]];
                if (operationCancelled()) { reject(@"outcomeUncertain", @"cancelledAfterEntry"); out[@"mutationOutcome"] = @"enteredUnverified"; break; }
                NSNumber *observed = isHidden ? @([view isHidden]) : @([view alpha]);
                out[@"observed"] = observed;
                if (!identity() || !(BOOL)[observed isEqual:q[@"value"]]) { reject(@"outcomeUncertain", @"readbackOrIdentityMismatch"); out[@"postcondition"] = @"mismatched"; break; }
                // Traversal/getter overrides can change values while checking identity.
                observed = isHidden ? @([view isHidden]) : @([view alpha]); out[@"observed"] = observed;
                if (!(BOOL)[observed isEqual:q[@"value"]] || [view superview] != parent
                    || (view != window && [view window] != window) || objc_getAssociatedObject(anchor, key) != macCURegistry) {
                    reject(@"outcomeUncertain", @"finalReadbackOrIdentityMismatch"); break;
                }
                NSString *revisionKey = [token stringByAppendingString:prop];
                ((NSMutableDictionary *)macCURegistry[@"revisions"])[revisionKey] = q[@"sequence"];
                // Invalidate every earlier receipt for this exact property, including ABA.
                for (NSString *oldToken in (id)[(id)[[macCURegistry[@"undo"] allKeys] copy] autorelease]) {
                    NSDictionary *u = ((NSMutableDictionary *)macCURegistry[@"undo"])[oldToken];
                    if ((BOOL)[u[@"nodeToken"] isEqual:token] && (BOOL)[u[@"property"] isEqual:prop]) {
                        [(NSMutableDictionary *)macCURegistry[@"undo"] removeObjectForKey:oldToken]; [(NSMutableArray *)macCURegistry[@"undoOrder"] removeObject:oldToken];
                    }
                }
                if (!(BOOL)[kind isEqual:@"revert"]) {
                    NSString *undoToken = [[NSUUID UUID] UUIDString];
                    NSDictionary *u = @{@"nodeToken": token, @"property": prop, @"before": before, @"applied": observed,
                        @"revision": q[@"sequence"], @"expectedParentToken": q[@"expectedParentToken"],
                        @"expectedWindowToken": q[@"expectedWindowToken"], @"expectedClass": q[@"expectedClass"]};
                    ((NSMutableDictionary *)macCURegistry[@"undo"])[undoToken] = u; [(NSMutableArray *)macCURegistry[@"undoOrder"] addObject:undoToken];
                    while ((NSUInteger)[macCURegistry[@"undoOrder"] count] > 256) { [(NSMutableDictionary *)macCURegistry[@"undo"] removeObjectForKey:((NSArray *)macCURegistry[@"undoOrder"])[0]]; [(NSMutableArray *)macCURegistry[@"undoOrder"] removeObjectAtIndex:0]; }
                    out[@"undoToken"] = undoToken; out[@"undoReceipt"] = u;
                }
                out[@"propertyRevision"] = q[@"sequence"]; out[@"status"] = @"success"; out[@"reasonCode"] = @"readbackMatched";
                out[@"mutationOutcome"] = @"appliedObserved"; out[@"phase"] = @"readback"; out[@"needsRefresh"] = @NO; out[@"postcondition"] = @"matched";
            } while (NO);
#if defined(OBJC_ZEROCOST_EXCEPTIONS)
        } @catch (NSException *exception) {
            reject(entered ? @"outcomeUncertain" : @"failed", @"objectiveCException");
            out[@"mutationOutcome"] = entered ? @"uncertain" : @"notEntered";
            out[@"exceptionName"] = [[exception name] substringToIndex:MIN((NSUInteger)256, (NSUInteger)[[exception name] length])];
        }
#endif
        if (reserved && objc_getAssociatedObject(anchor, key) == macCURegistry) {
            if ((BOOL)[out[@"needsRefresh"] boolValue] && !(BOOL)[kind isEqual:@"release"]) {
                macCURegistry[@"registryState"] = @"quarantined";
                [macCURegistry removeObjectForKey:@"undo"]; [macCURegistry removeObjectForKey:@"undoOrder"];
            }
            ((NSMutableDictionary *)((NSMutableDictionary *)macCURegistry[@"operations"])[op])[@"phase"] = @"finished";
            NSMutableDictionary *cached = (id)[(id)[out mutableCopy] autorelease]; [cached removeObjectForKey:@"editableNodes"];
            [cached removeObjectForKey:@"hierarchy"]; [cached removeObjectForKey:@"textureJoins"]; [cached removeObjectForKey:@"editing"];
            if ((BOOL)[kind isEqual:@"capture"] && (BOOL)[out[@"status"] isEqual:@"success"]) {
                cached[@"status"] = @"resultUnavailable"; cached[@"reasonCode"] = @"capturePayloadNotCached"; cached[@"needsRefresh"] = @YES;
            }
            ((NSMutableDictionary *)macCURegistry[@"results"])[op] = cached; [(NSMutableArray *)macCURegistry[@"resultOrder"] addObject:op];
            while ((NSUInteger)[macCURegistry[@"resultOrder"] count] > 256) { [(NSMutableDictionary *)macCURegistry[@"results"] removeObjectForKey:((NSArray *)macCURegistry[@"resultOrder"])[0]]; [(NSMutableArray *)macCURegistry[@"resultOrder"] removeObjectAtIndex:0]; }
            macCURegistry[@"busy"] = @NO;
        }
