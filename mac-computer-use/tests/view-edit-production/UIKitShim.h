// Headless UIKit-shaped Foundation objects. Only edit.expr supplies the algorithm.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreGraphics/CGGeometry.h>
#include <math.h>
#define CGRectGetMaxX(r) ((r).origin.x + (r).size.width)
#define CGRectGetMaxY(r) ((r).origin.y + (r).size.height)
#define CGRectGetMinX(r) ((r).origin.x)
#define CGRectGetMinY(r) ((r).origin.y)
#define dlopen(path, flags) ((void *)1)

@interface UIScreen : NSObject
- (id)fixedCoordinateSpace;
- (CGFloat)scale;
@end
@class UIWindow, UIWindowScene;
@interface UIView : NSObject {
@public
    NSMutableArray *_children;
    UIView *_parent;
    BOOL _hidden;
    CGFloat _alpha;
    NSString *_mode;
    NSUInteger _setterCalls;
}
- (NSArray *)subviews;
- (UIView *)superview;
- (UIWindow *)window;
- (CGRect)frame;
- (CGRect)bounds;
- (CGPoint)convertPoint:(CGPoint)p toView:(UIView *)view;
- (BOOL)isHidden;
- (CGFloat)alpha;
- (void)setHidden:(BOOL)value;
- (void)setAlpha:(CGFloat)value;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
@end
@interface UIWindow : UIView
- (UIScreen *)screen;
- (UIWindowScene *)windowScene;
- (CGPoint)convertPoint:(CGPoint)p toCoordinateSpace:(id)space;
@end
@interface UIScene : NSObject @end
@interface UISceneSession : NSObject
- (NSString *)persistentIdentifier;
@end
@interface UIWindowScene : UIScene
- (NSArray *)windows;
- (UISceneSession *)session;
@end
@interface UIApplication : NSObject
+ (id)sharedApplication;
- (NSSet *)connectedScenes;
- (NSArray *)windows;
@end
static UIWindow *TestWindow;
static UIView *TestView;
static BOOL ReentrantBusyObserved;

@implementation UIScreen
- (id)fixedCoordinateSpace { return self; }
- (CGFloat)scale { return 1; }
@end
@implementation UIView
- (id)init { if ((self = [super init])) { _children = [[NSMutableArray alloc] init]; _alpha = 1; } return self; }
- (void)dealloc { [_children release]; [_mode release]; [super dealloc]; }
- (NSArray *)subviews { return _children; }
- (UIView *)superview { return _parent; }
- (UIWindow *)window { UIView *v = self; while (v->_parent) v = v->_parent; return [v isKindOfClass:[UIWindow class]] ? (UIWindow *)v : nil; }
- (CGRect)frame { return (CGRect){{1, 2}, {30, 40}}; }
- (CGRect)bounds { return (CGRect){{0, 0}, {30, 40}}; }
- (CGPoint)convertPoint:(CGPoint)p toView:(UIView *)view { (void)view; return p; }
- (BOOL)isHidden { return _hidden; }
- (CGFloat)alpha { return _alpha; }
- (void)addSubview:(UIView *)view { [view retain]; [view removeFromSuperview]; [_children addObject:view]; view->_parent = self; [view release]; }
- (void)removeFromSuperview { UIView *p = _parent; _parent = nil; if (p) [p->_children removeObjectIdenticalTo:self]; }
- (void)beforeSet {
    _setterCalls++;
    if ([_mode isEqual:@"throwBefore"]) [NSException raise:@"FixtureException" format:@"before write"];
    if ([_mode isEqual:@"reentrant"]) {
        id s = objc_getAssociatedObject((id)objc_getClass("NSObject"), (const void *)sel_registerName("org.oozoofrog.macCu.viewInspection.registry.v1"));
        ReentrantBusyObserved = [s[@"busy"] boolValue] && [s[@"operations"][s[@"testOperation"]][@"phase"] isEqual:@"setterEntering"];
    }
}
- (void)afterSet {
    if ([_mode isEqual:@"throwAfter"]) [NSException raise:@"FixtureException" format:@"after write"];
    if ([_mode isEqual:@"detach"]) [self removeFromSuperview];
}
- (void)setHidden:(BOOL)v { [self beforeSet]; if (![_mode isEqual:@"mismatch"]) _hidden = v; [self afterSet]; }
- (void)setAlpha:(CGFloat)v { [self beforeSet]; if (![_mode isEqual:@"mismatch"]) _alpha = v; [self afterSet]; }
@end
@implementation UIWindow
- (UIScreen *)screen { static UIScreen *screen; if (!screen) screen = [UIScreen new]; return screen; }
- (UIWindowScene *)windowScene { static UIWindowScene *scene; if (!scene) scene = [UIWindowScene new]; return scene; }
- (CGPoint)convertPoint:(CGPoint)p toCoordinateSpace:(id)space { (void)space; return p; }
@end
@implementation UIScene @end
@implementation UISceneSession
- (NSString *)persistentIdentifier { return @"headless-fixture-scene"; }
@end
@implementation UIWindowScene
- (NSArray *)windows { return TestWindow ? @[TestWindow] : @[]; }
- (UISceneSession *)session { static UISceneSession *session; if (!session) session = [UISceneSession new]; return session; }
@end
@implementation UIApplication
+ (id)sharedApplication { static UIApplication *app; if (!app) app = [UIApplication new]; return app; }
- (NSSet *)connectedScenes { return [NSSet setWithObject:[[[UIWindowScene alloc] init] autorelease]]; }
- (NSArray *)windows { return TestWindow ? @[TestWindow] : @[]; }
@end

@interface DBGTargetHub : NSObject
+ (id)sharedHub;
- (NSData *)performRequestWithRequestInBase64:(NSString *)request;
@end
static NSDictionary *FixtureTextureNode(UIView *view) {
    NSMutableArray *children = [NSMutableArray array];
    for (UIView *child in [view subviews]) [children addObject:FixtureTextureNode(child)];
    return @{@"objectID": [NSString stringWithFormat:@"%p", (void *)view], @"className": NSStringFromClass([view class]),
        @"properties": @[@{@"propertyName": @"snapshotImage", @"propertyFormat": @"image", @"propertyRuntimeType": @"UIImage", @"fetchStatus": @4,
            @"propertyValue": @{@"imageData": @"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a6cAAAAASUVORK5CYII=",
                @"metadata": @{@"width": @30, @"height": @40}}}],
        @"childGroup": @{@"debugHierarchyObjects": children}};
}
@implementation DBGTargetHub
+ (id)sharedHub { static DBGTargetHub *hub; if (!hub) hub = [DBGTargetHub new]; return hub; }
- (NSData *)performRequestWithRequestInBase64:(NSString *)request {
    if (!request) return nil;
    NSData *wire = [[[NSData alloc] initWithBase64EncodedString:request options:0] autorelease];
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:wire options:0 error:NULL];
    if (![decoded[@"DBGHierarchyRequestActions"][0][@"propertyNames"] containsObject:@"snapshotImage"]) return nil;
    NSDictionary *response = @{@"topLevelGroups": @{@"com.apple.UIKit.UIWindow": @{@"debugHierarchyObjects": @[FixtureTextureNode(TestWindow)]}}};
    return [NSJSONSerialization dataWithJSONObject:response options:0 error:NULL];
}
@end
