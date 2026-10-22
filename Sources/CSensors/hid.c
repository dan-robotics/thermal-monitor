// IOHID temperature sensors — the source of the Apple Silicon die/SoC temperatures.
// CopyServices / CopyProperty are public SDK API; the functions declared below are exported
// by IOKit.framework but absent from the public headers.

#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kTMHIDPageAppleVendor             0xff00
#define kTMHIDUsageTemperatureSensor      0x0005
#define kTMHIDEventTypeTemperature        15
#define kTMHIDEventFieldTemperatureLevel  (kTMHIDEventTypeTemperature << 16)

// Created once and reused: creating the client and copying services every tick is the
// expensive part; copying one event per service is cheap.
static IOHIDEventSystemClientRef gClient = NULL;
static CFArrayRef gServices = NULL;

static int ensure_client(void) {
    if (gServices) return 0;
    gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) return -1;

    int page = kTMHIDPageAppleVendor, usage = kTMHIDUsageTemperatureSensor;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(gClient, match);
    CFRelease(match);
    CFRelease(pageNum);
    CFRelease(usageNum);

    gServices = IOHIDEventSystemClientCopyServices(gClient);
    if (!gServices) {
        // Release the client so the next attempt starts clean instead of leaking one per tick.
        CFRelease(gClient);
        gClient = NULL;
        return -1;
    }
    return 0;
}

int tm_hid_read(tm_hid_sensor *out, int max) {
    if (ensure_client() != 0) return -1;

    int written = 0;
    CFIndex count = CFArrayGetCount(gServices);
    for (CFIndex i = 0; i < count && written < max; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!product) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kTMHIDEventTypeTemperature, 0, 0);
        if (event) {
            double value = IOHIDEventGetFloatValue(event, kTMHIDEventFieldTemperatureLevel);
            if (CFGetTypeID(product) == CFStringGetTypeID() &&
                CFStringGetCString((CFStringRef)product, out[written].name, TM_NAME_LEN,
                                   kCFStringEncodingUTF8)) {
                out[written].celsius = value;
                written++;
            }
            CFRelease(event);
        }
        CFRelease(product);
    }
    return written;
}
