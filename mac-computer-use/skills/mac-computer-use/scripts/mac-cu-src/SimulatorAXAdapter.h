#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class NSAccessibilityCustomAction;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SAXStatus) {
    SAXOK, SAXNil, SAXUnsupportedSelector, SAXUnsupportedABI, SAXUnsupportedCapability,
    SAXInvalidResult, SAXException, SAXRedacted, SAXInvalidInput, SAXLimitExceeded
};
typedef NS_ENUM(NSInteger, SAXMutationOutcome) {
    SAXNotEntered, SAXDispatched, SAXRejected, SAXUncertain
};
typedef NS_ENUM(NSInteger, SAXProtection) { SAXProtectionUnknown, SAXProtectionClear, SAXProtectionProtected };
typedef NS_ENUM(NSInteger, SAXField) {
    SAXChildren, SAXParent, SAXRole, SAXSubrole, SAXRoleDescription, SAXTitle,
    SAXLabel, SAXIdentifier, SAXValue, SAXHelp, SAXEnabled, SAXFrame, SAXActivationPoint,
    SAXActions, SAXCustomActions, SAXProtectedContent, SAXAttributes, SAXTranslation, SAXFocused, SAXSelectedTextRange
};
typedef NS_ENUM(NSInteger, SAXAction) { SAXPress, SAXIncrement, SAXDecrement, SAXEscape };

/// ARC-owned result. Nil, empty collections/strings, unsupported, and exception are distinct.
/// objectValue contains only validated objects; arrays are shallow immutable copies (max 1024).
/// Opaque element/translation/custom-action references MUST remain in the caller's bounded session.
@interface SAXResult : NSObject
@property(nonatomic, readonly) SAXStatus status;
@property(nonatomic, readonly, nullable, strong) id objectValue;
@property(nonatomic, readonly) SAXMutationOutcome mutationOutcome;
/// True immediately before invoking the AXValue setter. Exception then means uncertain delivery.
@property(nonatomic, readonly) BOOL setterEntered;
@property(nonatomic, readonly, copy) NSString *diagnostic;
@end

/// No framework loading, queue ownership, retries, or session authorization.
/// Singleton access and caller-owned bridge completion dispatch are explicit closed operations.
/// Caller supplies already-owned objects. Serialized use with stable method metadata is required.
@interface SimulatorAXAdapter : NSObject
+ (SAXResult *)sharedTranslator;
+ (SAXResult *)customActionName:(NSAccessibilityCustomAction *)action;
+ (SAXResult *)sendRequest:(id)request device:(id)device queue:(dispatch_queue_t)queue completion:(void (^)(id _Nullable))completion;
+ (SAXResult *)frontApplication:(id)translator display:(uint32_t)display token:(NSString *)token;
+ (SAXResult *)platformElement:(id)translator translation:(id)translation;
+ (SAXResult *)elementAtPoint:(CGPoint)point translator:(id)translator display:(uint32_t)display token:(NSString *)token;
+ (SAXResult *)installBridgeDelegate:(id)delegate translator:(id)translator;
+ (SAXResult *)setToken:(NSString *)token translation:(id)translation;
+ (SAXResult *)token:(id)translation;
+ (SAXResult *)pid:(id)translation;
+ (SAXResult *)objectID:(id)translation;
/// Clear requires caller-established guest protection evidence; inherited AppKit NO alone is insufficient.
+ (SAXResult *)read:(SAXField)field element:(id)element protection:(SAXProtection)protection;
+ (SAXResult *)valueSettable:(id)element protection:(SAXProtection)protection;
/// qualified is the caller's CURRENT fixture/runtime qualification, never inferred from method existence.
+ (SAXResult *)dispatch:(SAXAction)action element:(id)element qualified:(BOOL)qualified;
/// Only NSString (<=65536 UTF-16 units), finite NSNumber/bool. Caller validates guest type and bounds.
+ (SAXResult *)setValue:(id)value element:(id)element protection:(SAXProtection)protection qualified:(BOOL)qualified;
/// Exact action object from current session, identity-checked against current advertised actions.
/// Never resolves by name; selector is obtained only from the retained system action.
+ (SAXResult *)invokeCustomAction:(NSAccessibilityCustomAction *)action element:(id)element qualified:(BOOL)qualified;
@end
NS_ASSUME_NONNULL_END
