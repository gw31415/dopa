#include "CDopa.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <dlfcn.h>

// These IOKit SPI symbols are used by Apple's pmset but are not declared in the
// public SDK. Resolve them at runtime rather than preventing process startup on
// an OS without them. Their signatures and Copy ownership match Apple's source.
typedef CFDictionaryRef (*copy_settings_fn)(void);
typedef IOReturn (*set_setting_fn)(CFStringRef, CFTypeRef);

int32_t dopa_read_sleep_disabled(int *disabled) {
    copy_settings_fn copy = (copy_settings_fn)dlsym(RTLD_DEFAULT, "IOPMCopySystemPowerSettings");
    // Require both symbols before a session can save a journal or enable sleep
    // inhibition; a readable setting without a usable setter is insufficient.
    set_setting_fn set = (set_setting_fn)dlsym(RTLD_DEFAULT, "IOPMSetSystemPowerSetting");
    if (!copy || !set) return -1;
    CFDictionaryRef settings = copy();
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
    set_setting_fn set = (set_setting_fn)dlsym(RTLD_DEFAULT, "IOPMSetSystemPowerSetting");
    if (!set) return -1;
    return set(CFSTR("SleepDisabled"), disabled ? kCFBooleanTrue : kCFBooleanFalse);
}
