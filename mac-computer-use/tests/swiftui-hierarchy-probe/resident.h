#include <stdint.h>

// Private experiment wire. At most two ordered read-only operations per loaded image.
// No addresses, selectors, callbacks, code strings, object pointers, or variable arrays.
typedef struct __attribute__((packed)) {
    char magic[8];
    uint64_t operation, pid, startSec, startUsec, sequence, expiresUnixMS, hiddenCount;
    char owner[37], operationID[37], device[37], generation[37];
    char executable[1024], image[1024], imageUUID[37], scene[128], parent[64];
    char digest[65]; // SHA256 of all preceding wire bytes; lowercase hex.
} ResidentRequest;
_Static_assert(sizeof(ResidentRequest) == 2554, "experiment wire layout changed");

// Synchronously copies a bounded path, reads/copies the fixed request, and queues
// the image's own callback. No caller-owned pointer survives this call.
__attribute__((visibility("default"))) int mac_cu_resident_submit(const char *directory);
