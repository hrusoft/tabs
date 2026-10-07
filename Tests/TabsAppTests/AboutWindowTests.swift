import AppKit
import Foundation
import Testing

@testable import Tabs
@testable import TabsCore

extension UITests {
    // MARK: - The About window (docs/ABOUT.md)

    /// A sleep a test releases by hand, so the 1.5 s "Copied" confirmation needs no waiting (and no race).
    final class SleepGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func sleep(_ duration: Duration) async throws {
            await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
        }

        var pending: Int { lock.withLock { waiters.count } }

        /// Ends the `index`th sleep that was started (in order); the others keep waiting.
        func release(_ index: Int) {
            let continuation = lock.withLock { waiters.indices.contains(index) ? waiters.remove(at: index) : nil }
            continuation?.resume()
        }
    }

    /// The window's contract over a recording opener and pasteboard and a hand-released clock.
    /// Its cases are the ids in docs/ABOUT.md; what the model alone decides is `AboutModelTests`'.
    @MainActor
    @Suite struct About {
        /// What the window handed the OS, in order.
        @MainActor private final class Recorder {
            var opened: [URL] = []
            var copied: [String] = []
        }

        @MainActor private final class Box {
            private let recorder = Recorder()
            let gate = SleepGate()
            let model: AboutModel
            let controller: AboutWindowController
            var openedURLs: [URL] { recorder.opened }
            var copiedTexts: [String] { recorder.copied }

            /// A credit of the window's own, whatever the build links (`AboutContentTests` holds the real list).
            static let credits = [Attribution(name: "Example", license: "MIT", url: "https://example.com/example")]

            init(version: String = "9.8.7", credits: [Attribution] = Box.credits) {
                let gate = gate
                let recorder = recorder
                model = AboutModel(
                    version: version, credits: credits, opener: { recorder.opened.append($0) },
                    pasteboard: { recorder.copied.append($0) }, sleep: { try await gate.sleep($0) })
                controller = AboutWindowController(model: model)
            }

            var body: AboutBodyView { controller.body }
            var window: NSWindow { controller.window! }

            func layout() { body.layoutSubtreeIfNeeded() }

            /// The scrolled content, flipped: y grows downward from the top of the page.
            var document: NSView { body.scrollView.documentView! }
            var foldHeight: CGFloat { body.scrollView.contentView.bounds.height }

            /// `view`'s frame in the page's coordinates (y down, 0 = the top of the content).
            func frame(_ view: NSView) -> CGRect {
                layout()
                return view.convert(view.bounds, to: document)
            }

            func scroll(to view: NSView) {
                body.scrollToTop(of: view)
                layout()
            }

            func click(_ view: NSView) throws {
                layout()
                let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                try InputSynthesizer.click(at: center, in: view, expecting: view.accessibilityIdentifier())
            }

            /// Waits until `count` timers have started: a press starts its timer in a task of its own.
            func timersStarted(_ count: Int) async {
                await settle { self.gate.pending >= count }
            }

            /// Polls `check` until it holds, for up to 5 s: a deadline, not a count of polls, so a
            /// loaded machine's longer sleeps don't cut the wait short.
            func settle(_ check: () -> Bool) async {
                let deadline = Date().addingTimeInterval(5)
                while !check(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            }

            func remove() {
                controller.close()
            }
        }

        // MARK: Opening and closing (A-1…A-9)

        @Test func theWindowIsAStandardFixedSizeWindow() throws {  // A-3, A-4
            let box = Box()
            defer { box.remove() }
            #expect(box.window.title == "About Tabs")
            #expect(box.window.contentLayoutRect.size == NSSize(width: 460, height: 630), "460×630 of content")
            #expect(!box.window.styleMask.contains(.resizable))
            #expect(box.window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable]))
            #expect(box.window.standardWindowButton(.zoomButton)?.isEnabled == false, "not maximizable")
            #expect(box.window.collectionBehavior.contains(.fullScreenNone), "not fullscreenable")
            #expect(box.window.parent == nil, "independent: it can sit on another Space beside the workspace")
            #expect(!box.window.isReleasedWhenClosed)
        }

        @Test func presentingItTwiceGivesTheOneWindow() {  // A-1, A-2, A-9
            let presenter = AboutPresenter(presentsWindows: false)
            #expect(presenter.controller == nil)
            let first = presenter.show()
            defer { presenter.dismiss() }
            #expect(presenter.show() === first, "never a second one")
            #expect(first.window?.isVisible == false, "hidden mode builds it without showing or focusing it")
        }

        @Test func closingDropsTheWindowAndTheNextOneIsFresh() throws {  // A-6
            let presenter = AboutPresenter(presentsWindows: false) { AboutWindowController(model: AboutModel(credits: Box.credits)) }
            let first = presenter.show()
            first.body.scrollToTop(of: try #require(first.body.sections["about-attributions"]))
            first.window?.close()
            #expect(presenter.controller == nil, "the singleton is dropped when the window closes")
            let second = presenter.show()
            defer { presenter.dismiss() }
            #expect(second !== first)
            #expect(second.body.scrollView.contentView.bounds.minY == 0, "scrolled to the top")
        }

        @Test func aStaleWindowClosingLeavesANewerOneInPlace() {  // A-6: the slot is the newer window's
            let presenter = AboutPresenter(presentsWindows: false)
            let first = presenter.show()
            presenter.dismiss()
            let second = presenter.show()
            defer { presenter.dismiss() }
            first.onClose?()
            #expect(presenter.controller === second)
        }

        // MARK: Identity (B-1…B-5)

        @Test func showsTheAppsIdentityWithTheRunningVersion() throws {  // B-2…B-5
            let box = Box(version: "2026.42.7")
            defer { box.remove() }
            let texts = box.body.texts
            #expect(texts.contains("Tabs"))
            #expect(box.body.versionLabel.stringValue == "Version 2026.42.7", "the version the model was given, not a literal")
            #expect(texts.contains("A fancy terminal with tabs, splits, and nested layouts."))
            #expect(texts.contains("Copyright © 2026 Hrusoft. All rights reserved."))
        }

        @Test func theIconIsDecorativeAndSeventyTwoPoints() throws {  // B-1
            let box = Box()
            defer { box.remove() }
            let icon = try #require(InputSynthesizer.find("about-icon", in: box.window))
            box.layout()
            #expect(icon.frame.size == NSSize(width: 72, height: 72))
            #expect(!icon.isAccessibilityElement(), "the name follows it: announcing the icon too would repeat it")
        }

        @Test func onlyTheVersionAndTheAddressesAreSelectable() {  // F-5
            let box = Box()
            defer { box.remove() }
            box.layout()
            func labels(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels) }
            let selectable = Set(labels(box.document).filter(\.isSelectable).map { $0.accessibilityIdentifier() })
            #expect(selectable == ["about-version", "about-address-btc", "about-address-eth"])
        }

        // MARK: Page structure (F-1…F-3)

        @Test func sectionsComeInOrderAndTheWindowScrollsRatherThanGrowing() throws {  // F-1, F-3
            let box = Box()
            defer { box.remove() }
            let identity = try #require(InputSynthesizer.find("about-identity", in: box.window))
            let order = ["about-donations", "about-crypto", "about-attributions"]
            let tops = try ([identity] + order.map { try #require(box.body.sections[$0]) }).map { box.frame($0).minY }
            #expect(tops == tops.sorted(), "identity, donations, crypto, credits")
            #expect(box.body.scrollableHeight > 0, "the page is taller than the window: the rest scrolls")
            #expect(box.window.contentLayoutRect.size == NSSize(width: 460, height: 630), "and the window stays as it was")
        }

        @Test func theIdentityAndAllThreeTiersAreAboveTheFold() throws {  // F-2
            let box = Box()
            defer { box.remove() }
            for tier in Donations.tiers {
                let frame = box.frame(try #require(box.body.tierButtons[tier.id]))
                #expect(frame.maxY <= box.foldHeight, "\(tier.id) is cut off at rest: \(frame) in \(box.foldHeight)")
            }
            let credits = try #require(box.body.sections["about-attributions"])
            #expect(box.frame(credits).minY >= box.foldHeight, "the credits are reached by scrolling")
        }

        // MARK: Donation tiers (C-1…C-6)

        @Test func offersEachTierWithItsAmountNameAndFlavor() throws {  // C-1, C-2
            let box = Box()
            defer { box.remove() }
            let texts = box.body.texts
            #expect(texts.contains("Buy me a coffee"))
            #expect(texts.contains("Like this app? You can buy me a coffee to fuel future development."))
            #expect(box.body.tierButtons.count == 3)
            for tier in Donations.tiers {
                let button = try #require(box.body.tierButtons[tier.id])
                #expect(button.amountLabel.stringValue == Donations.formatAmount(tier))
                #expect(button.nameLabel.stringValue == tier.label)
                #expect(button.flavorLabel.stringValue == tier.flavor)
            }
            #expect(Donations.tiers.map(\.label) == ["Coffee", "A pack of roasted beans", "I'm rich, I'll buy you a nice grinder"])
            let tops = try Donations.tiers.map { box.frame(try #require(box.body.tierButtons[$0.id])).minY }
            #expect(tops == tops.sorted(), "cheapest first, top to bottom")
        }

        @Test func pressingATierSendsItsOwnLinkToTheBrowser() throws {  // C-3
            let box = Box()
            defer { box.remove() }
            for tier in Donations.tiers { try box.click(try #require(box.body.tierButtons[tier.id])) }
            #expect(box.openedURLs.map(\.absoluteString) == Donations.tiers.map(\.url))
            #expect(box.window.isVisible == false)
        }

        @Test func aTierTakesThePressOnAnyOfItsParts() throws {  // C-3: no label steals the click
            let box = Box()
            defer { box.remove() }
            let tier = try #require(box.body.tierButtons["beans"])
            box.layout()
            for label in [tier.amountLabel, tier.nameLabel, tier.flavorLabel] {
                let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: tier.superview)
                #expect(tier.hitTest(point) === tier, "\(label.stringValue)")
            }
            #expect(tier.hitTest(NSPoint(x: -5, y: -5)) == nil)
        }

        @Test func tiersShowTheHoverWashAndAnAccentBorder() throws {  // C-4
            let box = Box()
            defer { box.remove() }
            let tier = try #require(box.body.tierButtons["coffee"])
            box.layout()
            func pixel(_ hovered: Bool) throws -> (border: NSColor, fill: NSColor) {
                tier.setHovered(hovered)
                let rep = try #require(tier.bitmapImageRepForCachingDisplay(in: tier.bounds))
                tier.cacheDisplay(in: tier.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / tier.bounds.width
                let y = Int(tier.bounds.midY * scale)
                func color(_ x: CGFloat) throws -> NSColor { try #require(rep.colorAt(x: Int(x * scale), y: y)).usingColorSpace(.sRGB)! }
                return (try color(0.5), try color(tier.bounds.width / 2))
            }
            let rest = try pixel(false)
            let hover = try pixel(true)
            #expect(tier.isHovered)
            #expect(hover.border != rest.border, "the border changes")
            #expect(tier.borderColor == NSColor.controlAccentColor, "and is the accent")
            #expect(tier.washColor == NSColor.labelColor.withAlphaComponent(0.06), "over the 6% wash")
            #expect(hover.fill != rest.fill, "the background takes the wash")
            tier.setHovered(false)
            #expect(!tier.isHovered)
            #expect(tier.borderColor == NSColor.separatorColor && tier.washColor == .clear, "and back")
        }

        @Test func everyTiersNameStartsAtTheSameX() throws {  // C-5
            let box = Box()
            defer { box.remove() }
            let starts = try Donations.tiers.map { tier -> CGFloat in
                let button = try #require(box.body.tierButtons[tier.id])
                #expect(button.amountLabel.frame.width >= 86, "\(tier.id): the amount column is at least 86pt")
                return box.frame(button.nameLabel).minX - box.frame(button).minX
            }
            #expect(Set(starts).count == 1, "\(starts)")
        }

        // MARK: Crypto (D-1…D-9)

        @Test func showsEveryAddressInFullWithItsLabelAndTicker() throws {  // D-1, D-2
            let box = Box()
            defer { box.remove() }
            let texts = box.body.texts
            #expect(texts.contains("Or in crypto"))
            #expect(texts.contains("Same idea, no card involved. Copy an address and send whatever you like."))
            for entry in Donations.addresses {
                let label = try #require(box.body.addressLabels[entry.id])
                #expect(label.stringValue == entry.address, "in full, not truncated")
                #expect(label.lineBreakMode == .byCharWrapping, "wrapped at any character")
                #expect(label.font?.isFixedPitch == true, "in the mono font")
                #expect(texts.contains("\(entry.label) \(entry.symbol)"))
                box.scroll(to: label)
                #expect(label.frame.height > label.font!.pointSize, "laid out with real height")
                #expect(label.frame.width <= AboutMetrics.contentWidth - 58 - 10 + 0.5, "the text column leaves room for the button")
            }
        }

        @Test func copyPutsTheAddressOnThePasteboardAndOnlyThat() throws {  // D-3
            let box = Box()
            defer { box.remove() }
            for entry in Donations.addresses {
                let button = try #require(box.body.copyButton(entry.id))
                box.scroll(to: button)
                try box.click(button)
            }
            #expect(box.copiedTexts == Donations.addresses.map(\.address))
        }

        @Test func aPressedButtonSaysCopiedForAMomentAndOnlyThatOne() async throws {  // D-4
            let box = Box()
            defer { box.remove() }
            let first = try #require(box.body.copyButton("btc"))
            let second = try #require(box.body.copyButton("eth"))
            box.scroll(to: first)
            try box.click(first)
            #expect(first.title == "Copied")
            #expect(second.title == "Copy", "each button owns its own confirmation")
            await box.timersStarted(1)
            box.gate.release(0)
            await box.settle { first.title == "Copy" }
            #expect(first.title == "Copy", "back to Copy when the timer ends")
            #expect(AboutModel.confirmation == .milliseconds(1500))
        }

        @Test func closingTheWindowLeavesNoTimerBehind() async throws {  // D-6
            let box = Box()
            box.model.copy(Donations.addresses[0])
            #expect(box.model.copied == ["btc"])
            await box.timersStarted(1)
            box.window.close()
            #expect(box.model.copied.isEmpty, "the confirmation is cleared with the window")
            box.gate.release(0)
            try await Task.sleep(for: .milliseconds(50))
            #expect(box.model.copied.isEmpty, "a timer that fires later touches nothing")
        }

        @Test func theCopyButtonKeepsItsWidthWhenItSaysCopied() throws {  // D-7
            let box = Box()
            defer { box.remove() }
            let button = try #require(box.body.copyButton("btc"))
            box.scroll(to: button)
            box.layout()
            let before = button.frame.width
            #expect(before >= 58)
            box.model.copy(Donations.addresses[0])
            box.layout()
            #expect(button.title == "Copied")
            #expect(button.frame.width == before, "the address column does not shift mid-interaction")
        }

        // MARK: Credits (E-1…E-6)

        @Test func creditsEveryPackageWithItsLicense() throws {  // E-1, E-3
            let box = Box()
            defer { box.remove() }
            let texts = box.body.texts
            #expect(texts.contains("Built with"))
            #expect(texts.contains("Tabs would not be possible without these projects."))
            #expect(!box.model.credits.isEmpty)
            for entry in box.model.credits {
                let name = try #require(box.body.creditButtons[entry.name], Comment(rawValue: entry.name))
                #expect(name.title == entry.name)
                let license = try #require(InputSynthesizer.find("about-credit-license-\(entry.name)", in: box.window) as? NSTextField)
                #expect(
                    license.stringValue == entry.license, "a license beside each: an uncredited one is the failure this window prevents")
            }
        }

        @Test func aBuildThatLinksNothingHasNoCreditsSection() throws {  // E-3
            let box = Box(credits: [])
            defer { box.remove() }
            #expect(box.body.sections["about-attributions"] == nil)
            #expect(!box.body.texts.contains("Built with"))
        }

        @Test func pressingACreditOpensItsURLInTheBrowserNotInTheWindow() throws {  // E-4
            let box = Box()
            defer { box.remove() }
            let entry = try #require(box.model.credits.first)
            let name = try #require(box.body.creditButtons[entry.name])
            box.scroll(to: name)
            try box.click(name)
            #expect(box.openedURLs.map(\.absoluteString) == [entry.url])
        }

        @Test func aCreditNameUnderlinesWhileHoveredAndIsAccentColored() throws {  // E-4
            let box = Box()
            defer { box.remove() }
            let entry = try #require(box.model.credits.first)
            let name = try #require(box.body.creditButtons[entry.name])
            func attributes() -> [NSAttributedString.Key: Any] { name.attributedTitle.attributes(at: 0, effectiveRange: nil) }
            #expect(attributes()[.underlineStyle] == nil)
            #expect(attributes()[.foregroundColor] as? NSColor == .controlAccentColor)
            name.setHovered(true)
            #expect(attributes()[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
            name.setHovered(false)
            #expect(attributes()[.underlineStyle] == nil)
        }

        @Test func theLicenseLinesUpAtTheRightEdge() throws {  // E-5
            let box = Box()
            defer { box.remove() }
            for entry in box.model.credits {
                let license = try #require(InputSynthesizer.find("about-credit-license-\(entry.name)", in: box.window))
                let row = try #require(InputSynthesizer.find("about-credit-row-\(entry.name)", in: box.window))
                // A label's frame overhangs its alignment rect by the 2pt its cell pads the text with: the text's
                // own edge, which is the alignment rect's, is what lines up.
                let overhang = license.frame.maxX - license.alignmentRect(forFrame: license.frame).maxX
                #expect(abs(box.frame(license).maxX - overhang - box.frame(row).maxX) < 0.5, "\(entry.name)")
                #expect(box.frame(row).maxX <= 460 - 28 + 0.5)
            }
        }

        // MARK: Look

        @Test func rendersInBothAppearancesWithoutClipping() throws {  // the look, checked by eye from the PNGs
            let box = Box()
            defer { box.remove() }
            box.layout()
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                box.window.appearance = NSAppearance(named: appearance)
                let document = box.document
                box.body.scrollView.frame.size = NSSize(width: 460, height: document.frame.height)  // the whole page, for the picture
                box.layout()
                let rep = try #require(document.bitmapImageRepForCachingDisplay(in: document.bounds))
                // The window's background under this appearance (the window paints it, not the page), then the page.
                box.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    box.window.backgroundColor.setFill()
                    document.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    document.cacheDisplay(in: document.bounds, to: rep)
                }
                var seen = Set<UInt32>()
                for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let (r, g, b) = (UInt32(c.redComponent * 255), UInt32(c.greenComponent * 255), UInt32(c.blueComponent * 255))
                        seen.insert(r << 16 | g << 8 | b)
                    }
                }
                #expect(seen.count > 8, "\(name) rendered blank")
                if let directory = ProcessInfo.processInfo.environment["TABS_SNAPSHOT_DIR"] {
                    let file = URL(filePath: directory).appending(path: "about-\(name).png")
                    try rep.representation(using: .png, properties: [:])?.write(to: file)
                }
            }
        }
    }
}

/// The About window's behaviour without the window (`AboutModel`, docs/ABOUT.md): what reaches
/// the OS, and which addresses say "Copied", over a recording opener and pasteboard and a
/// hand-released clock.
@MainActor
@Suite struct AboutModelTests {
    @MainActor private final class Recorder {
        var opened: [URL] = []
        var copied: [String] = []
    }

    private let recorder = Recorder()
    private let gate = UITests.SleepGate()
    private let model: AboutModel

    init() {
        let (recorder, gate) = (recorder, gate)
        model = AboutModel(
            version: "9.8.7", credits: [], opener: { recorder.opened.append($0) }, pasteboard: { recorder.copied.append($0) },
            sleep: { try await gate.sleep($0) })
    }

    /// Waits until `check` holds, for up to 5 s: a deadline, not a count of polls.
    private func settle(_ check: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !check(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Waits until `count` timers have started: a press starts its timer in a task of its own.
    private func timersStarted(_ count: Int) async { await settle { gate.pending >= count } }

    @Test func theRealModelReadsTheBundlesVersion() {  // B-3
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(expected != nil)
        #expect(AboutModel.runningVersion == expected)
    }

    @Test func eachButtonKeepsItsOwnTimer() async throws {  // D-4: two can say Copied at once
        model.copy(Donations.addresses[0])
        // Each timer sleeps off the main actor: let the first start before the second, so the
        // first sleep the gate holds is btc's.
        await timersStarted(1)
        model.copy(Donations.addresses[1])
        #expect(model.copied == ["btc", "eth"])
        #expect(recorder.copied == Donations.addresses.prefix(2).map(\.address))
        await timersStarted(2)
        gate.release(0)
        await settle { model.copied == ["eth"] }
        #expect(model.copied == ["eth"])
    }

    @Test func pressingAgainRestartsTheConfirmation() async throws {  // D-5
        let entry = Donations.addresses[0]
        model.copy(entry)
        await timersStarted(1)
        model.copy(entry)
        await timersStarted(2)
        #expect(gate.pending == 2)
        gate.release(0)  // the first press's timer ends: it must not end the second press's confirmation
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.copied == [entry.id], "still confirmed: the second press restarted the timer")
        gate.release(0)
        await settle { model.copied.isEmpty }
        #expect(model.copied.isEmpty)
    }

    @Test func opensNothingThatIsNotAWebOrMailLink() {  // X-1
        let refused = ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:x", "relative/path", ""]
        for url in refused { model.open(url) }
        #expect(recorder.opened.isEmpty)
        model.open("https://example.com/ok")
        #expect(recorder.opened.map(\.absoluteString) == ["https://example.com/ok"])
    }
}
