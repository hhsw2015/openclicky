/**
 * Browser connection error helpers.
 *
 * Simplified — no more token/extension/CDP classification.
 * The daemon architecture has a single failure mode: daemon not reachable or extension not connected.
 */
import { BrowserConnectError } from '../errors.js';
import { DEFAULT_DAEMON_PORT } from '../constants.js';
/**
 * Extension/daemon transient patterns — service worker restarts, attach races,
 * tab closure, daemon hiccups. These warrant a longer retry delay (~1500ms)
 * because the extension needs time to recover.
 */
const EXTENSION_TRANSIENT_PATTERNS = [
    'Extension disconnected',
    'Extension not connected',
    'attach failed',
    'Detached while handling command',
    'Debugger is not attached to the tab',
    'no longer exists',
    'No tab with id',
    'CDP connection',
    'Daemon command failed',
    'No window with id',
];
/**
 * CDP target navigation patterns — SPA client-side redirects can invalidate the
 * CDP target after chrome.tabs reports 'complete'. These warrant a shorter retry
 * delay (~200ms) because the new document is usually available quickly.
 */
const TARGET_NAVIGATION_PATTERNS = [
    'Inspected target navigated or closed',
];
function errorMessage(err) {
    return err instanceof Error ? err.message : String(err);
}
/**
 * Classify a browser error and return retry advice.
 *
 * Single source of truth for "is this error transient?" across all layers.
 */
export function classifyBrowserError(err) {
    const msg = errorMessage(err);
    // Extension/daemon transient errors — longer recovery time
    if (EXTENSION_TRANSIENT_PATTERNS.some(p => msg.includes(p))) {
        return { kind: 'extension-transient', retryable: true, delayMs: 1500 };
    }
    // CDP target navigation errors — shorter recovery time
    if (TARGET_NAVIGATION_PATTERNS.some(p => msg.includes(p))) {
        return { kind: 'target-navigation', retryable: true, delayMs: 200 };
    }
    // CDP protocol error with target/context invalidation (e.g., -32000 "target closed" or
    // -32000 "Cannot find default execution context" — both indicate the inspected target
    // went away and a fresh attach should recover).
    if (msg.includes('-32000') && /target|context/i.test(msg)) {
        return { kind: 'target-navigation', retryable: true, delayMs: 200 };
    }
    return { kind: 'non-retryable', retryable: false, delayMs: 0 };
}
/**
 * Check if an error is a transient browser error worth retrying.
 * Convenience wrapper around classifyBrowserError().
 */
export function isTransientBrowserError(err) {
    return classifyBrowserError(err).retryable;
}
export function formatBrowserConnectError(kind, detail) {
    switch (kind) {
        case 'daemon-not-running':
            return new BrowserConnectError('Cannot connect to opencli daemon.' + (detail ? `\n\n${detail}` : ''), `Run \`opencli doctor\` to diagnose, or \`opencli daemon restart\` to force a fresh daemon. Default port is ${DEFAULT_DAEMON_PORT}.`, kind);
        case 'extension-not-connected':
            return new BrowserConnectError('Browser Bridge extension is not connected.' + (detail ? `\n\n${detail}` : ''), 'Install the extension from GitHub Releases, then reload.', kind);
        case 'command-failed':
            return new BrowserConnectError(`Browser command failed: ${detail ?? 'unknown error'}`, undefined, kind);
        default:
            return new BrowserConnectError(detail ?? 'Failed to connect to browser', undefined, kind);
    }
}
