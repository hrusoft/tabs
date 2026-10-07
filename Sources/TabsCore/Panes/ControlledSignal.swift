import AppKit
import TabsPluginSDK

/// The one signal kind core declares itself: **controlled**, a pane another
/// pane drives through `tabs-ctl` — a pulsing robot before the title, the
/// pane's own border in the theme's `agent` color — raised while the ownership
/// ledger has an owner for the pane. Until withdrawn (a state, not a request
/// for attention), never on the tabs holding the pane, a slow 4.5 s pulse, the
/// tooltip the icon carries, and Settings ▸ Panes & Tabs' "Control indicator"
/// switch.
///
/// Core's, not a plugin's: ownership is core's, and the cue must look the same
/// whichever plugin's pane is controlled. It sits after every plugin's kinds,
/// so on a pane that also carries a plugin's signal the outline is the
/// controlled one's.
@MainActor
package enum ControlledSignal {
    package static let id = "controlled"
    package static let signal = PaneSignal(id)

    package static var kind: PaneSignalContribution {
        PaneSignalContribution(
            id: id, label: "Controlled by another pane", icon: .image(robotGlyph), color: .agent, pulse: 4.5, marksTabs: false,
            lifetime: .untilWithdrawn, tooltip: "Controlled by another pane",
            setting: .init(
                title: "Control indicator",
                detail: "Pulse a robot icon and highlight a pane's own border while another pane is controlling it."))
    }

    /// The robot: an antenna dot and stem, a rounded head, two eyes and a
    /// mouth, stroked 1.2, round caps and joins, in a 16-unit box drawn y down
    /// at any scale.
    static let robotGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: 7, y: 0, width: 2, height: 2)).fill()
            let stem = NSBezierPath()
            stem.move(to: CGPoint(x: 8, y: 2))
            stem.line(to: CGPoint(x: 8, y: 3.5))
            stroke(stem, round: true)
            stroke(NSBezierPath(roundedRect: CGRect(x: 2.5, y: 3.5, width: 11, height: 9), xRadius: 2, yRadius: 2), round: false)
            NSBezierPath(ovalIn: CGRect(x: 5.7 - 1.1, y: 8 - 1.1, width: 2.2, height: 2.2)).fill()
            NSBezierPath(ovalIn: CGRect(x: 10.3 - 1.1, y: 8 - 1.1, width: 2.2, height: 2.2)).fill()
            let mouth = NSBezierPath()
            mouth.move(to: CGPoint(x: 5.5, y: 10.8))
            mouth.line(to: CGPoint(x: 10.5, y: 10.8))
            stroke(mouth, round: true)
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func stroke(_ path: NSBezierPath, round: Bool) {
        path.lineWidth = 1.2
        if round {
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
        }
        path.stroke()
    }
}
