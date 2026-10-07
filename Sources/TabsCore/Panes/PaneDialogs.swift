import Foundation
import TabsPluginSDK

/// A question a pane asked (`PaneContext.confirm/choose/alert`), as the shell
/// shows it: one card, one answer.
package enum PaneDialog: Equatable, Sendable {
    case confirm(PaneConfirm)
    case choose(PaneChoose)
    case alert(PaneAlert)

    /// What the user meant, for a dialog that ended.
    package enum Answer: Equatable, Sendable {
        case confirmed(Bool)
        case chose(Int?)
        case acknowledged
    }

    /// The answer when there is no window to ask in (headless, tests): the
    /// card's default button — confirm goes ahead, choose keeps its first
    /// option, an alert is read.
    package var defaultAnswer: Answer {
        switch self {
        case .confirm: .confirmed(true)
        case .choose(let dialog): .chose(dialog.options.isEmpty ? nil : 0)
        case .alert: .acknowledged
        }
    }

    /// The answer when the user backs out (Escape, a click outside the card,
    /// the pane closing): nothing is confirmed or chosen.
    package var dismissedAnswer: Answer {
        switch self {
        case .confirm: .confirmed(false)
        case .choose: .chose(nil)
        case .alert: .acknowledged
        }
    }
}
