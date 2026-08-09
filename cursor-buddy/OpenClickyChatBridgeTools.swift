//
//  OpenClickyChatBridgeTools.swift
//  cursor-buddy
//
//  F32 landing — thin app-side shim for the SPM ChatBusTools. Exists
//  so `OpenClickyExternalControlBridgeServer.executeSensorTool` can
//  dispatch `chat_*` calls the same way it dispatches
//  `connector_*` / `opencli_*` — a static `execute(name:arguments:)`.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Source: src/Everywhere.Mcp/Tools/ChatBusTools.cs
//

import Foundation
import OpenClickyContextService

enum OpenClickyChatBridgeTools {

    static var toolNames: Set<String> { OpenClickyChatBusTools.toolNames }

    static var descriptorsRaw: [[String: Any]] { OpenClickyChatBusTools.descriptorsRaw }

    /// Sync -> async wrapper so the caller's dispatch switch stays
    /// consistent with the other bridge tool families.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        return OpenClickyChatBusTools.execute(name: name, arguments: arguments)
    }
}
