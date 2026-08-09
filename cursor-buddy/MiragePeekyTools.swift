//
//  MiragePeekyTools.swift
//  cursor-buddy
//
//  Tool JSON schemas Claude sees when running through the Peeky-mirage
//  pipeline. Verbatim from Peeky's Rust source
//  (peeky/src/providers/claude/parsing.rs `tools_array_value` +
//  peeky/src/integrations/*.rs `tools()` functions).
//
//  Layout:
//   * `desktopCore` — computer + open_url + launch_app + switch_to_window.
//     Sent for find_action, integration (with extras), and agent paths.
//   * `memoryTools` — store_fact / recall_fact / recall_conversation.
//     Sent for the memory router path.
//   * `integrationTools(available:)` — the macOS + service integrations
//     (Spotify, Calendar, Contacts, Messages, Reminders, FaceTime,
//     Shortcuts, Safari, Spotlight, Clipboard, Notes, Reminders, Apps,
//     Type Text, YouTube). Selection filtered by
//     `MirageMacIntegrations.availability()` at call time — the same
//     "is_available()" gate Peeky uses so Claude never sees a tool the
//     runtime can't execute.
//
//  Prompt-caching contract: the agent path adds
//  `cache_control: {type: "ephemeral"}` to the LAST tool so Anthropic
//  caches the whole (system + tools) prefix. Non-agent paths don't need
//  it because the tool set is small enough that the cache write cost
//  isn't worth the payoff.

import Foundation

enum MiragePeekyTools {

    // MARK: - Desktop core (find_action, integration, agent share these)

    /// `computer_20250124` tool + open_url/launch_app/switch_to_window.
    /// declared_w/h come from the pre-turn screenshot resize so Claude's
    /// coordinate output matches the actual visible surface (matches
    /// Peeky's tools_array_value:16-58).
    static func desktopCore(declaredWidthPx: Int, declaredHeightPx: Int) -> [[String: Any]] {
        [
            [
                "type": "computer_20250124",
                "name": "computer",
                "display_width_px": declaredWidthPx,
                "display_height_px": declaredHeightPx
            ],
            [
                "name": "open_url",
                "description": "Open a URL in the user's default web browser. Use ONLY for full https:// or http:// URLs the user explicitly wants to navigate to. Do NOT use for clicking a link visible on screen (use the computer tool's left_click for that).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Fully-qualified URL including scheme."]
                    ],
                    "required": ["url"]
                ]
            ],
            [
                "name": "launch_app",
                "description": "Launch a desktop application by name. Use for queries like 'open Spotify', 'launch Firefox'. The app argument is the app's common name. Do NOT use for switching to an already-running app (use switch_to_window for that).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "App name or .desktop file basename, lowercase."]
                    ],
                    "required": ["app"]
                ]
            ],
            [
                "name": "switch_to_window",
                "description": "Focus an already-running application window. Use for 'switch to Firefox' when the app is already open. Do NOT use to launch a new app.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Window class or title substring."]
                    ],
                    "required": ["target"]
                ]
            ]
        ]
    }

    // MARK: - Memory router

    /// Tool set for the memory intent path.
    static let memoryTools: [[String: Any]] = [
        [
            "name": "store_fact",
            "description": "Store a user fact for later recall. Extract a short snake_case key and the literal value.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "snake_case identifier, e.g. 'favorite_color', 'allergic_to', 'home_city'"],
                    "value": ["type": "string", "description": "the literal value the user provided"]
                ],
                "required": ["key", "value"]
            ]
        ],
        [
            "name": "recall_fact",
            "description": "Recall a previously-stored fact. Provide the snake_case key the user is asking about (best guess based on phrasing).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "snake_case key matching whatever 'remember X' might have stored"]
                ],
                "required": ["key"]
            ]
        ],
        [
            "name": "recall_conversation",
            "description": "User is asking about the conversation you are having right now, not a stored fact. E.g. 'what did I just ask you', 'what were we talking about', 'what did you just say'. Takes no input.",
            "input_schema": [
                "type": "object",
                "properties": [:]
            ]
        ]
    ]

    // MARK: - Classifier (5-intent forced-tool)

    /// One-tool schema for the classifier forced call. See classifier.rs.
    static let classifierTool: [String: Any] = [
        "name": "classify",
        "description": "Emit the single best category for the user's voice command.",
        "input_schema": [
            "type": "object",
            "properties": [
                "category": [
                    "type": "string",
                    "enum": ["find_action", "integration", "chat", "memory", "agent"]
                ]
            ],
            "required": ["category"]
        ]
    ]

    // MARK: - Integrations (macOS service tools)

    /// Every tool exposed by MirageMacIntegrations, gated by runtime
    /// availability so Claude never sees one it can't execute. Callers
    /// (integration + agent paths) inject these into their tools array
    /// alongside desktopCore.
    ///
    /// Selection is deliberately narrower than Peeky's 26-integration
    /// binary — we ship the ones OpenClicky already has native macOS
    /// support for (Spotify AppleScript, EventKit calendar/reminders,
    /// Contacts, Messages, FaceTime, Shortcuts, Safari, Spotlight,
    /// Clipboard). Gmail's OAuth is deferred because it needs a full
    /// auth flow the mirage lane can't own transparently.
    static func integrationTools(available: MirageIntegrationAvailability) -> [[String: Any]] {
        var out: [[String: Any]] = []

        if available.spotify {
            out.append(contentsOf: [
                ["name": "spotify_pause", "description": "Pause Spotify playback.", "input_schema": ["type": "object", "properties": [:]] as [String: Any]] as [String: Any],
                ["name": "spotify_resume", "description": "Resume Spotify playback after a pause.", "input_schema": ["type": "object", "properties": [:]] as [String: Any]],
                ["name": "spotify_next", "description": "Skip to the next track on Spotify.", "input_schema": ["type": "object", "properties": [:]] as [String: Any]],
                ["name": "spotify_previous", "description": "Go to the previous track on Spotify.", "input_schema": ["type": "object", "properties": [:]] as [String: Any]]
            ])
        }

        if available.calendar {
            out.append(contentsOf: [
                [
                    "name": "calendar_add_event",
                    "description": "Add an event to the calendar, starting a given number of minutes from now. Use for 'add a meeting in an hour', 'block 30 minutes for lunch'. Only relative times are supported.",
                    "input_schema": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string", "description": "The event title, e.g. 'dentist'."],
                            "offset_minutes": ["type": "integer", "description": "Minutes from now until the event starts, e.g. 60 for 'in an hour'."],
                            "duration_minutes": ["type": "integer", "description": "Event length in minutes. Defaults to 60."]
                        ],
                        "required": ["title", "offset_minutes"]
                    ]
                ],
                [
                    "name": "calendar_list_today",
                    "description": "List today's calendar events (title and start time) across all calendars. Use for 'what's on my calendar', 'what do I have today'.",
                    "input_schema": ["type": "object", "properties": [:]]
                ]
            ])
        }

        if available.contacts {
            out.append([
                "name": "contacts_lookup",
                "description": "Look up a person in Contacts by (partial) name and get their phone numbers and email addresses. Use before messages_send or mail_send when the user names a person, e.g. 'text mom' or 'email dan'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Full or partial contact name, e.g. 'mom', 'Dan Brooks'."]
                    ],
                    "required": ["name"]
                ]
            ])
        }

        if available.messages {
            out.append([
                "name": "messages_send",
                "description": "Send an iMessage. Use for 'text mom I'm on my way', 'message dan the address'. The recipient must be a phone number or email handle; resolve a contact name with contacts_lookup first. This sends immediately.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "recipient": ["type": "string", "description": "Phone number (e.g. +16175551234) or iMessage email handle."],
                        "text": ["type": "string", "description": "The message body to send."]
                    ],
                    "required": ["recipient", "text"]
                ]
            ])
        }

        if available.facetime {
            out.append([
                "name": "facetime_call",
                "description": "Start a FaceTime call (the user confirms in FaceTime before it dials). Use for 'facetime mom', 'call dan on facetime'. The recipient must be a phone number or email handle; resolve a contact name with contacts_lookup first.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "recipient": ["type": "string", "description": "Phone number (e.g. +16175551234) or FaceTime email handle."],
                        "audio_only": ["type": "boolean", "description": "true for a FaceTime Audio call. Defaults to false (video)."]
                    ],
                    "required": ["recipient"]
                ]
            ])
        }

        if available.reminders {
            out.append([
                "name": "reminders_add",
                "description": "Add a reminder to the default Reminders list. Use for 'remind me to X', 'add a reminder to Y'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The reminder text, e.g. 'buy milk'."]
                    ],
                    "required": ["text"]
                ]
            ])
        }

        if available.clipboard {
            out.append(contentsOf: [
                [
                    "name": "clipboard_read",
                    "description": "Read the current text on the clipboard. Use for 'what's on my clipboard', 'read me what I copied'.",
                    "input_schema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "clipboard_write",
                    "description": "Put text on the clipboard, replacing what is there. Use for 'copy that to my clipboard', 'put X on the clipboard'.",
                    "input_schema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string", "description": "The text to place on the clipboard."]
                        ],
                        "required": ["text"]
                    ]
                ]
            ])
        }

        if available.shortcuts {
            out.append(contentsOf: [
                [
                    "name": "shortcuts_list",
                    "description": "List the user's Shortcuts by name so the agent can pick one to run.",
                    "input_schema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "shortcuts_run",
                    "description": "Run a Shortcut by exact name. Use only after shortcuts_list has returned a matching entry.",
                    "input_schema": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Exact Shortcut name."]
                        ],
                        "required": ["name"]
                    ]
                ]
            ])
        }

        if available.safari {
            out.append([
                "name": "safari_open_url",
                "description": "Open a URL in Safari (as opposed to the user's default browser). Use only when the user specifically asks for Safari.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string"]
                    ],
                    "required": ["url"]
                ]
            ])
        }

        if available.spotlight {
            out.append([
                "name": "spotlight_search",
                "description": "Search the user's Mac via Spotlight and return the top hits. Use for 'find my invoice', 'where's the file called X'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Spotlight query string."]
                    ],
                    "required": ["query"]
                ]
            ])
        }

        return out
    }
}

/// Runtime feature detection for the macOS integration tools.
/// Populated by `MirageMacIntegrations.availability()` — Peeky's
/// `is_available()` convention ported into a struct so `integrationTools`
/// can build a schema list off it directly.
struct MirageIntegrationAvailability {
    var spotify: Bool = false
    var calendar: Bool = false
    var contacts: Bool = false
    var messages: Bool = false
    var facetime: Bool = false
    var reminders: Bool = false
    var clipboard: Bool = true       // Cocoa NSPasteboard, always available
    var shortcuts: Bool = false
    var safari: Bool = false
    var spotlight: Bool = true       // NSMetadataQuery, always available

    /// All-available flavor for testing.
    static let all = MirageIntegrationAvailability(
        spotify: true, calendar: true, contacts: true, messages: true,
        facetime: true, reminders: true, clipboard: true, shortcuts: true,
        safari: true, spotlight: true
    )

    /// Nothing available — safe default until MirageMacIntegrations
    /// registers its runtime probe result.
    static let none = MirageIntegrationAvailability()
}
