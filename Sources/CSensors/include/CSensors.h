// CSensors — thin C layer over the two macOS hardware sensor sources ThermalMonitor reads.
//
//  1. IOHID temperature sensors (Apple Silicon die/SoC/battery/NAND sensors). Uses the
//     IOHIDEventSystemClient family, which is exported by IOKit.framework but not declared in
//     the public SDK headers — the declarations live in hid.c.
//  2. AppleSMC (System Management Controller): temperature keys + fan speeds, read through the
//     AppleSMC IOKit user client.
//
// Read-only. No root required. Nothing here writes to the SMC.

#ifndef CSENSORS_H
#define CSENSORS_H

#include <stdint.h>

#define TM_NAME_LEN 64

typedef struct {
    char name[TM_NAME_LEN];   // e.g. "PMU tdie3", "pACC MTR Temp Sensor2"
    double celsius;
} tm_hid_sensor;

/// Reads every IOHID temperature sensor. Returns the number written to `out` (<= max),
/// or -1 if the HID event system client could not be created.
int tm_hid_read(tm_hid_sensor *out, int max);

typedef struct {
    char key[5];              // 4-char SMC key + NUL, e.g. "Tp01"
    char type[5];             // 4-char SMC data type + NUL, e.g. "flt "
    uint32_t size;            // data size in bytes
} tm_smc_key;

/// Opens the AppleSMC connection (idempotent). Returns 0 on success, otherwise an IOKit error.
int tm_smc_open(void);

/// Closes the AppleSMC connection if open.
void tm_smc_close(void);

/// Total number of keys the SMC exposes (the "#KEY" key). Returns -1 on failure.
int tm_smc_key_count(void);

/// Fills `out` with the key name/type/size at `index`. Returns 0 on success.
int tm_smc_key_at(uint32_t index, tm_smc_key *out);

/// Looks up type/size for a named key. Returns 0 on success.
int tm_smc_key_info(const char *key, tm_smc_key *out);

/// Reads a key and decodes it to a double. Supports flt, fpe2, sp78, ui8/ui16/ui32.
/// Returns 0 on success.
int tm_smc_read_double(const tm_smc_key *key, double *value);

#endif
