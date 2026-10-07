import AppKit
import Foundation
import TabsPluginSDK

/// The HTTP answer behind a committed document: what the navigation response
/// reported for the main frame.
struct DocumentStatus: Equatable, Sendable {
    var status: Int
    var statusText: String
}

/// One captured console message. `level` is the name callers filter on:
/// `verbose`, `info`, `warning`, `error` (Chromium's four).
struct ConsoleEntry: Sequenced, Equatable, Sendable {
    var seq = 0
    var level: String
    var text: String
    /// Milliseconds since the epoch, when the message arrived.
    var timestamp: Double
    var sourceURL: String?
    var line: Int?
}

/// Why a script didn't produce a value.
enum PageScriptError: Error, Equatable, Sendable {
    /// The page can't run script now: mid-navigation, its process gone, a viewer
    /// that runs none.
    case unavailable
    /// The script's value has no JSON form (a DOM node, a cycle).
    case unsupportedResult
    /// The script threw; the engine's message.
    case exception(String)

    /// What a verb tells its caller: the engine's own plumbing text names
    /// nothing a caller can act on, so unavailability is one sentence.
    var message: String {
        switch self {
        case .unavailable, .unsupportedResult: pageScriptUnavailableMessage
        case .exception(let message): message
        }
    }
}

/// What a verb answers when the page can't run script at all.
let pageScriptUnavailableMessage =
    "the page could not run script — it may be mid-navigation, showing an error page, or a viewer (such as the PDF viewer) that runs none"

/// How a wait for a load to end ended. `loaded: false` with no error means the
/// page was still loading when the wait ran out (the caller's to keep polling,
/// not a failure); with `loadError` it means the load failed, and the `ERR_*`
/// name says why (`ERR_CONNECTION_REFUSED` against a dev server that isn't up
/// being the case agents actually hit).
struct LoadOutcome: Equatable, Sendable {
    var loaded: Bool
    var loadError: String?
    /// The URL that failed, when it isn't the one asked for: a navigation the page
    /// started itself, followed by `waitForLoadSettle`, is what failed.
    var failedURL: String?
}

/// How many of each input event the page's current document has seen
/// (`InputAcknowledgement`): what `PageInput.settle` compares against.
struct InputCounts: Equatable, Sendable {
    var mouseup = 0
    var keyup = 0
    var input = 0
    var mousemove = 0
}

/// The page's own coordinate space, and how many image pixels a CSS pixel of it is.
struct PageViewport: Equatable, Sendable {
    /// `innerWidth`/`innerHeight`: the CSS-pixel space `click --x/--y` and `read-page` rects live in.
    var width: Double
    var height: Double
    /// `devicePixelRatio`: image pixels per CSS pixel in a snapshot.
    var scaleFactor: Double
}

/// A capture of the page: PNG bytes and the pixel size of the image.
struct PageSnapshot: Equatable, Sendable {
    var png: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Reason phrases for the statuses pages actually answer with (WebKit exposes
/// only the code, not the server's own phrase).
enum HTTPStatusText {
    static func phrase(for status: Int) -> String {
        if let known = phrases[status] { return known }
        return HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }

    private static let phrases: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 300: "Multiple Choices", 301: "Moved Permanently", 302: "Found",
        303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
        401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone", 411: "Length Required",
        412: "Precondition Failed", 413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
        416: "Range Not Satisfiable", 418: "I'm a teapot", 422: "Unprocessable Entity", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported",
    ]
}

extension JSONValue {
    /// A value WebKit handed back from a script (`NSNumber`, `NSString`, `NSNull`,
    /// `NSArray`, `NSDictionary`, or nil for `undefined`) as JSON.
    init(webKitValue value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let integer = Int64(exactly: number.doubleValue), abs(number.doubleValue) < 9_007_199_254_740_992 {
                // JavaScript has one number type; an integral one is what JSON writes without a fraction.
                self = .int(integer)
            } else {
                self = .double(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(webKitValue: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(webKitValue: $0) })
        default:
            self = .null
        }
    }
}

/// The title shown for a page that sets none: the URL without an `http://` prefix
/// or a bare host's trailing slash; a `file:` URL's last component; nothing for
/// the blank page.
func fallbackTitle(forURL url: String) -> String {
    if url == "about:blank" || url.isEmpty { return "" }
    if url.hasPrefix("http://") {
        var rest = String(url.dropFirst("http://".count))
        if let slash = rest.firstIndex(of: "/"), rest.index(after: slash) == rest.endIndex { rest.removeLast() }
        return rest
    }
    if url.hasPrefix("file://"), let name = URL(string: url)?.lastPathComponent, !name.isEmpty { return name }
    return url
}
