import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The pane's header chrome and what it says about itself (docs/BROWSER.md: B-1,
/// B-5, B-9…B-11, C-7, C-8, L-1…L-4, L-7, L-8), against the real controller in a
/// real core runtime, without the app.
@MainActor
@Suite struct BrowserPaneTests {
    let harness: PluginHarness

    init() throws {
        _ = NSApplication.shared
        harness = try PluginHarness { BrowserPlugin() }
    }

    /// A pane with its header chrome built and laid out at `width`, as core lays the header's title slot out.
    private func opened(_ config: JSONValue? = nil, width: Double = 500) throws -> (BrowserPane, BrowserToolbar) {
        let pane = try #require(harness.open("browser", config: config))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        let toolbar = try #require(browser.headerTitle as? BrowserToolbar)
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: 24)
        toolbar.layoutSubtreeIfNeeded()
        return (browser, toolbar)
    }

    // MARK: Geometry (L-1…L-4)

    /// L-1, L-2: the header's flex row: three 23 × 17 buttons and the bar filling the rest, 8 apart, each centered in the 24-tall bar.
    @Test func laysOutAsTheHeadersFlexRowDoes() throws {
        let (_, toolbar) = try opened()
        let layout = toolbar.computeLayout(width: 500)
        #expect(layout.back == CGRect(x: 0, y: 3.5, width: 23, height: 17))
        #expect(layout.forward == CGRect(x: 31, y: 3.5, width: 23, height: 17))
        #expect(layout.refresh == CGRect(x: 62, y: 3.5, width: 23, height: 17))
        #expect(layout.bar == CGRect(x: 93, y: 2, width: 407, height: 20))
        #expect(toolbar.back.frame == snapped(layout.back), "painted on whole points, as Chromium snaps a box")
        #expect(toolbar.bar.frame == snapped(layout.bar))
        // Told where the slot really is, the boxes carry the header's fractional position.
        toolbar.paneHeaderSlotDidChange(PaneHeaderSlot(barContentWidth: 620, fractionalOffset: CGPoint(x: 0.25, y: -0.25)))
        let shifted = toolbar.computeLayout(width: 500)
        #expect(shifted.back.origin == CGPoint(x: 0.25, y: 3.25) && shifted.bar.origin == CGPoint(x: 93.25, y: 1.75))
        #expect(shifted.bar.width == 407)
        // Never negative, however narrow the slot.
        #expect(toolbar.computeLayout(width: 40).bar.width == 0)
    }

    /// L-3: the segment is its text and its padding and border wide, up to 30% of the bar's content; the input has the rest.
    @Test func theTitleSegmentIsSnugUntilItHitsThirtyPercent() throws {
        let (browser, toolbar) = try opened()
        toolbar.bar.title = ""
        #expect(toolbar.bar.computeLayout().segment == nil)
        #expect(toolbar.bar.computeLayout().input == toolbar.bar.computeLayout().content)
        toolbar.bar.title = "Hi"
        var layout = toolbar.bar.computeLayout()
        let snug = BrowserText.ui12.width("Hi") + 6 + 6 + 1
        #expect(layout.segment == CGRect(x: 1, y: 1, width: snug, height: 18), "snug: padding 0 6 and a 1pt border-right")
        #expect(layout.input == CGRect(x: 1 + snug, y: 1, width: layout.content.width - snug, height: 18))
        toolbar.bar.title = String(repeating: "Long title ", count: 20)
        layout = toolbar.bar.computeLayout()
        #expect(abs((layout.segment?.width ?? 0) - 0.3 * layout.content.width) < 0.001)
        _ = browser
    }

    /// L-4: 12px text in the input, its line centered in the 14pt content box; the baseline is a whole point.
    @Test func theInputsTextSitsWhereChromiumPutsAnInputsLine() throws {
        let font = BrowserText.ui12
        let origin = AddressBar.inputTextOrigin(in: CGRect(x: 10, y: 1, width: 200, height: 18))
        #expect(origin.x == 16)
        #expect(abs(Double(origin.y) - (1 + 2 + (14 - font.lineHeight) / 2 + font.ascent)) < 1e-9)
    }

    // MARK: Painting (L-1…L-4, L-7)

    private func paint(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 0).setFill()
        view.bounds.fill(using: .copy)
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ point: CGPoint, scale: Double) -> NSColor {
        (rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)) ?? .clear).usingColorSpace(.sRGB) ?? .clear
    }

    /// The color a fill of `color` reads back as through the same offscreen pipeline.
    private func reference(_ color: NSColor) throws -> NSColor {
        let view = BrowserFlippedView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        view.bounds.fill(using: .copy)
        NSGraphicsContext.restoreGraphicsState()
        return (rep.colorAt(x: 2, y: 2) ?? .clear).usingColorSpace(.sRGB) ?? .clear
    }

    private func near(_ a: NSColor, _ b: NSColor, _ tolerance: CGFloat = 0.02) -> Bool {
        abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// L-3, L-4, L-7: the input on `--bg`, the segment on `--bg-elevated`, its border-right and the bar's border on `--border`; both themes.
    @Test func paintsTheBarInTheThemesColorsInBothThemes() throws {
        for theme in [PaneTheme.dark, PaneTheme.light] {
            let (browser, toolbar) = try opened()
            browser.paneAppearanceDidChange(theme: theme, depth: 0)
            toolbar.bar.title = "Title"
            toolbar.layoutSubtreeIfNeeded()
            let rep = try paint(toolbar)
            let scale = Double(rep.pixelsWide) / toolbar.bounds.width
            let bar = toolbar.bar.frame
            let layout = toolbar.bar.computeLayout()
            let segment = try #require(layout.segment)
            let inSegment = pixel(rep, CGPoint(x: bar.minX + segment.minX + 1.5, y: bar.minY + 16), scale: scale)
            let inInput = pixel(rep, CGPoint(x: bar.maxX - 10, y: bar.minY + 16), scale: scale)
            let onBorder = pixel(rep, CGPoint(x: bar.midX, y: bar.minY + 0.5), scale: scale)
            let rule = pixel(rep, CGPoint(x: bar.minX + segment.maxX - 0.5, y: bar.minY + 16), scale: scale)
            #expect(near(inSegment, try reference(theme.bgElevated)), "\(theme.isDark ? "dark" : "light") segment \(inSegment)")
            #expect(near(inInput, try reference(theme.bg)), "input \(inInput)")
            #expect(near(onBorder, try reference(theme.border)), "border \(onBorder)")
            #expect(near(rule, try reference(theme.border)), "the segment's border-right \(rule)")
            #expect(!near(inSegment, inInput), "two shades")
        }
    }

    /// L-2: the corners are rounded (the box is clipped to its 3pt radius): the corner pixel isn't the bar's fill.
    @Test func theBarsCornersAreRounded() throws {
        let (_, toolbar) = try opened()
        let rep = try paint(toolbar)
        let scale = Double(rep.pixelsWide) / toolbar.bounds.width
        let corner = pixel(rep, CGPoint(x: toolbar.bar.frame.minX + 0.2, y: toolbar.bar.frame.minY + 0.2), scale: scale)
        #expect(corner.alphaComponent < 0.5, "outside the rounded box nothing is painted: \(corner)")
    }

    /// L-1: the hover wash is `--hover` at 12%; a disabled button is dimmed to 35% and takes no hover.
    @Test func aButtonWashesOnHoverAndDimsWhenDisabled() throws {
        let (browser, toolbar) = try opened()
        let button = toolbar.refresh
        // The wash is drawn under the button's own bounds: sample its corner interior, clear of the icon.
        func fill() throws -> NSColor {
            let rep = try paint(button)
            let scale = Double(rep.pixelsWide) / button.bounds.width
            return pixel(rep, CGPoint(x: 2, y: 8), scale: scale)
        }
        #expect(try fill().alphaComponent < 0.01, "at rest nothing is drawn behind the icon")
        let event = NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
        button.mouseEntered(with: event)
        let washed = try fill()
        #expect(abs(washed.alphaComponent - 0.12) < 0.03, "\(washed)")
        #expect(washed.redComponent > 0.9, "white on the dark theme")
        button.mouseExited(with: event)
        #expect(try fill().alphaComponent < 0.01)
        // Light theme: black wash.
        browser.paneAppearanceDidChange(theme: .light, depth: 0)
        button.mouseEntered(with: event)
        #expect(try fill().redComponent < 0.1, "black on the light theme")
        button.mouseExited(with: event)
        // Disabled: no hover at all, the icon at 35%.
        toolbar.back.isEnabled = false
        toolbar.back.mouseEntered(with: event)
        #expect(!toolbar.back.hovered)
        let dimmed = try paint(toolbar.back)
        let enabled = try paint(toolbar.refresh)
        func inkAlpha(_ rep: NSBitmapImageRep) -> CGFloat {
            var strongest: CGFloat = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide { strongest = max(strongest, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
            }
            return strongest
        }
        #expect(abs(inkAlpha(dimmed) / inkAlpha(enabled) - 0.35) < 0.08, "\(inkAlpha(dimmed)) of \(inkAlpha(enabled))")
    }

    /// L-1, L-8: each nav glyph draws inside its 13 × 13 box, and the globe fills its 16 × 16 template.
    @Test func theGlyphsDrawInsideTheirBoxes() throws {
        let (_, toolbar) = try opened()
        for button in [toolbar.back, toolbar.forward, toolbar.refresh] {
            let rep = try paint(button)
            let scale = Double(rep.pixelsWide) / button.bounds.width
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            #expect(maxX > 0, "\(button.label) drew nothing")
            #expect(Double(minX) / scale >= 5 - 0.5 && Double(maxX + 1) / scale <= 5 + 13 + 0.5, "\(button.label) x \(minX)…\(maxX)")
            #expect(Double(minY) / scale >= 2 - 0.5 && Double(maxY + 1) / scale <= 2 + 13 + 0.5, "\(button.label) y \(minY)…\(maxY)")
        }
        let globe = BrowserGlyphs.browser
        #expect(globe.isTemplate && globe.size == NSSize(width: 16, height: 16))
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        globe.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        var ink = 0
        for y in 0..<32 { for x in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { ink += 1 } }
        #expect(ink > 60, "the globe has ink: \(ink)")
        // The four corners of the box are empty: it's a circle.
        #expect((rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.05)
    }

    // MARK: Behavior (B-5, B-11)

    @Test func aButtonPressesOnMouseUpInsideAndNeverWhenDisabledOrReleasedOutside() throws {
        let (_, toolbar) = try opened()
        let button = toolbar.refresh
        var presses = 0
        button.onPress = { presses += 1 }
        func up(at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: button.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        button.mouseUp(with: up(at: CGPoint(x: 5, y: 5)))
        #expect(presses == 1)
        button.mouseUp(with: up(at: CGPoint(x: 500, y: 500)))
        #expect(presses == 1, "released outside")
        #expect(button.accessibilityPerformPress() && presses == 2)
        button.isEnabled = false
        button.mouseUp(with: up(at: CGPoint(x: 5, y: 5)))
        #expect(!button.accessibilityPerformPress() && presses == 2)
        #expect(button.toolTip == "Refresh" && button.accessibilityLabel() == "Refresh", "a disabled button keeps its name")
        #expect(button.mouseDownCanMoveWindow == false)
    }

    /// B-2: the buttons follow the page's history.
    @Test func theButtonsFollowThePagesHistory() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/a", title: "A")
        server.page("/b", title: "B")
        let (browser, toolbar) = try opened()
        #expect(!toolbar.back.isEnabled && !toolbar.forward.isEnabled)
        browser.page.load(server.url("/a"))
        #expect(await eventually { browser.page.title == "A" })
        browser.page.load(server.url("/b"))
        #expect(await eventually { toolbar.back.isEnabled })
        #expect(!toolbar.forward.isEnabled)
        toolbar.back.onPress?()
        #expect(await eventually { toolbar.forward.isEnabled && !toolbar.back.isEnabled })
    }

    /// B-7: what Return resolves: a URL loads, a search is a search, blank is nothing.
    @Test func returnInTheAddressBarNavigatesToWhatItResolvesTo() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/typed", title: "Typed")
        let (browser, toolbar) = try opened()
        toolbar.bar.field.stringValue = server.url("/typed")
        let handled = toolbar.bar.control(toolbar.bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(handled)
        #expect(await eventually { browser.page.title == "Typed" })
        let before = server.requests.count
        toolbar.bar.field.stringValue = "   "
        _ = toolbar.bar.control(toolbar.bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requests.count == before && browser.page.url == server.url("/typed"), "blank does nothing")
        #expect(
            !toolbar.bar.control(toolbar.bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))),
            "other commands are the field's")
    }

    /// The header follows the page's title and URL, and typing over the bar is never replaced.
    @Test func theBarFollowsThePageButNeverTypedText() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/a", title: "Page A")
        server.page("/b", title: "Page B")
        let (browser, toolbar) = try opened()
        browser.page.load(server.url("/a"))
        #expect(await eventually { toolbar.bar.title == "Page A" && toolbar.bar.address == server.url("/a") })
        #expect(toolbar.bar.field.stringValue == server.url("/a"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = toolbar
        window.makeFirstResponder(toolbar.bar.field)
        #expect(toolbar.isEditingAddress)
        toolbar.bar.field.currentEditor()?.string = "typing"
        toolbar.bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        browser.page.load(server.url("/b"))
        #expect(await eventually { toolbar.bar.title == "Page B" }, "the segment still follows")
        #expect(toolbar.bar.address == "typing", "the text being typed stays")
    }

    // MARK: What the pane says about itself (C-7, C-8)

    /// C-8: `list-panes`' url comes from config, so it works while unmounted.
    @Test func listSummaryReadsTheConfigNotThePage() throws {
        let pane = try #require(harness.open("browser", config: ["url": "https://example.invalid/somewhere"]))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        #expect(browser.listSummaryFields() == ["url": "https://example.invalid/somewhere"])
    }

    /// C-7: `pane-info`'s fields; the viewport is the page's own or the pane is `hidden`, never an invented one.
    @Test func paneInfoReportsTheLiveFieldsAndRefusesToInventAViewport() async throws {
        let server = try await FixtureServer.start()
        defer { server.stop() }
        server.page("/a", title: "Page A")
        let pane = try #require(harness.open("browser"))
        let browser = try #require(harness.controller(of: pane.id, as: BrowserPane.self))
        browser.page.load(server.url("/a"))
        #expect(await browser.page.waitForLoadEnd(timeoutMs: 10_000).loaded)
        #expect(await eventually { browser.page.title == "Page A" })
        var info = await browser.paneInfoFields()
        #expect(info["url"] == .string(server.url("/a")) && info["title"] == "Page A")
        #expect(info["isLoading"] == false && info["canGoBack"] == false && info["canGoForward"] == false)
        #expect(info["pageInstance"] == .string(String(browser.page.pageInstance)))
        #expect(info["hidden"] == true && info["viewport"] == nil, "not in a window: hidden, no viewport")
        #expect(info["showingErrorPage"] == nil && info["loadError"] == nil)
        // Shown: the page's own viewport.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = browser.view
        info = await browser.paneInfoFields()
        #expect(info["viewport"]?["width"]?.doubleValue == 400 && info["viewport"]?["height"]?.doubleValue == 300 && info["hidden"] == nil)
        // On an error page: flagged, with the code.
        let dead = try await FixtureServer.closedPort()
        browser.page.load("http://127.0.0.1:\(dead)/")
        #expect(await eventually { browser.page.isShowingErrorPage })
        info = await browser.paneInfoFields()
        #expect(info["showingErrorPage"] == true && info["loadError"] == "ERR_CONNECTION_REFUSED")
        #expect(info["canGoBack"] == true)
    }
}
