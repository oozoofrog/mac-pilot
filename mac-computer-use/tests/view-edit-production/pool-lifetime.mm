// Included after main.mm with its entry renamed. Executes the canonical expression.
static NSUInteger SentinelCreated, SentinelDeallocated;
@interface PoolSentinel : NSObject @end
@implementation PoolSentinel
- (instancetype)init { if ((self = [super init])) SentinelCreated++; return self; }
- (void)dealloc { SentinelDeallocated++; [super dealloc]; }
@end
@interface PoolTarget : UIView @end
@implementation PoolTarget
- (void)setHidden:(BOOL)value { [[[PoolSentinel alloc] init] autorelease]; [super setHidden:value]; }
@end

int main(int argc, const char **argv) {
    if (argc != 3 || strcmp(argv[1], "--native-check") || getenv("MAC_CU_NATIVE_CHECK_CHILD")) return 64;
    @autoreleasepool {
        Output = [NSString stringWithUTF8String:argv[2]];
        NSString *token = nil;
        @autoreleasepool {
            Reset(); [TestView removeFromSuperview]; [TestView release];
            TestView = [PoolTarget new]; [TestWindow addSubview:TestView];
            NSMutableDictionary *q = Capture(); NSDictionary *cap = Call(q);
            NSMutableDictionary *e = Edit(q, cap); token = [e[@"nodeToken"] copy];
            Status(Call(e), @"success", @"readbackMatched");
            Check(TestView->_hidden && TestView->_setterCalls == 1 && SentinelCreated == 1,
                  @"one actual setter creates one autoreleased sentinel");
            [TestView removeFromSuperview]; [TestView release]; TestView = nil;
            Check(SentinelDeallocated == 1, @"successful expression drains its local pool in either compiler mode");
            Check([State()[@"map"] objectForKey:token] == nil, @"local traversal retention ends on return");
        }
        Check(SentinelDeallocated == 1, @"caller pool drain releases the sentinel exactly once");
        Check([State()[@"map"] objectForKey:token] == nil, @"caller drain releases traversal; registry stays weak");
        [token release]; Reset();
        printf("PASS canonical expression pool lifetime: %lu assertions; exceptions=%d\n",
               (unsigned long)Assertions,
#if defined(OBJC_ZEROCOST_EXCEPTIONS)
               1
#else
               0
#endif
        );
    }
    return 0;
}
