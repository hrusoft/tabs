import Foundation
import Observation
import SwiftUI
import os

/// A plugin's settings struct. `init()` supplies the defaults.
///
/// Stored settings are merged over the encoded defaults before decoding, so a
/// field added in a later build takes its default instead of failing to decode.
/// Top-level fields this build doesn't know (written by a newer one) are
/// carried through every update, so running an older build never erases them.
/// If the stored value can't be decoded at all (a field changed type), the
/// plugin gets defaults and the stored value is left untouched until the user
/// changes a setting — a bad decode never destroys data by itself.
public protocol PluginSettingsValue: Codable, Equatable, Sendable {
    init()
}

/// Live, observable settings for one plugin. SwiftUI views observe `value`
/// directly; AppKit code uses `observe`.
@MainActor
@Observable
public final class PluginSettings<Value: PluginSettingsValue> {
    public private(set) var value: Value

    @ObservationIgnored private let pluginID: PluginID
    @ObservationIgnored private let backend: any SettingsBackend
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private var observers: [(token: Int, handler: @MainActor (Value) -> Void)] = []
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var isInvalidated = false
    /// Stored top-level fields `Value` doesn't have, kept on every write.
    @ObservationIgnored private let unknownFields: [String: JSONValue]
    @ObservationIgnored private var pendingNotifications: [Value] = []
    @ObservationIgnored private var isNotifying = false

    package init(pluginID: PluginID, backend: any SettingsBackend, log: Logger) {
        self.pluginID = pluginID
        self.backend = backend
        self.log = log
        (value, unknownFields) = Self.decode(backend.storedSettings(for: pluginID), pluginID: pluginID, log: log)
    }

    public func update(_ mutate: (inout Value) -> Void) {
        guard !isInvalidated else {
            log.fault("ignored a settings update from \(self.pluginID.rawValue, privacy: .public) after it stopped")
            return
        }
        guard !backend.isReadOnly else {
            log.error("refused a settings update from \(self.pluginID.rawValue, privacy: .public): settings are read-only here (headless)")
            return
        }
        var next = value
        mutate(&next)
        guard next != value else { return }
        // All or nothing: a value that can't be stored (a NaN, say) isn't taken.
        var encoded: JSONValue
        do {
            encoded = try JSONValue(encoding: next)
        } catch {
            log.error("refused a settings update that cannot be stored: \(String(describing: error), privacy: .public)")
            return
        }
        if case .object(var fields) = encoded {
            for (key, field) in unknownFields where fields[key] == nil { fields[key] = field }
            encoded = .object(fields)
        }
        value = next
        backend.store(encoded, for: pluginID)
        notify(next)
    }

    /// In order, for every observer: an update made from inside an observer
    /// is delivered after the current one has reached everyone.
    private func notify(_ value: Value) {
        pendingNotifications.append(value)
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        while !pendingNotifications.isEmpty {
            let next = pendingNotifications.removeFirst()
            for observer in observers { observer.handler(next) }
        }
    }

    /// Stops the instance for good: later updates are ignored and observers are
    /// dropped. Core calls it when the plugin deactivates or fails.
    package func invalidate() {
        isInvalidated = true
        observers.removeAll()
    }

    /// Calls `handler` after every change (not initially).
    public func observe(_ handler: @escaping @MainActor (Value) -> Void) -> Subscription {
        nextToken += 1
        let token = nextToken
        observers.append((token, handler))
        return Subscription { [weak self] in self?.observers.removeAll { $0.token == token } }
    }

    /// A SwiftUI binding to one field.
    public func binding<Field: Sendable>(_ keyPath: WritableKeyPath<Value, Field> & Sendable) -> Binding<Field> {
        Binding(
            get: { MainActor.assumeIsolated { self.value[keyPath: keyPath] } },
            set: { newValue in MainActor.assumeIsolated { self.update { $0[keyPath: keyPath] = newValue } } }
        )
    }

    /// The value, and the stored top-level fields it has no place for.
    static func decode(_ stored: JSONValue?, pluginID: PluginID, log: Logger) -> (Value, unknown: [String: JSONValue]) {
        guard let stored else { return (Value(), [:]) }
        do {
            let defaults = try JSONValue(encoding: Value())
            let value = try stored.merged(over: defaults).decode(Value.self)
            // A field is known if it survives a round trip through `Value`.
            guard case .object(let storedFields) = stored, case .object(let known) = try JSONValue(encoding: value) else {
                return (value, [:])
            }
            return (value, storedFields.filter { known[$0.key] == nil })
        } catch {
            log.error(
                "stored settings for \(pluginID.rawValue, privacy: .public) do not decode; using defaults: \(String(describing: error), privacy: .public)"
            )
            return (Value(), [:])
        }
    }
}

/// Where settings live. Core-only: plugins receive `PluginSettings`.
@MainActor
package protocol SettingsBackend: AnyObject {
    /// Headless modes: nothing may change (an update is refused, not faked).
    var isReadOnly: Bool { get }
    func storedSettings(for plugin: PluginID) -> JSONValue?
    func store(_ value: JSONValue, for plugin: PluginID)
}
