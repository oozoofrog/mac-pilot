#import <Foundation/Foundation.h>

@interface FakeView : NSObject
@property(nonatomic, weak) FakeView *parent;
@property(nonatomic, weak) FakeView *window;
@property(nonatomic, strong) NSMutableArray<FakeView *> *children;
@property(nonatomic) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic) NSUInteger setters;
@property(nonatomic, copy) NSString *behavior;
@property(nonatomic, copy) void (^hook)(void);
- (void)apply:(NSString *)property value:(NSNumber *)value;
@end

// Deliberately in-memory algorithm fixture, not a durable host journal or service.
@interface OperationDriver : NSObject
@property(nonatomic, strong) FakeView *root;
@property(nonatomic, strong) NSMapTable<NSString *, FakeView *> *map;
@property(nonatomic, strong) NSMutableDictionary *journal;
@property(nonatomic, strong) NSMutableDictionary *undo;
@property(nonatomic) NSUInteger highWater;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL quarantined;
@property(nonatomic) BOOL released;
@property(nonatomic) double expires;
@property(nonatomic, copy) NSString *generation;
- (instancetype)initWithRoot:(FakeView *)root node:(FakeView *)node;
- (NSDictionary *)request:(NSString *)op sequence:(NSUInteger)sequence property:(NSString *)property
                 expected:(id)expected value:(id)value generation:(NSString *)generation
                    token:(NSString *)token parent:(NSString *)parent window:(NSString *)window
                    klass:(NSString *)klass now:(double)now;
- (NSDictionary *)revert:(NSString *)undoID operation:(NSString *)op sequence:(NSUInteger)sequence;
- (void)releaseCapture;
@end
