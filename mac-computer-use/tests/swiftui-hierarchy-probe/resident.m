#import <Foundation/Foundation.h>
#ifndef RESIDENT_HOST_CONTROL
#import <UIKit/UIKit.h>
#endif
#include "resident.h"
#import "ProbeBridge-Swift.h"
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#include <uuid/uuid.h>
#import <objc/runtime.h>
#import <objc/message.h>

#if __has_feature(objc_arc) || !defined(OBJC_ZEROCOST_EXCEPTIONS)
#error This helper requires explicit MRC and Objective-C exceptions
#endif

// Only scalar tombstones remain for this image's lifetime. Never reset or unload.
static atomic_int reserved;
static atomic_int operationContexts;
typedef struct { ResidentRequest request; int directory; } Operation;
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
static BOOL readRequest(int directory, ResidentRequest *r) {
    int fd = openat(directory, "request.bin", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    BOOL ok = fileShape(fd, sizeof(*r)) && pread(fd, r, sizeof(*r), 0) == sizeof(*r);
    if (fd >= 0) close(fd);
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
static BOOL validRequest(const ResidentRequest *r) {
    if (memcmp(r->magic, "MCURL1\0", 8) || r->operation != 1 || (r->sequence < 1 || r->sequence > 2) ||
        r->pid != (uint64_t)getpid() || r->startUsec >= 1000000 ||
        !uuidField(r->owner) || !uuidField(r->operationID) || !uuidField(r->device) ||
        !uuidField(r->generation) || !uuidField(r->imageUUID) ||
        !textField(r->executable, sizeof(r->executable)) || !textField(r->image, sizeof(r->image)) ||
        !textField(r->scene, sizeof(r->scene)) || !textField(r->parent, sizeof(r->parent)) ||
        r->digest[64] || r->expiresUnixMS < millis() || r->expiresUnixMS > millis() + 120000) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[65];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256(r, (CC_LONG)offsetof(ResidentRequest, digest), digest);
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
    const char *owner = getenv("MAC_CU_FIXTURE_SESSION"), *device = getenv("SIMULATOR_UDID");
    return owner && device && !strcmp(owner, r->owner) && !strcasecmp(device, r->device) &&
        (uint64_t)info.kp_proc.p_starttime.tv_sec == r->startSec &&
        (uint64_t)info.kp_proc.p_starttime.tv_usec == r->startUsec;
}
static BOOL imageIdentity(const ResidentRequest *r, Dl_info *image, char observedUUID[37]) {
    if (!dladdr((void *)&callback, image) || !image->dli_fbase || !image->dli_fname) return NO;
    char resolved[PATH_MAX];
    if (!realpath(image->dli_fname, resolved) || strcmp(resolved, r->image)) return NO;
    const struct mach_header_64 *header = image->dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->ncmds > 1024 || header->sizeofcmds > 1024 * 1024) return NO;
    const uint8_t *p = (const uint8_t *)(header + 1), *end = p + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (p + sizeof(struct load_command) > end) return NO;
        const struct load_command *c = (const void *)p;
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

#include "capture.inc"

static void callback(void *opaque) {
    Operation *op = opaque;
    int fd = op->directory, traced = -1, entered = 0, caught = 0, afterCancel = 0;
    int main = pthread_main_np();
    Dl_info image = {0};
    char observedUUID[37] = {0};
    uint64_t callbackAt = nanos(), workAt = 0;
    const char *outcome = "refused";
    char staged[3072] = {0};
    @autoreleasepool {
        @try {
            BOOL valid = identity(&op->request, &traced) && imageIdentity(&op->request, &image, observedUUID);
            if (!valid || !main || traced != 0 || millis() > op->request.expiresUnixMS) outcome = "identityOrTraceRefused";
            else if (cancelled(fd, op->request.digest) != 0) outcome = "cancelledBeforeEntry";
            else {
                UIView *target = freshHosting(&op->request);
                if (!target) outcome = "targetRefused";
                else if (!identity(&op->request, &traced) || traced != 0) outcome = "identityOrTraceRefused";
                else if (cancelled(fd, op->request.digest) != 0 || millis() > op->request.expiresUnixMS) outcome = "cancelledBeforeEntry";
                else {
                    char evidence[256];
                    int length = snprintf(evidence, sizeof(evidence), "{\"phase\":\"entered\",\"monotonicNS\":%llu,\"mainThread\":true,\"traced\":false}", (unsigned long long)nanos());
                    if (publish(fd, "entered.json", evidence, (size_t)length)) {
                        entered = 1;
                        outcome = captureHosting(target, op, fd);
                    } else outcome = "entryPublicationFailed";
                }
            }
        } @catch (id exception) {
            (void)exception; caught = 1; outcome = entered ? "uncertain" : "refusedException";
        }
        afterCancel = cancelled(fd, op->request.digest);
        workAt = nanos();
        // C bytes only. No object/string/exception/view is retained by a receipt.
        int length = snprintf(staged, sizeof(staged),
            "\"operationID\":\"%s\",\"requestDigest\":\"%s\",\"sequence\":%llu,\"outcome\":\"%s\","
            "\"captureEntered\":%s,\"caught\":%s,\"cancelObserved\":%s,\"channelError\":%s,\"authorityRestored\":false,\"undo\":null,"
            "\"mainThread\":%s,\"traced\":%d,\"callbackPC\":%llu,\"imageBase\":%llu,\"imageUUID\":\"%s\","
            "\"callbackNS\":%llu,\"workFinishedNS\":%llu",
            op->request.operationID, op->request.digest, (unsigned long long)op->request.sequence, outcome, entered ? "true" : "false", caught ? "true" : "false",
            afterCancel == 1 ? "true" : "false", afterCancel < 0 ? "true" : "false", main ? "true" : "false", traced,
            (unsigned long long)(uintptr_t)&callback, (unsigned long long)(uintptr_t)image.dli_fbase, observedUUID,
            (unsigned long long)callbackAt, (unsigned long long)workAt);
        if (length <= 0 || (size_t)length >= sizeof(staged)) staged[0] = 0;
        char work[128]; length = snprintf(work, sizeof(work), "{\"phase\":\"workFinished\",\"monotonicNS\":%llu}", (unsigned long long)workAt);
        if (!publish(fd, "work-finished.json", work, (size_t)length)) staged[0] = 0;
    }
    // Nothing claims pool exit until execution actually reaches this C-only tail.
    uint64_t poolAt = nanos();
    memset(op, 0, sizeof(*op)); free(op);
    atomic_fetch_sub(&operationContexts, 1);
    char terminal[4096];
    int length = snprintf(terminal, sizeof(terminal), "{%s,\"poolExited\":true,\"poolExitedNS\":%llu,"
        "\"publicationNS\":%llu,\"operationContexts\":%d,\"residentImages\":1,\"residentScalarBytes\":%zu,\"admissionClosed\":true}",
        staged, (unsigned long long)poolAt, (unsigned long long)nanos(), atomic_load(&operationContexts),
        sizeof(reserved) + sizeof(operationContexts));
    if (staged[0] && length > 0 && (size_t)length < sizeof(terminal)) publish(fd, "terminal.json", terminal, (size_t)length);
    close(fd);
}

int mac_cu_resident_submit(const char *directory) {
    // This bootstrap must stay on the selected stopped main thread. It does no UIKit work.
    if (!pthread_main_np()) return -1;
    int fd = privateDirectory(directory);
    if (fd < 0) return -2;
    ResidentRequest request;
    int traced = -1; Dl_info image = {0};
    char observedUUID[37] = {0};
    if (!readRequest(fd, &request) || !validRequest(&request) || !identity(&request, &traced) || !imageIdentity(&request, &image, observedUUID)) {
        close(fd); return -3;
    }
#ifndef RESIDENT_HOST_CONTROL
    if (traced != 1) { close(fd); return -4; }
#endif
    int expected = (int)request.sequence - 1;
    if (atomic_load(&operationContexts) != 0 || !atomic_compare_exchange_strong(&reserved, &expected, (int)request.sequence)) { close(fd); return -5; }
    Operation *op = calloc(1, sizeof(*op));
    if (!op) { close(fd); return -6; } // Reservation stays closed on every uncertain boundary.
    op->request = request; op->directory = fd;
    atomic_fetch_add(&operationContexts, 1);
    char accepted[256]; int length = snprintf(accepted, sizeof(accepted),
        "{\"phase\":\"accepted\",\"monotonicNS\":%llu,\"operationID\":\"%s\",\"requestDigest\":\"%s\"}",
        (unsigned long long)nanos(), request.operationID, request.digest);
    if (!publish(fd, "accepted.json", accepted, (size_t)length)) {
        memset(op, 0, sizeof(*op)); free(op); atomic_fetch_sub(&operationContexts, 1); close(fd); return -7;
    }
    dispatch_async_f(dispatch_get_main_queue(), op, callback);
    return 1;
}
