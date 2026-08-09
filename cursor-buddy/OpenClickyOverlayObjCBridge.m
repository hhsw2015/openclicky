//
//  OpenClickyOverlayObjCBridge.m
//  cursor-buddy
//
//  See header for design rationale. The exception we are catching is
//  `NSInternalInconsistencyException` raised from
//  `-[NSRemoteView containingWindowWillOrderOnScreen:]` on macOS 26
//  when a Safari SPCompletionList XPC popover has registered as a
//  process-wide observer of `NSWindowWillOrderOnScreenNotification`.
//
//  The exception is thrown BEFORE our panel is actually ordered on
//  screen, so callers should treat a NO return as "the ordering may
//  or may not have taken effect" and continue attempting to install
//  the remaining panels (each screen has its own panel, and one
//  failing doesn't necessarily doom the others).
//

#import "OpenClickyOverlayObjCBridge.h"

// ApplicationServices → HIServices → Processes.h still declares the
// deprecated Carbon front-process APIs for Obj-C callers. The Swift
// overlay marks them "unavailable", which is why we need this shim.
// AppKit pulls in ApplicationServices transitively, so no additional
// framework link is required.
#import <ApplicationServices/ApplicationServices.h>

// Suppress the deprecation churn — this file is the ONLY translation
// unit that intentionally calls these APIs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

BOOL OpenClickySafeOrderFront(NSWindow *window) {
    if (window == nil) { return NO; }
    @try {
        [window orderFront:nil];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[OpenClicky] OpenClickySafeOrderFront swallowed exception: name=%@ reason=%@",
              e.name, e.reason);
        return NO;
    }
}

BOOL OpenClickySafeOrderFrontRegardless(NSWindow *window) {
    if (window == nil) { return NO; }
    @try {
        [window orderFrontRegardless];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[OpenClicky] OpenClickySafeOrderFrontRegardless swallowed exception: name=%@ reason=%@",
              e.name, e.reason);
        return NO;
    }
}

BOOL OpenClickySafeMakeKeyAndOrderFront(NSWindow *window) {
    if (window == nil) { return NO; }
    @try {
        [window makeKeyAndOrderFront:nil];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[OpenClicky] OpenClickySafeMakeKeyAndOrderFront swallowed exception: name=%@ reason=%@",
              e.name, e.reason);
        return NO;
    }
}

BOOL OpenClickyCarbonSetFrontProcess(pid_t pid) {
    if (pid <= 0) { return NO; }
    ProcessSerialNumber psn = { 0, 0 };
    OSStatus st = GetProcessForPID(pid, &psn);
    if (st != noErr) {
        NSLog(@"[OpenClicky] GetProcessForPID(%d) -> %d", pid, (int)st);
        return NO;
    }
    // kSetFrontProcessFrontWindowOnly = (1 << 0). Front-only, don't
    // reorder the whole application-switcher stack. Mirrors Everywhere
    // `MacAppActivator.cs:294`.
    st = SetFrontProcessWithOptions(&psn, 0x00000001u);
    if (st != noErr) {
        NSLog(@"[OpenClicky] SetFrontProcessWithOptions(%d) -> %d", pid, (int)st);
        return NO;
    }
    return YES;
}

#pragma clang diagnostic pop
