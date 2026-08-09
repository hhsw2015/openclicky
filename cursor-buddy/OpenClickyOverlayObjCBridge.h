//
//  OpenClickyOverlayObjCBridge.h
//  cursor-buddy
//
//  macOS 26 workaround for `NSInternalInconsistencyException` raised
//  from `-[NSRemoteView containingWindowWillOrderOnScreen:]` when a
//  Safari `SPCompletionListServiceViewController` XPC remote view
//  observes our overlay panel's window-ordering broadcast.
//
//  Swift cannot catch Objective-C exceptions, so we route the
//  `orderFront:` / `orderFrontRegardless` / `makeKeyAndOrderFront:`
//  calls that trip the observer through this thin ObjC shim that
//  wraps them in `@try` / `@catch`.
//
//  These functions return `YES` when the underlying call completed
//  without exception, `NO` when an `NSException` was swallowed. On
//  `NO` the caller should still consider the panel to be in an
//  indeterminate state (some observers may have run before the
//  raise) but the process survives.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps `[window orderFront:nil]` in `@try` / `@catch`. Returns YES
/// on success, NO if an Objective-C exception was swallowed.
BOOL OpenClickySafeOrderFront(NSWindow *window);

/// Wraps `[window orderFrontRegardless]` in `@try` / `@catch`.
BOOL OpenClickySafeOrderFrontRegardless(NSWindow *window);

/// Wraps `[window makeKeyAndOrderFront:nil]` in `@try` / `@catch`.
BOOL OpenClickySafeMakeKeyAndOrderFront(NSWindow *window);

/// Force `pid` to the front-most process using the deprecated (but
/// still functional) Carbon `SetFrontProcessWithOptions` API. Returns
/// YES on success. Called as a fallback when
/// `-[NSRunningApplication activate:]` gets downgraded (macOS 26
/// tightened this for LSUIElement callers).
///
/// The Carbon `GetProcessForPID` + `SetFrontProcessWithOptions`
/// symbols are marked Swift-unavailable in the current SDK, but they
/// are still exported from the Carbon framework and callable from
/// Objective-C. This shim exists solely so Swift code can reach them.
/// Mirrors Everywhere's C# P/Invoke fallback at
/// `src/Everywhere.Mac/Interop/MacAppActivator.cs:113-123, 264-296`.
BOOL OpenClickyCarbonSetFrontProcess(pid_t pid);

NS_ASSUME_NONNULL_END
