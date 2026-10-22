// AppleSMC reader — temperature keys and fan speeds. Read-only: only the read-key,
// get-key-info and get-key-by-index commands are ever sent.

#include "CSensors.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char major, minor, build, reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    unsigned char bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must match the kernel's 80-byte layout");

static io_connect_t gConn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8)  |  (uint32_t)(unsigned char)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v;
    out[4] = '\0';
}

static kern_return_t call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(gConn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
}

int tm_smc_open(void) {
    if (gConn) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { gConn = 0; return kr; }
    return 0;
}

void tm_smc_close(void) {
    if (gConn) { IOServiceClose(gConn); gConn = 0; }
}

int tm_smc_key_info(const char *key, tm_smc_key *out) {
    if (!gConn || strlen(key) != 4) return -1;
    SMCKeyData_t in = {0}, res = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -1;
    memcpy(out->key, key, 4); out->key[4] = '\0';
    unfourcc(res.keyInfo.dataType, out->type);
    out->size = res.keyInfo.dataSize;
    return 0;
}

int tm_smc_key_at(uint32_t index, tm_smc_key *out) {
    if (!gConn) return -1;
    SMCKeyData_t in = {0}, res = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -1;
    char name[5];
    unfourcc(res.key, name);
    return tm_smc_key_info(name, out);
}

static int read_bytes(const tm_smc_key *key, unsigned char bytes[32]) {
    if (!gConn) return -1;
    SMCKeyData_t in = {0}, res = {0};
    in.key = fourcc(key->key);
    in.keyInfo.dataSize = key->size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (call(&in, &res) != KERN_SUCCESS || res.result != 0) return -1;
    memcpy(bytes, res.bytes, 32);
    return 0;
}

int tm_smc_key_count(void) {
    tm_smc_key info;
    if (tm_smc_key_info("#KEY", &info) != 0) return -1;
    unsigned char b[32];
    if (read_bytes(&info, b) != 0) return -1;
    return (int)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
}

int tm_smc_read_double(const tm_smc_key *key, double *value) {
    unsigned char b[32];
    if (read_bytes(key, b) != 0) return -1;

    if (strcmp(key->type, "flt ") == 0 && key->size == 4) {
        float f;                       // Apple Silicon SMC floats are little-endian
        memcpy(&f, b, 4);
        *value = f;
    } else if (strcmp(key->type, "fpe2") == 0 && key->size == 2) {
        *value = (double)(((uint16_t)b[0] << 8) | b[1]) / 4.0;     // Intel-era fan format
    } else if (strcmp(key->type, "sp78") == 0 && key->size == 2) {
        *value = (double)(int16_t)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    } else if (strcmp(key->type, "ui8 ") == 0) {
        *value = b[0];
    } else if (strcmp(key->type, "ui16") == 0) {
        *value = ((uint16_t)b[0] << 8) | b[1];
    } else if (strcmp(key->type, "ui32") == 0) {
        *value = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    } else {
        return -1;
    }
    return 0;
}
