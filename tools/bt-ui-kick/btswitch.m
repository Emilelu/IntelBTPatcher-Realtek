#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static AXUIElementRef g_found = NULL;
static int g_count = 0;

static void dumpEl(AXUIElementRef el, int depth, const char *want);

static void walk(AXUIElementRef el, int depth, const char *want) {
    if (depth > 14 || g_count > 40) return;
    CFTypeRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kids) != kAXErrorSuccess) return;
    CFArrayRef arr = (CFArrayRef)kids;
    if (arr) {
        CFIndex n = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n; i++) {
            AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(arr, i);
            dumpEl(k, depth + 1, want);
            walk(k, depth + 1, want);
        }
        CFRelease(kids);
    }
}

static void dumpEl(AXUIElementRef el, int depth, const char *want) {
    if (g_count > 40) return;
    CFTypeRef role = NULL, desc = NULL, val = NULL, title = NULL;
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
    AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute, &desc);
    AXUIElementCopyAttributeValue(el, kAXValueAttribute, &val);
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute, &title);
    const char *r = role ? [(NSString *)role UTF8String] : "";
    const char *d = desc ? [(NSString *)desc UTF8String] : "";
    const char *t = title ? [(NSString *)title UTF8String] : "";
    NSString *vs = @"";
    if (val) {
        if (CFGetTypeID(val) == CFStringGetTypeID()) vs = (NSString *)val;
        else if (CFGetTypeID(val) == CFNumberGetTypeID()) vs = [(NSNumber *)val stringValue];
        else if (CFGetTypeID(val) == CFBooleanGetTypeID()) vs = [(NSNumber *)val boolValue] ? @"YES" : @"NO";
        else vs = [NSString stringWithFormat:@"<%@>", [(id)val class]];
    }
    if (r && (strcmp(r, "AXCheckBox") == 0 || strcmp(r, "AXSwitch") == 0 || strcmp(r, "AXRadioButton") == 0)) {
        g_count++;
        printf("[%d] depth=%d role=%s desc=%s title=%s value=%s\n", g_count, depth, r, d, t,
               [vs UTF8String] ?: "");
        if (!g_found && want && (strcmp(want, "find") == 0 || strcmp(want, "press") == 0)) {
            CFRetain(el);
            g_found = el;
            printf("    -> SELECTED\n");
        }
    }
    if (role) CFRelease(role);
    if (desc) CFRelease(desc);
    if (val) CFRelease(val);
    if (title) CFRelease(title);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bid = argc > 1 ? argv[1] : "com.apple.systempreferences";
        const char *mode = argc > 2 ? argv[2] : "find";
        NSRunningApplication *app = nil;
        for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if (a.bundleIdentifier && strcmp(a.bundleIdentifier.UTF8String, bid) == 0) { app = a; break; }
        }
        if (!app) { printf("app not running: %s\n", bid); return 1; }
        printf("bid=%s pid=%d\n", bid, app.processIdentifier);
        AXUIElementRef ax = AXUIElementCreateApplication(app.processIdentifier);
        CFTypeRef wins = NULL;
        AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute, &wins);
        if (!wins) { printf("no windows\n"); return 2; }
        CFArrayRef wa = (CFArrayRef)wins;
        for (CFIndex i = 0; i < CFArrayGetCount(wa); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wa, i);
            dumpEl(w, 0, mode);
            walk(w, 0, mode);
        }
        CFRelease(wins);
        if (g_found) {
            CFTypeRef before = NULL;
            AXUIElementCopyAttributeValue(g_found, kAXValueAttribute, &before);
            printf("before=%s\n", before ? [[(NSNumber *)before description] UTF8String] : "nil");
            if (before) CFRelease(before);
            if (strcmp(mode, "press") == 0) {
                AXError e = AXUIElementPerformAction(g_found, kAXPressAction);
                printf("AXPress err=%d\n", (int)e);
            }
            sleep(3);
            CFTypeRef after = NULL;
            AXUIElementCopyAttributeValue(g_found, kAXValueAttribute, &after);
            printf("after=%s\n", after ? [[(NSNumber *)after description] UTF8String] : "nil");
            if (after) CFRelease(after);
            CFRelease(g_found);
        } else {
            printf("no toggle found\n");
        }
        printf("done\n");
    }
    return 0;
}
