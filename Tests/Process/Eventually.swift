import Foundation
import Testing

/// Polls `condition` until it holds or `timeout` passes (generous: tests share the machine, and
/// a tier's tests share its main actor; it returns as soon as it holds). A wait that held only
/// after more than 3 s is recorded as a warning, which fails nothing: a stalled process or a
/// starved main actor shows up long before it costs a timeout. It runs on the caller's actor, so
/// `condition` reads the caller's state as it is, and may itself wait for something that answers
/// later (a page).
func eventually(
    timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation, isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    var held = try await condition()
    while !held, clock.now < start + timeout {
        try? await Task.sleep(for: .milliseconds(10))
        held = try await condition()
    }
    let waited = start.duration(to: clock.now)
    if held, waited > .seconds(3) {
        func seconds(_ duration: Duration) -> String {
            let (whole, fraction) = duration.components
            return String(format: "%.1f s", Double(whole) + Double(fraction) / 1e18)
        }
        Issue.record("slow: held after \(seconds(waited)) of its \(seconds(timeout))", severity: .warning, sourceLocation: sourceLocation)
    }
    return held
}

/// A mutable value closures can share: what a `@MainActor` closure (Sendable) changes after
/// capture.
@MainActor
final class Ref<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A test's own error: what went wrong, in words.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
