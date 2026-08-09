//
//  cursor-buddy-Bridging-Header.h
//  cursor-buddy
//
//  Bridging header for the OpenClicky app target. Currently only
//  exposes the Objective-C exception-swallowing shim used to survive
//  macOS 26's NSRemoteView `containingWindowWillOrderOnScreen:` bug
//  (see OpenClickyOverlayObjCBridge.h for details).
//

#import "OpenClickyOverlayObjCBridge.h"
