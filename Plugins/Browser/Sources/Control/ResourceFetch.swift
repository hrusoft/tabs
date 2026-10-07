import Foundation
import TabsPluginSDK
import WebKit

/// `save-resource`'s fetch half: turning a `blob:`/`data:`/`http(s):` URL, or an element's
/// `src`, into bytes. Three routes, one per scheme, each measured against a strict
/// `connect-src 'self'` page:
///
/// - **`http`/`https`** is a `URLSession` request in the plugin's own configuration, carrying
///   the cookies of the page's own web data store. Because the host makes it and the page
///   doesn't, it is subject to neither the page's CSP nor CORS, which is what makes "save this
///   CDN image" work where an in-page `fetch` cannot.
/// - **`blob`** is a `fetch` inside the page, in a content world of its own (not the page's).
///   Measured on WebKit: an isolated world's `fetch` is not held to the page's CSP. It read a
///   blob that was loaded into an iframe, one only minted with `createObjectURL`, and one on
///   an `about:blank` page (`blob:null/…`), all behind `connect-src 'self'`, where the same
///   `fetch` in the page's own world fails with "Load failed". So one route covers every blob,
///   even one never loaded on a page whose CSP forbids blob fetches.
/// - **`data`** is decoded in-process; the page is not involved.
///
/// The scheme allowlist (`isAllowedResourceUrl`) is re-checked on the URL actually about to be
/// read, including one resolved from an element's `src`, where a hostile attribute could hold
/// `file:` and the http(s) route would otherwise read a local file.
struct FetchedResource: Equatable {
    var bytes: Data
    /// From the response or the media type when the route knows it; drives extension inference.
    var contentType: String?
}

@MainActor
enum ResourceFetch {
    /// How long an http(s) fetch may run before it is aborted: inside `save-resource`'s budget, so
    /// this, the more specific answer, is the one the caller gets, and the request is actually
    /// released rather than left streaming after core has given up on it.
    static let httpTimeout = Duration.seconds(25)

    /// The content world the blob fetch runs in: not the page's, so the page's CSP doesn't bind it.
    static let blobWorldName = "tabs-resource-fetch"

    // MARK: Naming the resource

    /// Resolves an element (`ref` from a prior `read-page`, or a CSS `selector`) to the URL of what
    /// it points at: `src`/`currentSrc`/`href`/`data`. Runs in the page's own world, the one
    /// `read-page`'s ref registry lives in, so a ref resolves against exactly the map that minted it.
    static func resolveElementSrc(in page: BrowserPage, ref: String?, selector: String?) async -> Result<String, VerbFailure> {
        let finder: String
        let notFound: String
        if let ref {
            finder = refResolverExpression(ref)
            notFound = staleRefError(ref)
        } else {
            finder = "document.querySelector(\(jsonQuoted(selector ?? "")))"
            notFound = "no element matches selector \(jsonQuoted(selector ?? ""))"
        }
        let script = """
            (() => {
              let el
              try { el = \(finder) } catch (e) { return { error: 'invalid selector: ' + (e && e.message) } }
              if (!el) return { error: \(jsonQuoted(notFound)) }
              const url = el.currentSrc || el.src || el.href || el.data ||
                el.getAttribute?.('src') || el.getAttribute?.('href') || ''
              if (!url) return { error: 'the element has no src/href to save' }
              return { url: String(url) }
            })()
            """
        switch await page.evaluate(script) {
        case .failure(let error): return .failure(VerbFailure("could not read the element: \(error.message)"))
        case .success(.object(let object)):
            if let error = object["error"] { return .failure(VerbFailure(error.stringValue ?? "\(error)")) }
            if let url = object["url"] { return .success(url.stringValue ?? "\(url)") }
        case .success: break
        }
        return .failure(VerbFailure("could not resolve the element to a URL"))
    }

    // MARK: Fetching

    /// Fetches `url` by the route its scheme dictates, or answers the error a caller reads. Every
    /// route holds the bytes to `maxBytes` (`BrowserServices.maxResourceBytes`).
    static func fetch(
        _ url: String, page: BrowserPage, maxBytes: Int = BrowserLimits.maxResourceBytes, httpTimeout: Duration = ResourceFetch.httpTimeout
    ) async -> Result<FetchedResource, VerbFailure> {
        guard isAllowedResourceUrl(url) else {
            return .failure(VerbFailure("url not allowed: \(url) (save-resource reads http, https, blob and data URLs)"))
        }
        guard let scheme = parsedScheme(url) else { return .failure(VerbFailure("not a valid URL: \(url)")) }
        switch scheme {
        case "data": return decodeDataURL(url, maxBytes: maxBytes)
        case "blob": return await fetchBlob(url, page: page, maxBytes: maxBytes)
        default: return await fetchHTTP(url, page: page, maxBytes: maxBytes, timeout: httpTimeout)
        }
    }

    /// `data:[<mediatype>][;base64],<data>` decoded in-process.
    static func decodeDataURL(_ url: String, maxBytes: Int = BrowserLimits.maxResourceBytes) -> Result<FetchedResource, VerbFailure> {
        guard let comma = url.firstIndex(of: ",") else { return .failure(VerbFailure("malformed data: URL")) }
        let meta = String(url[url.index(url.startIndex, offsetBy: min(5, url.count))..<comma])
        let isBase64 = meta.range(of: ";base64", options: [.caseInsensitive, .anchored, .backwards]) != nil
        let withoutEncoding = isBase64 ? String(meta.dropLast(";base64".count)) : meta
        let mediatype = withoutEncoding.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        let payload = String(url[url.index(after: comma)...])
        let bytes: Data
        if isBase64 {
            bytes = decodeLenientBase64(payload)
        } else {
            guard let decoded = payload.removingPercentEncoding else {
                return .failure(VerbFailure("could not decode data: URL: URIError: URI malformed"))
            }
            bytes = Data(decoded.utf8)
        }
        if bytes.count > maxBytes { return .failure(tooLarge(bytes.count, cap: maxBytes)) }
        return .success(FetchedResource(bytes: bytes, contentType: mediatype?.isEmpty == false ? mediatype : nil))
    }

    /// Base64 as a JavaScript engine reads it (`Buffer.from(_, 'base64')`): either alphabet,
    /// whitespace and stray characters skipped, padding optional.
    private static func decodeLenientBase64(_ text: String) -> Data {
        var cleaned = ""
        cleaned.reserveCapacity(text.utf8.count)
        scan: for scalar in text.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/": cleaned.unicodeScalars.append(scalar)
            case "-": cleaned.append("+")
            case "_": cleaned.append("/")
            case "=": break scan
            default: continue
            }
        }
        if cleaned.count % 4 == 1 { cleaned.removeLast() }
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: cleaned) ?? Data()
    }

    // MARK: blob:

    /// A `blob:` resource, by a fetch inside the page in a world of its own; the bytes come back
    /// base64. The size cap is checked inside the page against `blob.size` *before* encoding, so an
    /// oversized blob costs no giant string.
    private static func fetchBlob(_ url: String, page: BrowserPage, maxBytes: Int) async -> Result<FetchedResource, VerbFailure> {
        let script = """
            try {
              const response = await fetch(url)
              const blob = await response.blob()
              if (blob.size > max) return { tooLargeBytes: blob.size }
              const bytes = new Uint8Array(await blob.arrayBuffer())
              let binary = ''
              const CHUNK = 0x8000
              for (let i = 0; i < bytes.length; i += CHUNK) {
                binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK))
              }
              return { b64: btoa(binary), type: blob.type || null }
            } catch (error) {
              return { error: error instanceof Error ? error.name + ': ' + error.message : String(error) }
            }
            """
        // Raced (`BrowserPage.call`): a navigation mid-fetch orphans it, and it would never answer.
        let raw: JSONValue
        switch await page.call(script, arguments: ["url": url, "max": maxBytes], in: .world(name: blobWorldName)) {
        case .success(let value): raw = value
        case .failure(let error): return .failure(VerbFailure("could not run the fetch in the page: \(error.message)"))
        }
        guard case .object(let answer) = raw else {
            return .failure(VerbFailure("the blob could not be read: the page returned no data"))
        }
        if let size = answer["tooLargeBytes"]?.doubleValue { return .failure(tooLarge(Int(size), cap: maxBytes)) }
        if let encoded = answer["b64"]?.stringValue, let bytes = Data(base64Encoded: encoded) {
            return .success(FetchedResource(bytes: bytes, contentType: answer["type"]?.stringValue))
        }
        let reason = answer["error"]?.stringValue ?? "the page returned no data"
        return .failure(
            VerbFailure("the blob could not be read: fetching it inside the page failed (\(reason)): a revoked blob URL is gone entirely"))
    }

    // MARK: http(s):

    /// An `http`/`https` resource, streamed with a running byte cap so a runaway body is aborted
    /// mid-flight rather than buffered whole and rejected after, and aborted when it stalls (see
    /// `httpTimeout`). The page's cookies ride along, and cookies the response sets are
    /// written back to the page's store, as they are for any request the page's session makes.
    private static func fetchHTTP(_ url: String, page: BrowserPage, maxBytes: Int, timeout: Duration) async -> Result<
        FetchedResource, VerbFailure
    > {
        guard let target = URL(string: url) else { return .failure(VerbFailure("not a valid URL: \(url)")) }
        let cookieStore = page.webView.configuration.websiteDataStore.httpCookieStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let jar = configuration.httpCookieStorage
        for cookie in await cookieStore.allCookies() { jar?.setCookie(cookie) }
        var request = URLRequest(url: target)
        if case .success(.string(let agent)) = await page.evaluate("navigator.userAgent") {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        let download = Download(maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let outcome = await download.run(request, in: session, timeout: timeout)
        if case .success = outcome { for cookie in jar?.cookies ?? [] { await cookieStore.setCookie(cookie) } }
        return outcome
    }

    nonisolated static func tooLarge(_ bytes: Int, cap: Int) -> VerbFailure {
        func megabytes(_ count: Int) -> String { String(format: "%.1fMB", Double(count) / (1024 * 1024)) }
        return VerbFailure("resource is too large to save (\(megabytes(bytes)); the cap is \(megabytes(cap)))")
    }

    /// A deadline as the timeout message states it: whole seconds as such, else milliseconds.
    nonisolated static func describe(_ timeout: Duration) -> String {
        let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
        return milliseconds % 1000 == 0 ? "\(milliseconds / 1000)s" : "\(milliseconds)ms"
    }

    // MARK: Naming the file

    private static let extensionsByContentType: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg",
        "image/bmp": "bmp", "application/pdf": "pdf", "application/json": "json", "application/zip": "zip",
        "application/javascript": "js", "text/javascript": "js", "text/html": "html", "text/css": "css",
        "text/plain": "txt", "text/csv": "csv",
    ]

    /// Picks a file extension for a generated name: the content type when a route knows it, else a
    /// magic-byte sniff (so a blob whose type is missing still lands as `.pdf`/`.png`/…), else the
    /// URL path's own extension, else `bin`. A wrong extension is cosmetic, since the caller's file
    /// reader sniffs content, but a right one saves it a guess.
    static func extensionFor(url: String, contentType: String?, bytes: Data) -> String {
        if let contentType, let known = extensionsByContentType[contentType.lowercased()] { return known }
        if let sniffed = sniffExtension(bytes) { return sniffed }
        let path = pathname(of: url)
        if let dot = path.lastIndex(of: "."), path.lastIndex(of: "/").map({ dot > $0 }) ?? true {
            let ext = path[path.index(after: dot)...].lowercased()
            if (1...8).contains(ext.count), ext.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) { return ext }
        }
        return "bin"
    }

    /// `new URL(url).pathname`: the path of a hierarchical URL, and for `blob:` and `data:` everything
    /// after the scheme (up to the query or fragment), which is what a URL parser makes of an opaque one.
    private static func pathname(of url: String) -> String {
        guard let scheme = parsedScheme(url) else { return "" }
        if scheme == "http" || scheme == "https" { return URL(string: url)?.path ?? "" }
        let rest = url.dropFirst(scheme.count + 1)
        return String(rest.prefix { $0 != "?" && $0 != "#" })
    }

    /// Magic-byte sniff for the handful of artifact types agents actually save.
    private static func sniffExtension(_ bytes: Data) -> String? {
        let head = [UInt8](bytes.prefix(12))
        func starts(_ signature: [UInt8]) -> Bool { head.count >= signature.count && Array(head.prefix(signature.count)) == signature }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }  // %PDF
        if starts([0x89, 0x50, 0x4e, 0x47]) { return "png" }  // \x89PNG
        if starts([0xff, 0xd8, 0xff]) { return "jpg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "gif" }  // GIF8
        if starts([0x50, 0x4b, 0x03, 0x04]) { return "zip" }  // PK..
        // RIFF....WEBP
        if starts([0x52, 0x49, 0x46, 0x46]), head.count >= 12, Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return nil
    }
}

/// One http(s) download: a data task whose delegate streams the body under the byte cap, refuses a
/// status of 400 or more, refuses to follow a redirect off http(s), and settles exactly once, with
/// whichever of the response, a failure, the cap or the deadline gets there first.
private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var contentType: String?
    private var continuation: CheckedContinuation<Result<FetchedResource, VerbFailure>, Never>?
    private var outcome: Result<FetchedResource, VerbFailure>?
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func run(_ request: URLRequest, in session: URLSession, timeout: Duration) async -> Result<FetchedResource, VerbFailure> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A download cancelled before it began has already settled: it answers at once.
                let early: Result<FetchedResource, VerbFailure>? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    return nil
                }
                if let early { return continuation.resume(returning: early) }
                let task = session.dataTask(with: request)
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.settle(
                        .failure(VerbFailure("the resource did not finish downloading within \(ResourceFetch.describe(timeout))")))
                }
                // Settled since (cancelled): it has answered already, so nothing starts.
                let started = lock.withLock {
                    guard outcome == nil else { return false }
                    self.task = task
                    self.timer = timer
                    return true
                }
                guard started else { return timer.cancel() }
                task.resume()
            }
        } onCancel: {
            settle(.failure(VerbFailure("the download was cancelled")))
        }
    }

    private func settle(_ result: Result<FetchedResource, VerbFailure>) {
        let pending: (CheckedContinuation<Result<FetchedResource, VerbFailure>, Never>?, URLSessionDataTask?, Task<Void, Never>?)? =
            lock.withLock {
                guard outcome == nil else { return nil }
                outcome = result
                defer { continuation = nil }
                return (continuation, task, timer)
            }
        guard let (continuation, task, timer) = pending else { return }
        timer?.cancel()
        task?.cancel()
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            if http.statusCode >= 400 {
                settle(.failure(VerbFailure("the resource returned HTTP \(http.statusCode)")))
                return completionHandler(.cancel)
            }
            lock.withLock {
                contentType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first.map(String.init)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int = lock.withLock {
            buffer.append(data)
            return buffer.count
        }
        if total > maxBytes { settle(.failure(ResourceFetch.tooLarge(total, cap: maxBytes))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            settle(.failure(VerbFailure("could not fetch the resource: \(error.localizedDescription)")))
        } else {
            let (bytes, type) = lock.withLock { (buffer, contentType) }
            settle(.success(FetchedResource(bytes: bytes, contentType: type)))
        }
    }

    /// A redirect stays on http(s): the allowlist governs where bytes are read from, and a server
    /// must not be able to walk it to a `file:` URL.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let scheme = request.url?.scheme?.lowercased()
        if scheme == "http" || scheme == "https" { return completionHandler(request) }
        settle(
            .failure(
                VerbFailure("the resource redirected to \(request.url?.absoluteString ?? "a URL"), which save-resource does not read from"))
        )
        completionHandler(nil)
    }
}
