import Foundation
import TabsPluginSDK

/// The Read verbs: `screenshot`, `get-page-text`, `read-page` and `find`. The handlers are in
/// `ReadCapture` and `ReadPage`; this is what each verb declares.
@MainActor
enum ReadVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] {
        [screenshot(services), getPageText(), readPage(), find()]
    }

    /// Reads and input that may first reveal, scroll or settle the page: the waits under this
    /// (`screenshot`'s reveal wait) stay far below it so their bounded failures reach the
    /// caller instead of a deadline.
    private static let readBudget: Duration = .seconds(15)

    private static let rect: JSONValue = ["x": "number", "y": "number", "width": "number", "height": "number"]
    private static let element: JSONValue = ["role": "string", "name": "string", "tag": "string"]

    /// The readiness fields every read carries.
    private static let pageState: [String: JSONValue] = [
        "isLoading": "boolean", "readyState": "string", "settled": "boolean", "frames": "number", "shadowRoots": "number",
    ]

    private static func shape(_ own: [String: JSONValue]) -> JSONValue {
        .object(own.merging(pageState) { own, _ in own })
    }

    private static func screenshot(_ services: BrowserServices) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.screenshot",
            summary:
                "Capture the pane, bringing it to the front first if it’s backgrounded (reported as activated: true). Returns a PNG path to read, never inline image data.",
            arguments: [
                ControlArgument(
                    "noActivate", .bool, summary: "Fail on a backgrounded pane instead of bringing it to the front."),
                ControlArgument(
                    "selector", .string,
                    summary:
                        "Clip the capture to this element instead of the whole viewport. Scrolled into view first; clamped to what the guest is showing.",
                    placeholder: "css"),
                ControlArgument("ref", .string, summary: "Clip to a read-page/find ref, like --selector."),
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: readBudget, command: "screenshot", wireType: "screenshot",
            resultShape: [
                "path": "string", "width": "number", "height": "number", "viewport": ["width": "number", "height": "number"],
                "scaleFactor": "number", "clipped": rect, "element": element, "activated": "boolean",
            ]
        ) { [unowned services] invocation in
            try await ReadCapture.screenshot(invocation, services: services)
        }
    }

    private static func getPageText() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.getPageText", summary: "Rendered page text (innerText — no script or style bodies).",
            arguments: [
                ControlArgument(
                    "maxLength", .number,
                    summary: "Default \(BrowserLimits.defaultPageTextMax), capped at \(BrowserLimits.pageTextHardMax).", minimum: 1)
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: readBudget, command: "get-page-text", wireType: "getPageText",
            resultShape: shape(["text": "string", "truncated": "boolean"])
        ) { invocation in
            try await ReadPage.getPageText(invocation)
        }
    }

    private static func readPage() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.readPage",
            summary:
                "Interactive elements and headings, each with a ref for click/type. Capped at 200 per call — narrow with --selector/--role or page with --offset.",
            arguments: [
                ControlArgument(
                    "selector", .string,
                    summary:
                        "Extract this selector's matches instead of the default interactive set — the way to reach elements it never lists, images (img[alt]) especially.",
                    placeholder: "css"),
                ControlArgument(
                    "role", .string,
                    summary:
                        "Only elements with this role (button, link, textbox, combobox, checkbox, heading, …). A hard filter: it never widens on its own."
                ),
                ControlArgument(
                    "offset", .number,
                    summary: "Skip this many matches before the page returned. Use with total/truncated to walk a long page.",
                    minimum: 0),
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: readBudget, command: "read-page", wireType: "readPage",
            resultShape: shape([
                "elements": [
                    [
                        "ref": "string", "role": "string", "name": "string", "tag": "string", "rect": rect, "value": "string",
                        "checked": "boolean | \"mixed\"",
                    ]
                ],
                "total": "number", "offset": "number", "truncated": "boolean",
            ])
        ) { invocation in
            try await ReadPage.readPage(invocation)
        }
    }

    private static func find() -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.find", summary: "Best-effort search over read-page’s elements. Heuristic, not semantic.",
            arguments: [
                ControlArgument("description", .string, required: true, placeholder: "text"),
                ControlArgument("maxResults", .number, minimum: 1),
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: readBudget, command: "find", wireType: "find",
            resultShape: shape([
                "matches": [["ref": "string", "name": "string", "role": "string", "tag": "string", "rect": rect, "score": "number"]]
            ])
        ) { invocation in
            try await ReadPage.find(invocation)
        }
    }
}
