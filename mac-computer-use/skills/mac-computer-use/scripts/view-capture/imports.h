@import Foundation;
@import UIKit;
@import Darwin;
// Declarations only: the implementation belongs to Apple's private runtime support.
@interface NSObject (MacCUHierarchyRequest)
+ (id)sharedHub;
- (NSData *)performRequestWithRequestInBase64:(NSString *)request;
@end
