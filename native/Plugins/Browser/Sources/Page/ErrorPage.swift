import Foundation
import WebKit

/// The page shown for a main-frame load that failed.
///
/// `WKWebView` shows nothing for a failed load, where the Electron app's guest
/// shows Chromium's error page as a *commit* at the failed URL: the page's URL,
/// its history entry and the saved `config.url` all follow the failure. A
/// failed page here is a document of the app's own served over a scheme it
/// registers on the web view (`tabs-error:`), loaded like any navigation, so it
/// is a real history entry (Back leaves it, Forward comes back to it).
/// `loadHTMLString(…, baseURL: failedURL)` was measured and refused: it
/// *replaces* the current history entry, so a failure would take the previous
/// page's Back target with it. `BrowserPage` maps the scheme back: the failed
/// URL is the page's URL, and the error's name rides in the entry itself, so a
/// history step onto a failed entry knows why it failed.
enum ErrorPage {
    static let scheme = "tabs-error"

    /// The URL of the error document for `failedURL`, failing with `code`.
    static func url(failedURL: String, code: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "page"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "url", value: failedURL), URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    /// What an error document's URL says, or nil for any other URL.
    static func parse(_ url: URL) -> (failedURL: String, code: String)? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        guard let failed = items.first(where: { $0.name == "url" })?.value, let code = items.first(where: { $0.name == "code" })?.value
        else { return nil }
        return (failed, code)
    }

    /// The document: Chromium's error page in miniature (a heading, why, and
    /// the code) that follows the system appearance.
    static func html(failedURL: String, code: String) -> String {
        let host = URL(string: failedURL)?.host ?? failedURL
        let title = escape(host)
        return """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(title)</title>
            <style>
            :root { color-scheme: light dark; }
            body { font: 14px -apple-system, sans-serif; margin: 0; padding: 72px 10%; }
            h1 { font-size: 24px; font-weight: 500; margin: 0 0 16px; }
            p { margin: 8px 0; color: GrayText; }
            .code { font-size: 12px; margin-top: 24px; }
            </style></head>
            <body>
            <h1>This site can’t be reached</h1>
            <p>\(escape(LoadErrors.explanation(code: code, host: host)))</p>
            <p class="code">\(escape(code))</p>
            </body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Serves `ErrorPage.html` for the `tabs-error:` scheme.
final class ErrorPageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        let parsed = url.flatMap(ErrorPage.parse)
        let body = Data(ErrorPage.html(failedURL: parsed?.failedURL ?? "", code: parsed?.code ?? "ERR_FAILED").utf8)
        let response = URLResponse(
            url: url ?? URL(string: "\(ErrorPage.scheme)://page/")!, mimeType: "text/html", expectedContentLength: body.count,
            textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
