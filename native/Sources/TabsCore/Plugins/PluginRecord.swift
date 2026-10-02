import Foundation
import TabsPluginSDK

/// Where a plugin is in its life, as the Plugins window and `--plugin-report`
/// show it. Everything except `active` means none of its code is running.
package enum PluginState: Equatable, Sendable {
    /// Refused at discovery from its Info.plist and stamp alone; never loaded.
    case rejected(String)
    /// Turned off by the user and no open pane needs it; never loaded.
    case disabled
    /// Loaded, but instantiation, activation or its contributions failed. All
    /// of it was rolled back; the image stays mapped (it can't be unloaded).
    case failed(String)
    case active

    package var label: String {
        switch self {
        case .rejected: "rejected"
        case .disabled: "disabled"
        case .failed: "failed"
        case .active: "active"
        }
    }

    package var detail: String? {
        switch self {
        case .rejected(let reason), .failed(let reason): reason
        case .disabled, .active: nil
        }
    }

    /// Whether this state indicates a broken build rather than a user choice.
    package var isProblem: Bool {
        switch self {
        case .rejected, .failed: true
        case .disabled, .active: false
        }
    }
}

package struct PluginRecord: Identifiable, Equatable {
    package let id: PluginID
    package let displayName: String
    package let summary: String
    package let location: String
    package let canDisable: Bool
    /// From the manifest, when it could be read: lets a placeholder pane name
    /// the plugin that would have provided it.
    package let declaredContentTypes: [ContentTypeID]
    package var state: PluginState
    /// The user's setting (Plugins window). A disabled plugin can still be
    /// active when something needs it; it just offers no creation actions.
    package var userEnabled: Bool
    package var contributionCounts: [String: Int] = [:]
    /// Why things are the way they are, beyond `state` (e.g. why a disabled
    /// plugin is loaded anyway).
    package var notes: [String] = []
    /// Calls the plugin made at a time its context refused them.
    package var ignoredCalls: [String] = []
    package var activationTime: Duration?

    /// Active and allowed to offer creation actions and settings pages.
    package var offersCreation: Bool { state == .active && userEnabled }

    package func reportValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "displayName": .string(displayName),
            "state": .string(state.label),
            "enabled": .bool(userEnabled),
            "location": .string(location),
            "contributions": .object(contributionCounts.mapValues { .int(Int64($0)) }),
        ]
        if let detail = state.detail { object["detail"] = .string(detail) }
        if !notes.isEmpty { object["notes"] = .array(notes.map(JSONValue.string)) }
        if !ignoredCalls.isEmpty { object["ignoredCalls"] = .array(ignoredCalls.map(JSONValue.string)) }
        if let activationTime {
            let (seconds, attoseconds) = activationTime.components
            object["activationMilliseconds"] = .double((Double(seconds) * 1000 + Double(attoseconds) / 1e15).rounded(toPlaces: 2))
        }
        return .object(object)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
