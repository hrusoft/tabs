import AppKit
import Foundation
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The page's viewport and pixels (docs/BROWSER.md C-7, J-6): read from the page, never invented.
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
        #expect(
            viewport.scaleFactor == NSScreen.main.map { Double($0.backingScaleFactor) },
            "the display's scale, a window nobody sees included")
        #expect(await bed.value("window.devicePixelRatio").doubleValue == viewport.scaleFactor)
    }

    @Test func aFractionalWidthReportsTheExactViewportTheCoordinatesLiveIn() async throws {
        let bed = try await redPage()
        bed.window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        bed.window.contentView?.addSubview(bed.page.webView)
        bed.page.webView.frame = NSRect(x: 0, y: 0, width: 345.4, height: 300)
        bed.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let viewport = try #require(await bed.page.viewport())
        #expect(
            viewport.width == (await bed.value("window.innerWidth").doubleValue ?? -1), "what the page says, not a rounding of the view's")
        #expect(viewport.width >= 345 && viewport.width <= 346)
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
}
