import AppKit
import Testing

@testable import Tabs

extension UITests {
    /// The app acts only on key events the system delivered (`TabsApplication`, docs/BROWSER.md D-3): one a
    /// view was handed directly and passed on through `NSApp.sendEvent` (a web view with a key its page
    /// didn't handle) never reaches the app's monitors or menu; one taken from the queue does, passed on
    /// again included.
    @MainActor
    @Suite struct InjectedKeys {
        /// F19: a key no command binds, so the monitor is all it reaches.
        private static func key(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 80)
        }

        @Test func aKeyTheSystemNeverDeliveredNeverReachesTheApp() async throws {
            #expect(NSApp is TabsApplication, "the principal class")
            let seen = Ref<[NSEvent]>([])
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                MainActor.assumeIsolated { seen.value.append(event) }
                return nil
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }

            let injected = try #require(Self.key(.keyDown))
            NSApp.sendEvent(injected)
            #expect(seen.value.isEmpty, "an injected key went nowhere")

            let queued = try #require(Self.key(.keyDown))
            NSApp.postEvent(queued, atStart: false)
            #expect(await eventually { !seen.value.isEmpty }, "a key from the queue reaches the monitors")
            let delivered = try #require(seen.value.first)
            NSApp.sendEvent(delivered)
            #expect(seen.value.count == 2, "and so does the same key handed back")
        }

        @Test func everyOtherKindOfEventPasses() throws {
            let keys = DeliveredKeys()
            let move = try #require(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                    clickCount: 0, pressure: 0))
            #expect(keys.admits(move))
            let up = try #require(Self.key(.keyUp))
            #expect(!keys.admits(up))
            keys.note(up)
            #expect(keys.admits(up))
            // Remembered as long as it is alive, however many keys follow (a page far behind hands its key back late).
            var later: [NSEvent] = []
            for _ in 0..<200 {
                let key = try #require(Self.key(.keyDown))
                keys.note(key)
                later.append(key)
            }
            #expect(keys.admits(up))
            #expect(later.allSatisfy(keys.admits))
        }
    }
}
