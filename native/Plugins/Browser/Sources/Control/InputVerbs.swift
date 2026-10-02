import Foundation
import TabsPluginSDK

/// The verbs that drive a page with input: `click`, `hover`, `type`, `key`, `scroll` and
/// `form-input` (`renderer/inputVerbs.ts`, their specs in `shared/controlSpec.ts`, their budgets in
/// `main/browserExternalControl.ts`), and the host-focus guard they run under.
///
/// None of them focuses the page itself: input goes straight to it as `NSEvent`s (`PageInput`). What
/// focus the page pulls anyway, when a script inside it calls `el.focus()` or a click lands, is undone by
/// `PageInput.withHostFocusRestored`, so an agent driving a pane never takes the keyboard from the
/// terminal the user is typing in. Injected input also never goes through the app's event monitors,
/// so it can't activate the pane the way a user's press does (what the Electron app's
/// `suppressGuestActivation` counter exists to prevent): the active pane stays where it was.
///
/// A verb that is given a pane that isn't mounted (no window to address an event to) says so as any
/// verb does (`paneNotMountedError`).
@MainActor
enum InputVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] {
        [click, hover, type, key, scroll, formInput]
    }

    // MARK: Specs

    /// The `{role, name, tag}` an input verb reports for the element it acted on.
    static let elementShape: JSONValue = ["role": "string", "name": "string", "tag": "string"]

    /// A press or a move at a target: `{x, y, element}`.
    static let pointShape: JSONValue = ["x": "number", "y": "number", "element": elementShape]

    /// The quick tier of `browserExternalControl.ts`: one resolve round trip and one injected event.
    static let quick = Duration.seconds(5)
    /// The read tier: input that may first reveal, scroll or settle the page (type's per-key pacing).
    static let read = Duration.seconds(15)

    // MARK: click, hover

    static let click = ControlVerbContribution(
        name: "browser.click",
        summary:
            "Click an element or a viewport coordinate, with real mouse events. A ref is re-checked at dispatch time and the result reports the element hit.",
        target: .ownedPane(ofTypes: ["browser"]), timeout: quick, command: "click", wireType: "click", resultShape: pointShape,
        composition: .elementTarget
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        let target = try elementTarget(invocation["target"])
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                // Deliberately no focus of the page: the events go straight in (see the type's doc).
                //
                // One round trip remains between the hit test and the events landing, unclosable
                // without giving up real input events: dispatch is host-side by design.
                let point = try await pointed(target, in: pane)
                try await TargetingInput(page: pane.page).clickAt(x: point.x, y: point.y)
                return report(point)
            }
        }
    }

    /// Moves the pointer onto the target and stops there: no press.
    ///
    /// Resolution is `click`'s, unchanged: the same `resolveClickTarget`, so a ref is scrolled into view
    /// and hit-tested, a covered element fails naming both, and a coordinate is taken as given. What
    /// differs is only the dispatch. The hover *persists*: the page holds the hovered element until the
    /// next pointer event reaches it, so the follow-up read that inspects what appeared does not need to
    /// re-hover to keep a menu open. (A second hover onto the same point is still a real `mouseMoved`,
    /// but produces no fresh `mouseenter`, which is exactly what a real pointer sitting still does.)
    ///
    /// **Only in the key window.** WebKit delivers no pointer move to a page whose window isn't key
    /// (`PageInput`), where Chromium hovers a background window too, so there the verb fails with
    /// `hoverWindowNotActiveError` after resolving the target (a bad target is still the error a caller
    /// sees first), rather than answer for a move the page never saw.
    static let hover = ControlVerbContribution(
        name: "browser.hover",
        summary:
            "Move the pointer onto an element without pressing it — for a menu that opens on hover but navigates on click. Read the page afterwards to see what appeared. Works only while the pane's window is the active one.",
        target: .ownedPane(ofTypes: ["browser"]), timeout: quick, command: "hover", wireType: "hover", resultShape: pointShape,
        composition: .elementTarget
    ) { invocation in
        let pane = try VerbSupport.pane(invocation)
        let target = try elementTarget(invocation["target"])
        let input = PageInput(page: pane.page)
        return try await mounted {
            try await input.withHostFocusRestored {
                let point = try await pointed(target, in: pane)
                do {
                    try await input.move(x: point.x, y: point.y)
                } catch PageInput.Failure.windowNotActive {
                    throw ControlVerbError(hoverWindowNotActiveError)
                } catch PageInput.Failure.cannotMovePointer {
                    throw ControlVerbError(hoverUnsupportedError)
                }
                return report(point)
            }
        }
    }

    // MARK: Shared

    /// The target of a request, or the message that names what is wrong with it.
    static func elementTarget(_ wire: JSONValue?) throws -> ElementTarget {
        switch InputTarget.parse(wire) {
        case .success(let target): return target
        case .failure(let failure): throw ControlVerbError(failure.message)
        }
    }

    /// Where a target's input lands, or the error that says why it can't.
    static func pointed(_ target: ElementTarget, in pane: BrowserPane) async throws -> TargetingInput.Point {
        switch await TargetingInput(page: pane.page).resolveClickTarget(target) {
        case .success(let point): return point
        case .failure(let failure): throw ControlVerbError(failure.message)
        }
    }

    /// What click and hover answer: where the pointer went and what sits there.
    static func report(_ point: TargetingInput.Point) -> JSONValue {
        var result: [String: JSONValue] = ["x": InputTarget.json(point.x), "y": InputTarget.json(point.y)]
        if let element = point.element { result["element"] = InputTarget.json(element) }
        return .object(result)
    }

    /// Why a hover in a window that isn't key fails, and what to do instead.
    static let hoverWindowNotActiveError =
        "the pointer move can't reach the page: WebKit delivers hover only to the active window, and this pane's window isn't — bring the Tabs window to the front and retry, or use click if pressing the element is acceptable"

    /// Why a hover fails where WebKit offers no way to move the pointer (`PageInput.sendMove`).
    static let hoverUnsupportedError =
        "this version of WebKit offers no way to move the pointer onto the page, so hover can't work — use click if pressing the element is acceptable"

    /// Runs `action`, answering a page with no window as a pane that isn't mounted.
    static func mounted<T>(_ action: () async throws -> T) async throws -> T {
        do {
            return try await action()
        } catch PageInput.Failure.notMounted {
            throw ControlVerbError(paneNotMountedError)
        }
    }
}
