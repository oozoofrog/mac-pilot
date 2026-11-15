#include <stdint.h>
// ABI 2: fixed native header followed by at most 64 KiB of server-owned schema-2 JSON.
// No target pointers, callback pointers, selectors, KVC or executable code.
typedef struct __attribute__((packed)) {
    char magic[8];
    uint64_t abi, pid, startSec, startUsec, sequence, expiresUnixMS, payloadLength;
    char owner[37], operationID[37], device[37];
    char executable[1024], image[1024], imageUUID[37];
    char digest[65];
} ResidentRequest;
static_assert(sizeof(ResidentRequest) == 2325, "resident ABI layout changed");
extern "C" __attribute__((visibility("default"))) int mac_cu_resident_submit_v2(const char *directory);
