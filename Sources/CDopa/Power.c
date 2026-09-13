#include "CDopa.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <dlfcn.h>
#include <pthread.h>

// These IOKit SPI symbols are used by Apple's pmset but are not declared in the
// public SDK. Resolve them at runtime rather than preventing process startup on
// an OS without them. Their signatures and Copy ownership match Apple's source.
typedef CFDictionaryRef (*copy_settings_fn)(void);
typedef IOReturn (*set_setting_fn)(CFStringRef, CFTypeRef);

// RTLD_DEFAULT lookup results are stable for the lifetime of the process, so
// resolving once is enough. pthread_once also guarantees that the cached
// pointers are visible to every thread that returns from it, which keeps these
// entry points safe when the daemon serial engine and tests call them
// concurrently. A symbol missing on an unsupported OS stays NULL.
static copy_settings_fn g_copy_settings;
static set_setting_fn g_set_setting;
static pthread_once_t g_resolve_once = PTHREAD_ONCE_INIT;

static void dopa_resolve_power_symbols(void) {
    g_copy_settings = (copy_settings_fn)dlsym(RTLD_DEFAULT, "IOPMCopySystemPowerSettings");
    g_set_setting = (set_setting_fn)dlsym(RTLD_DEFAULT, "IOPMSetSystemPowerSetting");
}

int32_t dopa_read_sleep_disabled(int *disabled) {
    pthread_once(&g_resolve_once, dopa_resolve_power_symbols);
    // Require both symbols before a session can save a journal or enable sleep
    // inhibition; a readable setting without a usable setter is insufficient.
    if (!g_copy_settings || !g_set_setting) return -1;
    CFDictionaryRef settings = g_copy_settings();
    if (!settings) return -2;
    int32_t result = -2;
    if (CFGetTypeID(settings) == CFDictionaryGetTypeID()) {
        CFTypeRef value = CFDictionaryGetValue(settings, CFSTR("SleepDisabled"));
        if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) {
            *disabled = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
            result = 0;
        }
    }
    CFRelease(settings); // Copy returned exactly one owned reference.
    return result;
}

int32_t dopa_set_sleep_disabled(int disabled) {
    pthread_once(&g_resolve_once, dopa_resolve_power_symbols);
    if (!g_set_setting) return -1;
    return g_set_setting(CFSTR("SleepDisabled"), disabled ? kCFBooleanTrue : kCFBooleanFalse);
}
