import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The page's viewport and pixels (docs/BROWSER.md C-7, J-6): read from the page, never invented; and `screenshot`'s
/// clip, on an agent's pane in a window that is never shown. A reveal is the UI tier's (`BrowserControlUITests`).
@MainActor
@Suite struct BrowserSnapshotTests {
    private func redPage() async throws -> PageBed {
        let bed = try await PageBed(serving: { server in
            server.page(
                "/red", title: "Red",
                head:
                    "<style>body{margin:0;background:#ff0000}#blue{position:absolute;left:100px;top:100px;width:100px;height:50px;background:#0000ff}</style>",
                body: "<div id=blue></div>")
        })
        await bed.load("/red")
        return bed
    }

    private func pixel(_ png: Data, x: Int, y: Int) -> [Int]? {
        guard let bitmap = NSBitmapImageRep(data: png), let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return [
            Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
        ]
    }

    /// C-7: the viewport is the page's own `innerWidth × innerHeight`, and the scale is its `devicePixelRatio`.
    @Test func theViewportIsThePagesOwn() async throws {
        let bed = try await redPage()
        let viewport = try #require(await bed.page.viewport())
        #expect(viewport.width == 400 && viewport.height == 300)
        // The scale of the page's own window (its display's, a window nobody sees included), not the main
        // screen's: with displays of two scales attached they differ.
        #expect(viewport.scaleFactor == Double(bed.window.backingScaleFactor), "the page's window's scale")
        #expect(await bed.value("window.devicePixelRatio").doubleValue == viewport.scaleFactor)
    }

    @Test func aFractionalWidthReportsTheExactViewportTheCoordinatesLiveIn() async throws {
        let bed = try await redPage()
        bed.window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        bed.window.contentView?.addSubview(bed.page.webView)
        bed.page.webView.frame = NSRect(x: 0, y: 0, width: 345.4, height: 300)
        bed.window.contentView?.layoutSubtreeIfNeeded()
        // The page hears of its new width a moment later: once it reports one under 400.
        #expect(await eventuallyAsync { (await bed.value("window.innerWidth").doubleValue ?? 400) < 400 })
        let viewport = try #require(await bed.page.viewport())
        #expect(
            viewport.width == (await bed.value("window.innerWidth").doubleValue ?? -1), "what the page says, not a rounding of the view's")
        #expect(viewport.width >= 345 && viewport.width <= 346)
        #expect(
            viewport.scaleFactor == (await bed.value("window.devicePixelRatio").doubleValue ?? -1),
            "the display's real ratio, not the image over a rounded width")
    }

    /// J-6: a snapshot is a PNG of the page's pixels, at the window's scale.
    @Test func aSnapshotIsAPNGOfThePagesPixelsAtTheWindowsScale() async throws {
        let bed = try await redPage()
        let scale = Int(try #require(await bed.page.viewport()).scaleFactor)
        let snapshot = try #require(await bed.page.snapshot())
        #expect(snapshot.pixelWidth == 400 * scale && snapshot.pixelHeight == 300 * scale)
        #expect(snapshot.png.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "a PNG")
        let red = try #require(pixel(snapshot.png, x: 10 * scale, y: 10 * scale))
        #expect(red[0] > 230 && red[1] < 60 && red[2] < 30, "red: \(red)")
        let blue = try #require(pixel(snapshot.png, x: 150 * scale, y: 120 * scale))
        #expect(blue[2] > 230 && blue[0] < 30 && blue[1] < 80, "blue: \(blue)")
    }

    /// J-6: a clip is in CSS pixels and comes back at device scale.
    @Test func aClipIsInCSSPixelsAndComesBackAtDeviceScale() async throws {
        let bed = try await redPage()
        let scale = Int(try #require(await bed.page.viewport()).scaleFactor)
        let clip = try #require(await bed.page.snapshot(rect: CGRect(x: 100, y: 100, width: 100, height: 50)))
        #expect(clip.pixelWidth == 100 * scale && clip.pixelHeight == 50 * scale)
        let corner = try #require(pixel(clip.png, x: 5, y: 5))
        #expect(corner[2] > 230 && corner[0] < 30, "the blue box, exactly: \(corner)")
    }

    /// C-7: a pane that isn't shown reports no viewport and can't be captured.
    @Test func aPageThatIsNotOnScreenHasNoViewportAndNoSnapshot() async throws {
        let bed = try await PageBed(mounted: false)
        #expect(await bed.page.viewport() == nil)
        #expect(await bed.page.snapshot() == nil)
        let hidden = try await redPage()
        hidden.page.webView.isHidden = true
        #expect(!hidden.page.isVisible)
        #expect(await hidden.page.viewport() == nil, "never an invented viewport")
    }

    // MARK: The verb

    private func png(_ path: String) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: URL(filePath: path))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), "a PNG on disk")
        return try #require(NSBitmapImageRep(data: data))
    }

    /// J-6, J-10: `screenshot --selector | --ref` clips to one element: a real, smaller PNG whose rect is in CSS pixels at
    /// the unclipped capture's scale factor, rounded outward to whole pixels and clamped to the viewport, which still
    /// describes the pane. An element outside the viewport, one that isn't there, a stale ref and an ambiguous target are
    /// refused, each saying why.
    @Test func screenshotClipsToOneElementInCSSPixelsClampedToTheViewport() async throws {
        let bed = try await InputVerbBed()
        let full = await bed.ctl("screenshot")
        #expect(full.ok, "\(full.raw)")
        let clipped = await bed.ctl("screenshot", ["selector": "#go"])
        #expect(clipped.result["element"]?["name"] == "Do the thing", "\(clipped.raw)")
        let rect = try #require(clipped.result["clipped"], "a clipped screenshot reports its rect")

        // The clip is a real, much smaller PNG: not a full capture with a rect reported beside it.
        let image = try png(try #require(clipped.result["path"]?.stringValue))
        #expect(
            clipped.result["width"]?.intValue == Int64(image.pixelsWide) && clipped.result["height"]?.intValue == Int64(image.pixelsHigh))
        #expect((clipped.result["width"]?.intValue ?? .max) < (full.result["width"]?.intValue ?? 0))
        #expect((clipped.result["height"]?.intValue ?? .max) < (full.result["height"]?.intValue ?? 0))
        // The rect is CSS pixels and the image device pixels, at the scale factor the unclipped capture reports.
        let scale = try #require(full.result["scaleFactor"]?.doubleValue)
        #expect(clipped.result["scaleFactor"]?.doubleValue == scale)
        #expect(clipped.result["width"]?.doubleValue == (rect["width"]?.doubleValue ?? 0) * scale)
        #expect(clipped.result["height"]?.doubleValue == (rect["height"]?.doubleValue ?? 0) * scale)
        #expect(clipped.result["viewport"] == full.result["viewport"], "the pane's, not the clip's")
        let viewport = (width: full.result["viewport"]?["width"]?.doubleValue, height: full.result["viewport"]?["height"]?.doubleValue)
        #expect(viewport.width == 800 && viewport.height == 600, "\(full.raw)")
        // Rounded outward to whole CSS pixels.
        for key in ["x", "y", "width", "height"] { #expect(rect[key]?.intValue != nil, "\(key) is a whole number") }
        let box = await bed.value(
            "(() => { const r = document.getElementById('go').getBoundingClientRect(); return [r.x, r.y, r.width, r.height] })()")
        let measured: [Double] = if case .array(let numbers) = box { numbers.compactMap(\.doubleValue) } else { [] }
        try #require(measured.count == 4)
        let x = Double(rect["x"]?.intValue ?? 0), y = Double(rect["y"]?.intValue ?? 0)
        #expect(x <= measured[0] && x + (rect["width"]?.doubleValue ?? 0) >= measured[0] + measured[2])
        #expect(y <= measured[1] && y + (rect["height"]?.doubleValue ?? 0) >= measured[1] + measured[3])

        // A ref clips identically: the two forms name one element two ways.
        let ref = await bed.element(named: "Do the thing").ref
        #expect(await bed.ctl("screenshot", ["ref": .string(ref)]).result["clipped"] == rect)

        // What can't be captured says why.
        let missing = await bed.ctl("screenshot", ["selector": "#nope"])
        #expect(!missing.ok && missing.error?.contains("no element matches") == true, "\(missing.raw)")
        let stale = await bed.ctl("screenshot", ["ref": "e999-gone"])
        #expect(!stale.ok && stale.error == staleRefError("e999-gone"), "\(stale.raw)")
        let ambiguous = await bed.ctl("screenshot", ["selector": "button"])
        #expect(!ambiguous.ok && ambiguous.error?.contains("elements match") == true, "\(ambiguous.raw)")
        #expect(ambiguous.error?.contains("Do the thing") == true, "it lists the candidates")

        // Clamped to what the page shows: an element bigger than the viewport, starting above and left of it…
        await bed.value(
            """
            (document.body.insertAdjacentHTML('beforeend', `
              <div id=tall style="position:fixed;left:-20px;top:-30px;width:5000px;height:5000px"></div>
              <div id=far style="position:absolute;left:-200px;top:0;width:50px;height:50px"></div>`), 1)
            """)
        let clamped = await bed.ctl("screenshot", ["selector": "#tall"]).result["clipped"]
        let corner = [clamped?["x"], clamped?["y"], clamped?["width"], clamped?["height"]].map { $0?.doubleValue }
        #expect(corner == [0, 0, viewport.width, viewport.height], "the viewport's own corner and size: \(String(describing: clamped))")
        // …and one no scroll brings into it is refused.
        let outside = await bed.ctl("screenshot", ["selector": "#far"])
        #expect(!outside.ok && outside.error?.contains("is outside the visible viewport") == true, "\(outside.raw)")
    }
}
