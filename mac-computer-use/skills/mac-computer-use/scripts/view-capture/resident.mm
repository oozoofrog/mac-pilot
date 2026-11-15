#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "imports.h"
#include "resident.h"
#import "SwiftUIBridge-Swift.h"
#define MAC_CU_SWIFTUI_BRIDGE 1
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <atomic>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#import <objc/runtime.h>

#if __has_feature(objc_arc) || !defined(OBJC_ZEROCOST_EXCEPTIONS)
#error This helper requires explicit MRC and Objective-C exceptions
#endif

// Only scalar tombstones remain for this image's lifetime. Never reset or unload.
// 0 idle, 1 submitted/running, 2 quarantined. Only completed terminal publication returns to idle.
static std::atomic<int> admission{0};
static std::atomic<int> operationContexts{0};
typedef struct { ResidentRequest request; int directory; unsigned char *payload; } Operation;
static void callback(void *opaque);

static uint64_t millis(void) {
    struct timeval t; gettimeofday(&t, NULL);
    return (uint64_t)t.tv_sec * 1000 + t.tv_usec / 1000;
}
static uint64_t nanos(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static int privateDirectory(const char *path) {
    if (!path || path[0] != '/' || strnlen(path, 1024) >= 1024) return -1;
    char copy[1024]; strlcpy(copy, path + 1, sizeof(copy));
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    char *save = NULL, *part = strtok_r(copy, "/", &save);
    if (!part) { close(fd); return -1; }
    while (part && fd >= 0) {
        if (!strcmp(part, ".") || !strcmp(part, "..")) { close(fd); return -1; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next; part = strtok_r(NULL, "/", &save);
    }
    struct stat s;
    if (fd < 0) return -1;
    if (fstat(fd, &s) || !S_ISDIR(s.st_mode) || s.st_uid != getuid() || (s.st_mode & 077) != 0) {
        close(fd); return -1;
    }
    return fd;
}
static BOOL fileShape(int fd, off_t length) {
    struct stat s;
    return fd >= 0 && !fstat(fd, &s) && S_ISREG(s.st_mode) && s.st_uid == getuid() &&
        (s.st_mode & 077) == 0 && s.st_nlink == 1 && s.st_size == length;
}
static BOOL readRequest(int directory, ResidentRequest *r, unsigned char **payload) {
    int fd = openat(directory, "request.bin", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat shape;
    BOOL ok = fd >= 0 && !fstat(fd, &shape) && shape.st_size > (off_t)sizeof(*r) && shape.st_size <= (off_t)sizeof(*r) + 65536;
    ok = ok && fileShape(fd, shape.st_size) && pread(fd, r, sizeof(*r), 0) == sizeof(*r)
        && r->payloadLength > 0 && r->payloadLength <= 65536 && shape.st_size == (off_t)(sizeof(*r) + r->payloadLength);
    if (ok) {
        *payload = (unsigned char *)malloc((size_t)r->payloadLength);
        ok = *payload && pread(fd, *payload, (size_t)r->payloadLength, sizeof(*r)) == (ssize_t)r->payloadLength;
    }
    if (fd >= 0) close(fd);
    if (!ok && *payload) { free(*payload); *payload = NULL; }
    return ok;
}
static BOOL publish(int directory, const char *name, const char *bytes, size_t length) {
    if (length == 0 || length > 16777216) return NO;
    char temporary[64]; snprintf(temporary, sizeof(temporary), "%s.stage", name);
    int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    BOOL ok = write(fd, bytes, length) == (ssize_t)length && fsync(fd) == 0;
    if (close(fd)) ok = NO;
    // linkat is no-replace publication. A preexisting answer is always a refusal.
    if (ok) ok = linkat(directory, temporary, directory, name, 0) == 0;
    unlinkat(directory, temporary, 0);
    if (ok) ok = fsync(directory) == 0;
    return ok;
}
static int cancelled(int directory, const char *digest) {
    int fd = openat(directory, "cancel", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    char bytes[64];
    BOOL ok = fileShape(fd, sizeof(bytes)) && pread(fd, bytes, sizeof(bytes), 0) == sizeof(bytes) &&
        !memcmp(bytes, digest, sizeof(bytes));
    close(fd); return ok ? 1 : -1;
}
static BOOL textField(const char *s, size_t n) {
    size_t length = strnlen(s, n);
    if (!length || length == n) return NO;
    for (size_t i = 0; i < length; ++i) if (s[i] < 32 || s[i] > 126 || s[i] == '"' || s[i] == '\\') return NO;
    for (size_t i = length; i < n; ++i) if (s[i]) return NO;
    return YES;
}
static BOOL uuidField(const char *s) { uuid_t value; return strnlen(s, 37) == 36 && uuid_parse(s, value) == 0; }
static BOOL validRequest(const ResidentRequest *r, const unsigned char *payload) {
    if (memcmp(r->magic, "MCURP2\0", 8) || r->abi != 2 || r->sequence < 1 || r->sequence > 4096 ||
        r->pid != (uint64_t)getpid() || r->startUsec >= 1000000 ||
        !uuidField(r->owner) || !uuidField(r->operationID) || !uuidField(r->device) || !uuidField(r->imageUUID) ||
        !textField(r->executable, sizeof(r->executable)) || !textField(r->image, sizeof(r->image)) ||
        r->digest[64] || r->expiresUnixMS < millis() || r->expiresUnixMS > millis() + 120000) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[65];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, r, (CC_LONG)offsetof(ResidentRequest, digest));
    CC_SHA256_Update(&context, payload, (CC_LONG)r->payloadLength);
    CC_SHA256_Final(digest, &context);
#pragma clang diagnostic pop
    for (int i = 0; i < 32; ++i) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    return !memcmp(hex, r->digest, 65);
}
static BOOL identity(const ResidentRequest *r, int *traced) {
    struct kinfo_proc info; memset(&info, 0, sizeof(info));
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()}; size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) || size != sizeof(info)) return NO;
    *traced = (info.kp_proc.p_flag & P_TRACED) != 0;
    char path[1024], resolved[PATH_MAX]; uint32_t n = sizeof(path);
    if (_NSGetExecutablePath(path, &n) || !realpath(path, resolved) || strcmp(resolved, r->executable)) return NO;
    const char *device = getenv("SIMULATOR_UDID");
    return device && !strcasecmp(device, r->device) &&
        (uint64_t)info.kp_proc.p_starttime.tv_sec == r->startSec &&
        (uint64_t)info.kp_proc.p_starttime.tv_usec == r->startUsec;
}
static BOOL imageIdentity(const ResidentRequest *r, Dl_info *image, char observedUUID[37]) {
    if (!dladdr((void *)&callback, image) || !image->dli_fbase || !image->dli_fname) return NO;
    char resolved[PATH_MAX];
    if (!realpath(image->dli_fname, resolved) || strcmp(resolved, r->image)) return NO;
    const struct mach_header_64 *header = (const struct mach_header_64 *)image->dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->ncmds > 1024 || header->sizeofcmds > 1024 * 1024) return NO;
    const uint8_t *p = (const uint8_t *)(header + 1), *end = p + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (p + sizeof(struct load_command) > end) return NO;
        const struct load_command *c = (const struct load_command *)p;
        if (c->cmdsize < sizeof(*c) || c->cmdsize > (size_t)(end - p)) return NO;
        if (c->cmd == LC_UUID && c->cmdsize == sizeof(struct uuid_command)) {
            char value[37]; uuid_unparse_upper(((const struct uuid_command *)c)->uuid, value);
            strlcpy(observedUUID, value, 37);
            return !strcasecmp(value, r->imageUUID);
        }
        p += c->cmdsize;
    }
    return NO;
}

static NSMutableDictionary *executeOperation(NSMutableDictionary *q, Operation *nativeOperation) {
    auto operationCancelled = [&]() -> BOOL {
        return cancelled(nativeOperation->directory, nativeOperation->request.digest) != 0
            || millis() > nativeOperation->request.expiresUnixMS;
    };
    auto operationEntering = [&]() {
        char bytes[128]; int length = snprintf(bytes, sizeof(bytes),
            "{\"phase\":\"entered\",\"monotonicNS\":%llu}", (unsigned long long)nanos());
        if (!publish(nativeOperation->directory, "entered.json", bytes, (size_t)length))
            @throw [NSException exceptionWithName:@"MacCUEntryPublication" reason:nil userInfo:nil];
    };
#include "operation.inc"
    return out;
}

static void callback(void *opaque) {
    Operation *op = (Operation *)opaque;
    int fd = op->directory, traced = -1;
    Dl_info image = {}; char observedUUID[37] = {0};
    uint64_t callbackAt = nanos(), workAt = 0;
    unsigned char *staged = NULL; size_t stagedLength = 0;
    BOOL quarantined = YES, cancelledAfter = NO;
    @autoreleasepool {
        @try {
            BOOL valid = identity(&op->request, &traced) && imageIdentity(&op->request, &image, observedUUID);
            if (valid && pthread_main_np() && traced == 0) {
                NSData *input = [NSData dataWithBytes:op->payload length:(NSUInteger)op->request.payloadLength];
                NSMutableDictionary *q = [NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingMutableContainers error:NULL];
                if ([q isKindOfClass:[NSMutableDictionary class]] && [q[@"schemaVersion"] isEqual:@2]
                    && [q[@"operationID"] isEqual:[NSString stringWithUTF8String:op->request.operationID]]
                    && [q[@"ownerID"] isEqual:[NSString stringWithUTF8String:op->request.owner]]
                    && [q[@"sequence"] unsignedLongLongValue] == op->request.sequence
                    && [@[@"capture", @"edit", @"revert", @"release"] containsObject:q[@"kind"]]) {
                    NSMutableDictionary *answer = executeOperation(q, op);
                    cancelledAfter = cancelled(fd, op->request.digest) != 0;
                    quarantined = cancelledAfter || [answer[@"mutationOutcome"] isEqual:@"uncertain"]
                        || [answer[@"mutationOutcome"] isEqual:@"enteredUnverified"];
                    answer[@"validationOnly"] = q[@"validationOnly"];
                    NSData *bytes = [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL];
                    if (bytes && bytes.length <= 16777216) {
                        stagedLength = bytes.length; staged = (unsigned char *)malloc(stagedLength);
                        if (staged) memcpy(staged, bytes.bytes, stagedLength);
                    }
                }
            }
        } @catch (id exception) {
            (void)exception; quarantined = YES;
        }
        workAt = nanos();
        char work[128]; int length = snprintf(work, sizeof(work), "{\"phase\":\"workFinished\",\"monotonicNS\":%llu}", (unsigned long long)workAt);
        if (!publish(fd, "work-finished.json", work, (size_t)length)) quarantined = YES;
    }
    // Only C-owned bounded bytes survive this point. Target views, all traversal
    // collections, temporary textures, caught exceptions and q/out have drained.
    uint64_t poolAt = nanos();
    char operationID[37], digest[65]; strlcpy(operationID, op->request.operationID, sizeof(operationID));
    strlcpy(digest, op->request.digest, sizeof(digest));
    free(op->payload); memset(op, 0, sizeof(*op)); free(op); operationContexts.fetch_sub(1);
    BOOL answerPublished = staged && publish(fd, "answer.json", (const char *)staged, stagedLength);
    free(staged);
    if (!answerPublished) quarantined = YES;
    char terminal[2048]; int length = snprintf(terminal, sizeof(terminal),
        "{\"abi\":2,\"operationID\":\"%s\",\"requestDigest\":\"%s\",\"mainThread\":%s,\"traced\":%d,"
        "\"callbackPC\":%llu,\"imageUUID\":\"%s\",\"callbackNS\":%llu,\"workFinishedNS\":%llu,"
        "\"poolExitedNS\":%llu,\"publicationNS\":%llu,\"poolExited\":true,\"operationContexts\":%d,"
        "\"quarantined\":%s,\"cancelObserved\":%s,\"answerPublished\":%s}",
        operationID, digest, pthread_main_np() ? "true" : "false", traced,
        (unsigned long long)(uintptr_t)&callback, observedUUID, (unsigned long long)callbackAt,
        (unsigned long long)workAt, (unsigned long long)poolAt, (unsigned long long)nanos(), operationContexts.load(),
        quarantined ? "true" : "false", cancelledAfter ? "true" : "false", answerPublished ? "true" : "false");
    BOOL terminalPublished = length > 0 && (size_t)length < sizeof(terminal) && publish(fd, "terminal.json", terminal, (size_t)length);
    admission.store(terminalPublished && !quarantined ? 0 : 2);
    close(fd);
}

int mac_cu_resident_submit_v2(const char *directory) {
    if (!pthread_main_np()) return -1;
    int fd = privateDirectory(directory); if (fd < 0) return -2;
    ResidentRequest request; unsigned char *payload = NULL;
    int traced = -1; Dl_info image = {}; char observedUUID[37] = {0};
    if (!readRequest(fd, &request, &payload) || !validRequest(&request, payload)
        || !identity(&request, &traced) || !imageIdentity(&request, &image, observedUUID) || traced != 1) {
        free(payload); close(fd); return -3;
    }
    int expected = 0;
    if (!admission.compare_exchange_strong(expected, 1)) { free(payload); close(fd); return -5; }
    Operation *op = (Operation *)calloc(1, sizeof(*op));
    if (!op) { admission.store(2); free(payload); close(fd); return -6; }
    op->request = request; op->directory = fd; op->payload = payload; operationContexts.fetch_add(1);
    char accepted[256]; int length = snprintf(accepted, sizeof(accepted),
        "{\"phase\":\"accepted\",\"monotonicNS\":%llu,\"operationID\":\"%s\",\"requestDigest\":\"%s\"}",
        (unsigned long long)nanos(), request.operationID, request.digest);
    if (!publish(fd, "accepted.json", accepted, (size_t)length)) {
        free(payload); free(op); operationContexts.fetch_sub(1); admission.store(2); close(fd); return -7;
    }
    dispatch_async_f(dispatch_get_main_queue(), op, callback);
    return 1;
}
