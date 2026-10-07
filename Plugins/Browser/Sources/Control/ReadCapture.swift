import AppKit
import Foundation
import TabsPluginSDK

/// `screenshot`.
@MainActor
enum ReadCapture {
    /// How long `screenshot` gives a pane it just revealed to become paintable: core lays the
    /// revealed tab out and the view gets a size and a window, neither of which is done the
    /// instant the reveal returns. Far under the read tier's budget, so the bounded failure
    /// below reaches the caller instead of a deadline.
    static let revealCaptureWaitMs = 3_000

    /// The rect a capture is clipped to, in whole CSS pixels, and the element it is.
    struct Clip: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var element: JSONValue

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        var json: JSONValue {
            .object(["x": .int(Int64(x)), "y": .int(Int64(y)), "width": .int(Int64(width)), "height": .int(Int64(height))])
        }
    }

    /// Resolves `screenshot`'s optional `selector`/`ref` into the rect to clip to.
    ///
    /// Two things the page cannot do for itself happen here. The rect is **clamped to the
    /// viewport**, because a snapshot can only ever return pixels the page is showing: an
    /// element taller than the screen would otherwise request rows that do not exist. And the
    /// rect is **rounded outward** to whole CSS pixels: a fractional rect (a `translateY(0.5px)`,
    /// a `zoom`) would otherwise cut a sliver off the element's own edge, which reads as a
    /// rendering bug in the page rather than as rounding here.
    static func resolveClip(_ page: BrowserPage, target: ElementTarget, viewport: PageViewport) async -> Result<Clip, VerbFailure> {
        let named: NamedTarget
        switch Targeting.namedTargetResolver(target) {
        case .failure(let failure): return .failure(failure)
        case .success(let resolved): named = resolved
        }
        let outcome: [String: JSONValue]
        switch await VerbSupport.evalOutcomeInGuest(page, elementRectScript(named.resolver)) {
        case .failure(let failure): return .failure(failure)
        case .success(let object): outcome = object
        }
        guard outcome["resolved"] == true, let rect = outcome["rect"], let x = rect["x"]?.doubleValue, let y = rect["y"]?.doubleValue,
            let width = rect["width"]?.doubleValue, let height = rect["height"]?.doubleValue
        else { return .failure(VerbFailure(outcome["reason"]?.stringValue ?? named.notResolved)) }

        let left = max(0, x.rounded(.down))
        let top = max(0, y.rounded(.down))
        let right = min(viewport.width, (x + width).rounded(.up))
        let bottom = min(viewport.height, (y + height).rounded(.up))
        if right <= left || bottom <= top {
            return .failure(
                VerbFailure(
                    "\(named.described) is outside the visible viewport, so there is nothing to capture — scroll it into view first"))
        }
        return .success(
            Clip(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top), element: outcome["element"] ?? .null))
    }

    /// Captures the page's visible viewport, or one element's rect within it, into a PNG file
    /// and answers its path.
    ///
    /// A hidden pane is revealed first rather than failed: a backgrounded tab is not in a
    /// window, and a view nobody can see paints nothing. That is why visibility is checked
    /// *before* any capture is attempted instead of diagnosed from how the capture failed. The
    /// reveal is the same `revealPane` the `activate-pane` verb performs (it never makes the pane
    /// active, so the no-keyboard-steal guarantee is inherited rather than re-implemented), and
    /// it is reported as `activated: true` so the caller knows the visible tab changed.
    /// `--no-activate` opts out for a caller that would rather fail than change what the user sees.
    static func screenshot(_ invocation: ControlInvocation, services: BrowserServices) async throws
        -> JSONValue
    {
        let pane = try VerbSupport.pane(invocation)
        let page = pane.page
        // Request-shape checks come first, before anything is revealed: they need nothing from
        // the page, and refusing after the reveal would change what the user is looking at and
        // spend the whole wait budget to answer a question that was unanswerable from the start.
        let selector = VerbSupport.namedString(invocation["selector"]) ? invocation["selector"]?.stringValue : nil
        let ref = VerbSupport.namedString(invocation["ref"]) ? invocation["ref"]?.stringValue : nil
        if selector != nil && ref != nil {
            throw ControlVerbError("pass only one of selector or ref — they are different ways to name one element")
        }
        let target: ElementTarget? = ref.map { .ref($0) } ?? selector.map { .semantic(SemanticTarget(selector: $0)) }

        let deadline = Date().addingTimeInterval(Double(revealCaptureWaitMs) / 1000)
        var activated = false
        if !page.isVisible {
            if invocation["noActivate"]?.boolValue == true {
                throw ControlVerbError(
                    "the pane is hidden — it is not its tab group’s active tab, so it has no frame to capture; rerun without noActivate, or run activatePane first"
                )
            }
            services.workspace.revealPane(pane.pane.paneID)
            activated = true
            _ = await pollUntil(deadline: deadline) { page.isVisible }
        }
        // Resolved after the reveal, never before: an element's rect in a hidden page is
        // meaningless, and scrolling into view in one is a no-op.
        let view = await page.viewport() ?? unshownViewport(page)
        var clip: Clip?
        if let target {
            switch await resolveClip(page, target: target, viewport: view) {
            case .failure(let failure): throw ControlVerbError(failure.message)
            case .success(let resolved): clip = resolved
            }
        }

        var snapshot = await page.snapshot(rect: clip?.rect)
        // A freshly revealed page can need a frame or two before a capture sees pixels: retry
        // inside the same budget rather than failing on the first empty image, and give the
        // view that frame before the first retry. Only after a reveal: for a pane that was
        // visible all along, an empty capture is not a state that waiting fixes.
        if activated && snapshot == nil {
            await delay(milliseconds: 100)
            _ = await pollUntil(deadline: deadline, everyMs: 100) {
                snapshot = await page.snapshot(rect: clip?.rect)
                return snapshot != nil
            }
        }
        guard let snapshot else { throw ControlVerbError("the pane produced no frame to capture") }

        // Bytes never ride the socket: the PNG is a file and the answer its path (no `--out`: a
        // screenshot only ever takes the generated form).
        let path: String
        switch services.agentFiles.write(
            snapshot.png, out: nil, subdirectory: AgentFiles.Subdirectory.screenshots, ext: "png", what: "screenshot")
        {
        case .success(let written): path = written
        case .failure(let failure): throw ControlVerbError(failure.message)
        }
        // Two different coordinate spaces, reported separately because they are not the same
        // number on a HiDPI display and conflating them silently puts every coordinate-based
        // click off by the scale factor. The image (and so `width`/`height`) is in *device*
        // pixels, while a click's coordinates, element bounding rects and read-page's rects are
        // all in *CSS* pixels. Both `viewport` and `scaleFactor` come from the page itself
        // (`BrowserPage.viewport`): `scaleFactor` is what a caller divides an image coordinate
        // by to reach the CSS pixels `click` takes, so it must be the real ratio, and the same
        // whether or not the capture was clipped.
        var result: [String: JSONValue] = [
            "path": .string(path), "width": .int(Int64(snapshot.pixelWidth)), "height": .int(Int64(snapshot.pixelHeight)),
            "viewport": .object(["width": .double(view.width), "height": .double(view.height)]), "scaleFactor": .double(view.scaleFactor),
        ]
        // The rect the capture actually used, after clamping: so a caller mapping a point on a
        // clipped image back into page space has the origin it needs.
        if let clip {
            result["clipped"] = clip.json
            result["element"] = clip.element
        }
        // Present only when the reveal actually happened: absence is the promise that the
        // user's visible tabs were not touched.
        if activated { result["activated"] = true }
        return .object(result)
    }

    /// The view's own size and its window's scale: what a page that isn't on screen can be measured by.
    private static func unshownViewport(_ page: BrowserPage) -> PageViewport {
        let view = page.webView
        return PageViewport(
            width: Double(view.bounds.width).rounded(.up), height: Double(view.bounds.height).rounded(.up),
            scaleFactor: Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1))
    }
}
