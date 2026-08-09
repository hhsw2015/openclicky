//
//  OpenClickyDaemonHost.swift
//  cursor-buddy
//
//  In-process implementation of RewindDaemonHost. OpenClicky runs
//  OpenRewind capture inside the main App process (no subprocess), so
//  vaultRoot() returns the live path and restartDaemon() is a re-read
//  of live config rather than a fork.
//

import Foundation

public final class OpenClickyDaemonHost: RewindDaemonHost {

    private let bridge: OpenRewindBridgeAccess

    public init(bridge: OpenRewindBridgeAccess) {
        self.bridge = bridge
    }

    public func vaultRoot() -> URL? {
        bridge.vaultRoot()
    }

    public func restartDaemon() {
        // In-process: nothing to fork. Bridge picks up latest UserDefaults
        // toggles the next time capture runs its loop tick.
        bridge.refreshFromUserDefaults()
    }

    public func startIfNeeded() {
        bridge.startIfNeeded()
    }

    public func stop() {
        bridge.stop()
    }
}

/// Narrow protocol the daemon-host adapter needs from OpenRewindBridge.
/// Keeps the daemon host testable without the full bridge instance.
public protocol OpenRewindBridgeAccess: AnyObject {
    func vaultRoot() -> URL?
    func refreshFromUserDefaults()
    func startIfNeeded()
    func stop()
}
