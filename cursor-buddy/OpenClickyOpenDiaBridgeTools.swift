//
//  OpenClickyOpenDiaBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.6b F31 — MCP tool implementations for OpenDia browser control.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  OpenDia upstream (MIT) pin: 304345754cc99b24c07a3289a2e27abd5a5c19bb
//
//  Ports Everywhere's Everywhere.Mcp.OpenDia.OpenDiaBridge.CallToolAsync
//  path into Swift. Every browser_* MCP tool dispatches to the Node
//  subprocess, which forwards the request over WebSocket to the
//  connected Chrome/Firefox extension. The extension replies with a
//  matched-id result envelope; we surface it verbatim inside an MCP
//  content-text envelope, so downstream Everywhere clients see the same
//  wire shape.
//
//  Tool list: 120 browser_* tools from PARITY_MATRIX.md
//  (ownership=opendia OR universal). See docs/ROADMAP/.impl-notes/
//  phase7-6b-opendia-2026-07-23.md for the full rationale on why we
//  register the universal ones alongside the opendia-owned ones.
//

import Foundation
import os

/// Structured logger for F31 bridge-tool dispatch.
private let f31ToolLog = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-OpenDia")

/// Tool descriptors, executor, and envelope helpers for the 120
/// browser_* MCP tools that route through the OpenDia Node subprocess.
enum OpenClickyOpenDiaBridgeTools {

    /// Full list of (name, description) tuples, one per registered
    /// browser_* tool. Source of truth: Everywhere PARITY_MATRIX.md
    /// (ownership=opendia OR universal, status=in-progress|blocked).
    static let toolList: [(name: String, description: String)] = [
        (name: "browser_auth_delete", description: "Delete a saved auth vault entry."),
        (name: "browser_auth_list", description: "List saved auth vault entries."),
        (name: "browser_auth_login", description: "Log into a site using a saved auth vault entry."),
        (name: "browser_auth_save", description: "Save the current login session into the auth vault."),
        (name: "browser_auth_show", description: "Inspect one saved auth vault entry."),
        (name: "browser_back", description: "Navigate back in the active tab."),
        (name: "browser_batch", description: "Run a batch of browser_* calls in order."),
        (name: "browser_check", description: "Check a checkbox by ref."),
        (name: "browser_click", description: "Click an element by ref."),
        (name: "browser_close", description: "Close the active tab."),
        (name: "browser_confirm", description: "Accept the current native dialog."),
        (name: "browser_console", description: "Read the JS console log for the active tab."),
        (name: "browser_cookies_clear", description: "Clear cookies (all or by domain)."),
        (name: "browser_cookies_get", description: "Read cookies (all or by domain)."),
        (name: "browser_cookies_set", description: "Set one or more cookies."),
        (name: "browser_cookies_set_curl", description: "Set cookies from a curl Cookie header string."),
        (name: "browser_dblclick", description: "Double-click an element by ref."),
        (name: "browser_deny", description: "Deny the current permission prompt."),
        (name: "browser_device", description: "Emulate a device (Playwright device preset)."),
        (name: "browser_dialog_accept", description: "Accept the current native dialog with optional text."),
        (name: "browser_dialog_dismiss", description: "Dismiss the current native dialog."),
        (name: "browser_dialog_status", description: "Report the current native dialog status."),
        (name: "browser_diff_screenshot", description: "Compare two screenshots and return a delta report."),
        (name: "browser_diff_snapshot", description: "Compare two snapshots and return a delta report."),
        (name: "browser_diff_url", description: "Diff the active URL against a reference."),
        (name: "browser_download", description: "Wait for and describe a triggered file download."),
        (name: "browser_drag", description: "Drag an element from ref A to ref B."),
        (name: "browser_errors", description: "Read JS uncaught errors captured by the extension."),
        (name: "browser_eval", description: "Evaluate JS in the active tab and return the result."),
        (name: "browser_fill", description: "Type text into an input by ref."),
        (name: "browser_find", description: "Find elements by CSS or XPath selector."),
        (name: "browser_focus", description: "Focus an element by ref."),
        (name: "browser_forward", description: "Navigate forward in the active tab."),
        (name: "browser_frame_main", description: "Switch active frame to the main document."),
        (name: "browser_frame_switch", description: "Switch active frame to a named or indexed iframe."),
        (name: "browser_get_attr", description: "Read an attribute of an element by ref."),
        (name: "browser_get_box", description: "Read the bounding box of an element by ref."),
        (name: "browser_get_cdp_url", description: "Return the CDP websocket URL for the active tab."),
        (name: "browser_get_count", description: "Count elements matching a selector."),
        (name: "browser_get_html", description: "Return the outerHTML of an element by ref (or document)."),
        (name: "browser_get_styles", description: "Read computed styles of an element by ref."),
        (name: "browser_get_text", description: "Return the visible text of an element by ref (or document)."),
        (name: "browser_get_title", description: "Return the active tab title."),
        (name: "browser_get_url", description: "Return the active tab URL."),
        (name: "browser_get_value", description: "Read the value of a form input by ref."),
        (name: "browser_highlight", description: "Draw an overlay rectangle around an element by ref."),
        (name: "browser_hover", description: "Hover over an element by ref."),
        (name: "browser_inspect", description: "Inspect an element (attributes, computed style, aria)."),
        (name: "browser_is_checked", description: "Return whether a checkbox is checked."),
        (name: "browser_is_enabled", description: "Return whether a form control is enabled."),
        (name: "browser_is_visible", description: "Return whether an element is visible."),
        (name: "browser_keyboard_insert_text", description: "Insert literal text via keyboard events."),
        (name: "browser_keyboard_type", description: "Type text by dispatching keydown/keyup events."),
        (name: "browser_keydown", description: "Dispatch a raw keydown event."),
        (name: "browser_keyup", description: "Dispatch a raw keyup event."),
        (name: "browser_mouse_down", description: "Dispatch a raw mousedown event."),
        (name: "browser_mouse_move", description: "Dispatch a raw mousemove event."),
        (name: "browser_mouse_up", description: "Dispatch a raw mouseup event."),
        (name: "browser_mouse_wheel", description: "Dispatch a raw wheel event."),
        (name: "browser_network_har_start", description: "Start capturing a HAR file for the active tab."),
        (name: "browser_network_har_stop", description: "Stop the HAR capture and return the file."),
        (name: "browser_network_request", description: "Read one recorded network request."),
        (name: "browser_network_requests", description: "List recorded network requests."),
        (name: "browser_network_route", description: "Install a network route or interceptor."),
        (name: "browser_network_unroute", description: "Remove a previously installed network route."),
        (name: "browser_open", description: "Open a URL in the active or a new tab."),
        (name: "browser_pdf", description: "Print the active tab to a PDF."),
        (name: "browser_press", description: "Press a keyboard chord like Cmd+K."),
        (name: "browser_profiler_start", description: "Start the JS profiler for the active tab."),
        (name: "browser_profiler_stop", description: "Stop the JS profiler and return the trace."),
        (name: "browser_pushstate", description: "Call history.pushState() in the active tab."),
        (name: "browser_react_inspect", description: "Inspect a React component by ref."),
        (name: "browser_react_renders_start", description: "Start tracking React render counts."),
        (name: "browser_react_renders_stop", description: "Stop React render tracking and return counts."),
        (name: "browser_react_suspense", description: "Report React Suspense boundaries for the active tab."),
        (name: "browser_react_tree", description: "Return the React component tree."),
        (name: "browser_read", description: "Reader-mode extraction (blocked in current opendia; returns an error)."),
        (name: "browser_reload", description: "Reload the active tab."),
        (name: "browser_remove_init_script", description: "Remove a previously installed init script."),
        (name: "browser_screenshot", description: "Screenshot the active tab (viewport, full page, or element)."),
        (name: "browser_scroll", description: "Scroll the active tab by delta or to coordinates."),
        (name: "browser_scroll_into_view", description: "Scroll an element by ref into view."),
        (name: "browser_select", description: "Select an option in a select element by ref."),
        (name: "browser_set_credentials", description: "Set basic-auth credentials for the active tab."),
        (name: "browser_set_geo", description: "Emulate a geolocation for the active tab."),
        (name: "browser_set_headers", description: "Install extra HTTP headers for the active tab."),
        (name: "browser_set_media", description: "Emulate a CSS media type or prefers-color-scheme."),
        (name: "browser_set_offline", description: "Toggle offline network emulation."),
        (name: "browser_set_viewport", description: "Resize the viewport of the active tab."),
        (name: "browser_snapshot", description: "Return an aria/DOM snapshot with @refN handles."),
        (name: "browser_state_clean", description: "Clean transient extension state."),
        (name: "browser_state_clear", description: "Clear a named state slot."),
        (name: "browser_state_list", description: "List saved state slots."),
        (name: "browser_state_load", description: "Load a named state slot into the current tab."),
        (name: "browser_state_rename", description: "Rename a state slot."),
        (name: "browser_state_save", description: "Save the current tab state into a named slot."),
        (name: "browser_state_show", description: "Show the contents of a named state slot."),
        (name: "browser_storage_clear", description: "Clear localStorage or sessionStorage for a domain."),
        (name: "browser_storage_get", description: "Read a localStorage or sessionStorage key."),
        (name: "browser_storage_set", description: "Write a localStorage or sessionStorage key."),
        (name: "browser_swipe", description: "Dispatch a touch swipe gesture."),
        (name: "browser_tab_close", description: "Close a tab by id."),
        (name: "browser_tab_list", description: "List open tabs."),
        (name: "browser_tab_new", description: "Open a new tab."),
        (name: "browser_tab_switch", description: "Switch the active tab by id."),
        (name: "browser_tap", description: "Dispatch a touch tap event."),
        (name: "browser_trace_start", description: "Start a performance trace."),
        (name: "browser_trace_stop", description: "Stop the performance trace and return the file."),
        (name: "browser_type", description: "Type a string into the focused input."),
        (name: "browser_uncheck", description: "Uncheck a checkbox by ref."),
        (name: "browser_upload", description: "Upload a local file to a file input by ref."),
        (name: "browser_vitals", description: "Return web-vitals metrics for the active tab."),
        (name: "browser_wait_for_download", description: "Wait for a download to complete."),
        (name: "browser_wait_for_function", description: "Wait for a JS function to return truthy."),
        (name: "browser_wait_for_load", description: "Wait for the active tab to reach a load state."),
        (name: "browser_wait_for_selector", description: "Wait for a selector to appear."),
        (name: "browser_wait_for_text", description: "Wait for text to appear on the page."),
        (name: "browser_wait_for_url", description: "Wait for the tab URL to match."),
        (name: "browser_wait_ms", description: "Sleep for N milliseconds."),
        (name: "browser_window_new", description: "Open a new browser window."),
    ]


    /// Set of every registered browser_* name — used by the bridge's
    /// dispatch switch to route on prefix-plus-membership.
    static var toolNames: Set<String> {
        return Set(toolList.map { $0.name })
    }

    /// MCP tools/list descriptor rows for every registered tool. Input
    /// schemas are intentionally permissive (params object with no
    /// required fields) because the extension is the source of truth
    /// for per-tool argument shape — Everywhere upstream reflects the
    /// same permissive schema through .
    ///
    /// TODO(F31 follow-up): mirror Everywhere's approach. On the Node
    /// subprocess READY handshake the extension sends a `tools/register`
    /// frame with real per-tool schemas — see the upstream builder at
    /// `Everywhere/src/Everywhere.Mcp/OpenDia/OpenDiaToolListBuilder.cs`
    /// lines 21-42, called from `OpenDiaBridge.cs:333-343`. Once the
    /// subprocess caches those, `descriptorsRaw` should return the
    /// registered schemas and fall back to permissive shape only when
    /// the cache is empty (extension disconnected).
    static var descriptorsRaw: [[String: Any]] {
        return toolList.map { entry in
            [
                "name": entry.name,
                "description": entry.description,
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": true,
                    "required": [] as [Any]
                ] as [String: Any]
            ]
        }
    }

    // MARK: - Dispatch

    /// Executes one browser_* tool. Returns the MCP content envelope and
    /// an isError flag — same shape as
    /// OpenClickyExternalControlBridgeServer.executeSensorTool.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        let t0 = Date()
        let argLen = (try? JSONSerialization.data(withJSONObject: arguments))?.count ?? 0
        let (result, isError) = await dispatch(name: name, arguments: arguments)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        f31ToolLog.info("openclicky.opendia.tool_call tool=\(name, privacy: .public) arg_len=\(argLen, privacy: .public) ok=\(!isError, privacy: .public) latency_ms=\(latencyMs, privacy: .public)")
        return (result, isError)
    }

    private static func dispatch(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard toolNames.contains(name) else {
            return errorEnvelope(name: name,
                                 code: "UNKNOWN_TOOL",
                                 message: "'\(name)' is not a registered OpenDia tool")
        }
        let running = await MainActor.run { OpenClickyOpenDiaSubprocess.shared.isRunning }
        guard running else {
            return errorEnvelope(name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: "OpenDia Node subprocess is not running. Enable OpenDia in Settings.")
        }
        do {
            let response = try await OpenClickyOpenDiaSubprocess.shared.callTool(
                name: name, arguments: arguments
            )
            // The Node shim returns {ok, name, result} on success and
            // {ok:false, code, error} on failure. Both shapes are safe
            // to forward as-is inside the MCP content text envelope.
            var body = response
            if body["schema_version"] == nil { body["schema_version"] = "1" }
            if body["tool"] == nil { body["tool"] = name }
            let isError = (body["ok"] as? Bool) == false
            return (textEnvelope(from: body), isError)
        } catch {
            return errorEnvelope(name: name,
                                 code: "RUNTIME_HOST_ERROR",
                                 message: error.localizedDescription)
        }
    }

    // MARK: - Envelope helpers

    static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    static func errorEnvelope(name: String?, code: String, message: String) -> ([String: Any], Bool) {
        var body: [String: Any] = [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "error": message
        ]
        if let name { body["tool"] = name }
        return (textEnvelope(from: body), true)
    }
}

