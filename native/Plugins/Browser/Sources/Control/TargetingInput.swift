import Foundation
import TabsPluginSDK

/// Naming an element for an input verb: resolving a ref, a semantic target or a
/// point to where input should land (`resolveClickTarget`) or what should hold the
/// keyboard (`focusTypingTarget`), and pressing there (`clickAt`). The impure half
/// of `renderer/targeting.ts`: what needs the page and its input. The wording every
/// targeting error shares is `Targeting` (VerbSupport.swift).
@MainActor
struct TargetingInput {
    let page: BrowserPage

    private var input: PageInput { PageInput(page: page) }

    /// Where input lands: a point of the page's viewport (CSS pixels), and what sits there.
    struct Point: Equatable {
        var x: Double
        var y: Double
        var element: ElementDescription?
    }

    /// How long the host waits before the one hit-test retry. Host-timed rather
    /// than an in-page `requestAnimationFrame` on purpose: a page that is not on
    /// screen throttles rAF and timers, and agents routinely drive panes that
    /// aren't visible, so an in-page wait could hang the verb until its budget
    /// fires, while a host timer is as reliable as any other.
    static let hitTestRetryDelayMs = 100

    /// Turns an `ElementTarget` into the viewport coordinate to dispatch at, plus
    /// what sits there. A ref or semantic target is resolved, scrolled into view,
    /// and hit-tested in one page script immediately before dispatch, so a layout
    /// shift since `read-page` moves the click with the element instead of leaving
    /// the coordinate pointing at whatever slid into its old spot; a point that no
    /// longer holds the element (an overlay, a collapse) gets one retry (transient
    /// reflows settle within it) and then a loud failure naming both elements,
    /// which beats silently clicking the wrong thing. A raw `{x, y}` is taken
    /// as-is and only described, never refused: the caller named the exact point.
    func resolveClickTarget(_ target: ElementTarget) async -> Result<Point, VerbFailure> {
        if case .point(let x, let y) = target {
            // A page that can't run script (an error page, a viewer) can still be
            // clicked: the description is reporting, never a gate.
            var element: ElementDescription?
            if case .success(let hit) = await page.evaluate(describePointScript(x: x, y: y)) {
                element = InputTarget.description(of: hit)
            }
            return .success(Point(x: x, y: y, element: element))
        }

        let named: NamedTarget
        switch Targeting.namedTargetResolver(target) {
        case .success(let resolved): named = resolved
        case .failure(let failure): return .failure(failure)
        }

        let script = hitTestPointScript(named.resolver)
        var run = await VerbSupport.evalOutcomeInGuest(page, script)
        if case .success(let outcome) = run, outcome["resolved"] == true, outcome["matched"] != true {
            await delay(milliseconds: Self.hitTestRetryDelayMs)
            run = await VerbSupport.evalOutcomeInGuest(page, script)
        }
        let outcome: [String: JSONValue]
        switch run {
        case .failure(let failure): return .failure(failure)
        case .success(let value): outcome = value
        }
        guard outcome["resolved"] == true else {
            return .failure(VerbFailure(outcome["reason"]?.stringValue ?? named.notResolved))
        }
        let intended = InputTarget.description(of: outcome["intended"])
        guard outcome["matched"] == true else {
            let remedy: String
            if case .ref = target {
                remedy = "call readPage again, or click by coordinate to press what is actually there"
            } else {
                remedy = "dismiss what covers it, or click by coordinate to press what is actually there"
            }
            return .failure(
                VerbFailure(
                    "clicking \(named.described) (\(Targeting.describeForError(intended))) would land on \(Targeting.describeForError(InputTarget.description(of: outcome["element"]))) instead — the layout shifted or another element covers it; \(remedy)"
                ))
        }
        return .success(
            Point(x: outcome["x"]?.doubleValue ?? 0, y: outcome["y"]?.doubleValue ?? 0, element: intended))
    }

    /// A left click at a point: a move first, so a page that only reveals a
    /// control on hover has seen the pointer arrive before the press lands on it.
    func clickAt(x: Double, y: Double) async throws {
        try await input.click(x: x, y: y)
    }

    /// Puts the page's focus where typed text should land. A ref or semantic
    /// target is focused directly rather than clicked (an overlay could swallow
    /// the click): the semantic form resolves and focuses in the same page
    /// script, so no layout shift fits between match and focus; a coordinate has
    /// nothing to focus but the point itself, so that one clicks. Answers nil on
    /// success, else a complete error: a semantic failure already names its
    /// candidates or its remedy, and a generic suffix appended here would read as
    /// noise after them. The caller decides whether that aborts the verb (`type`)
    /// or just skips the field (`form-input`).
    func focusTypingTarget(_ target: ElementTarget) async throws -> VerbFailure? {
        if case .point(let x, let y) = target {
            try await clickAt(x: x, y: y)
            return nil
        }
        let named: NamedTarget
        switch Targeting.namedTargetResolver(target) {
        case .success(let resolved): named = resolved
        case .failure(let failure): return failure
        }
        let outcome: [String: JSONValue]
        switch await VerbSupport.evalOutcomeInGuest(page, focusTargetScript(named.resolver)) {
        case .failure(let failure): return failure
        case .success(let value): outcome = value
        }
        // A resolved-but-unfocusable element always carries its own reason; only a
        // target that resolved to nothing falls through to the shared wording.
        if outcome["focused"] != true { return VerbFailure(outcome["reason"]?.stringValue ?? named.notResolved) }
        return nil
    }
}
