#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

// Fixture-only Objective-C frames: an NSException must not cross a Swift setter.
@interface MacCUQualificationEditTarget : UIView
@property(nonatomic, readonly) NSString *generation;
@property(nonatomic, readonly) NSUInteger hiddenSetterCount;
@property(nonatomic, readonly) NSUInteger alphaSetterCount;
- (BOOL)armFault:(NSString *)mode requestID:(NSString *)requestID;
+ (NSDictionary *)eventSnapshot;
@end
NS_ASSUME_NONNULL_END
