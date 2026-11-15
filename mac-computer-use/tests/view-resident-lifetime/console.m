#import <Foundation/Foundation.h>
#include "resident.h"
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>

static id currentTarget;
static __weak id weakTarget, weakSentinel;
static int writes, deallocations, targetDeallocations;
static atomic_int finiteEntered;
static const char *mode, *directory;
static ResidentRequest request;

@interface ResidentConsoleSentinel : NSObject @end
@implementation ResidentConsoleSentinel
- (void)dealloc { ++deallocations; [super dealloc]; }
@end
@interface ResidentConsoleTarget : NSObject
+ (id)current;
@end
@implementation ResidentConsoleTarget
+ (id)current { return currentTarget; }
- (NSString *)generation { return @"11111111-1111-4111-8111-111111111111"; }
- (NSUInteger)hiddenSetterCount { return (NSUInteger)writes; }
- (BOOL)isHidden { return writes != 0; }
- (void)setHidden:(BOOL)value {
    if (!value) abort();
    ++writes;
    id sentinel = [[[ResidentConsoleSentinel alloc] init] autorelease]; weakSentinel = sentinel;
    if (!strcmp(mode, "throw")) [NSException raise:@"ConsoleWriteThenThrow" format:@"finite control"];
    if (!strcmp(mode, "cancel")) { atomic_store(&finiteEntered, 1); usleep(300000); }
}
- (void)dealloc { ++targetDeallocations; [super dealloc]; }
@end

static void cancelNow(void) {
    char path[1200]; snprintf(path, sizeof(path), "%s/cancel", directory);
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600);
    if (fd < 0 || write(fd, request.digest, 64) != 64 || close(fd)) abort();
}
static void cancellation(void *unused) {
    (void)unused;
    for (int i = 0; i < 2000 && !atomic_load(&finiteEntered); ++i) usleep(1000);
    if (!atomic_load(&finiteEntered)) abort();
    cancelNow();
}
static void verify(void *unused) {
    (void)unused;
    @autoreleasepool {
        NSString *path = [NSString stringWithFormat:@"%s/terminal.json", directory];
        NSDictionary *r = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
        BOOL pre = !strcmp(mode, "pre-cancel"), throwing = !strcmp(mode, "throw");
        NSString *expectedOutcome = pre ? @"cancelledBeforeEntry" : throwing ? @"uncertain" : @"enteredUnverified";
        BOOL ok = r && [r[@"poolExited"] boolValue] && [r[@"operationContexts"] intValue] == 0 &&
            [r[@"outcome"] isEqualToString:expectedOutcome] &&
            [r[@"traced"] intValue] == 0 && [r[@"mainThread"] boolValue] &&
            [r[@"setterEntered"] boolValue] == !pre && [r[@"caught"] boolValue] == throwing &&
            writes == !pre && deallocations == !pre && weakSentinel == nil &&
            [r[@"workFinishedNS"] unsignedLongLongValue] <= [r[@"poolExitedNS"] unsignedLongLongValue] &&
            [r[@"poolExitedNS"] unsignedLongLongValue] <= [r[@"publicationNS"] unsignedLongLongValue] &&
            mac_cu_resident_submit(directory) == -5;
        if (!strcmp(mode, "cancel") || pre) ok &= [r[@"cancelObserved"] boolValue];
        [currentTarget release]; currentTarget = nil;
        ok &= weakTarget == nil && targetDeallocations == 1;
        printf("%s %s: one-or-zero write, independent sentinel dealloc, weak target nil, ordered pool/publication, zero context, replay refused\n", ok ? "PASS" : "FAIL", mode);
        exit(ok ? 0 : 1);
    }
}
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--native-check") || getenv("MAC_CU_NATIVE_CHECK_CHILD") ||
        getenv("MAC_CU_RESIDENT_CONSOLE_CHILD")) return 64;
    directory = getenv("RESIDENT_CONSOLE_DIRECTORY"); mode = getenv("RESIDENT_CONSOLE_MODE");
    if (!directory || !mode || (strcmp(mode, "throw") && strcmp(mode, "cancel") && strcmp(mode, "pre-cancel") && strcmp(mode, "normal"))) return 64;
    setenv("MAC_CU_RESIDENT_CONSOLE_CHILD", "1", 1);
    @autoreleasepool {
        currentTarget = [[ResidentConsoleTarget alloc] init]; weakTarget = currentTarget;
        memcpy(request.magic, "MCURL1\0", 8); request.operation = request.sequence = 1; request.pid = getpid();
        struct kinfo_proc info = {0}; int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()}; size_t length = sizeof(info);
        if (sysctl(mib, 4, &info, &length, NULL, 0) || length != sizeof(info)) return 1;
        request.startSec = info.kp_proc.p_starttime.tv_sec; request.startUsec = info.kp_proc.p_starttime.tv_usec;
        request.expiresUnixMS = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000) + 10000;
        strlcpy(request.owner, "22222222-2222-4222-8222-222222222222", sizeof(request.owner));
        strlcpy(request.operationID, "33333333-3333-4333-8333-333333333333", sizeof(request.operationID));
        strlcpy(request.device, "44444444-4444-4444-8444-444444444444", sizeof(request.device));
        strlcpy(request.generation, "11111111-1111-4111-8111-111111111111", sizeof(request.generation));
        strlcpy(request.scene, "console", sizeof(request.scene)); strlcpy(request.parent, "console", sizeof(request.parent));
        char path[1024], resolved[PATH_MAX]; uint32_t size = sizeof(path);
        if (_NSGetExecutablePath(path, &size) || !realpath(path, resolved)) return 1;
        strlcpy(request.executable, resolved, sizeof(request.executable));
        Dl_info image;
        if (!dladdr((void *)&mac_cu_resident_submit, &image) || !realpath(image.dli_fname, resolved)) return 1;
        strlcpy(request.image, resolved, sizeof(request.image));
        const struct mach_header_64 *header = image.dli_fbase;
        const char *p = (const char *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; ++i) {
            const struct load_command *c = (const void *)p;
            if (c->cmd == LC_UUID) uuid_unparse_upper(((const struct uuid_command *)c)->uuid, request.imageUUID);
            p += c->cmdsize;
        }
        unsigned char hash[32];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_SHA256(&request, offsetof(ResidentRequest, digest), hash);
#pragma clang diagnostic pop
        for (int i = 0; i < 32; ++i) snprintf(request.digest + i * 2, 3, "%02x", hash[i]);
        setenv("MAC_CU_FIXTURE_SESSION", request.owner, 1); setenv("SIMULATOR_UDID", request.device, 1);
        snprintf(path, sizeof(path), "%s/request.bin", directory);
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0 || write(fd, &request, sizeof(request)) != sizeof(request) || close(fd)) return 1;
        if (!strcmp(mode, "pre-cancel")) cancelNow();
        if (mac_cu_resident_submit(directory) != 1) return 1;
        if (!strcmp(mode, "cancel")) dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), NULL, cancellation);
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), NULL, verify);
    }
    // Keep pthread main as the main-queue execution thread; CLI language control only.
    CFRunLoopRun();
    return 1;
}
