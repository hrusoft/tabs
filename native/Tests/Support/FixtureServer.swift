import Foundation
import Network

/// A tiny HTTP server on the loopback interface, in the test process: the pages a
/// browser test loads, with the failure modes a page engine has to be measured
/// against and no network in sight. Shared by every tier that needs a page: the
/// unhosted plugin tests, the in-process UI tier and the end-to-end tests (which
/// run the app as its own process, so a real port is what it can reach).
///
/// ```swift
/// let server = try await FixtureServer.start()
/// server.page("/a", title: "Page A", body: "<button>Go</button>")
/// server.route("/slow") { _ in .init(body: "late", delay: .milliseconds(500)) }
/// server.route("/gone") { _ in .init(status: 404, body: "no such page") }
/// server.route("/bounce") { _ in .redirect(to: "/a") }
/// server.route("/csp") { _ in .init(headers: ["Content-Security-Policy": "default-src 'none'"], body: "…") }
/// try await page.load(server.url("/a"))
/// server.stop()
/// ```
///
/// Every response closes its connection (`Connection: close`). An unrouted path
/// answers 404 with an HTML body naming it. `requests` is every request seen, in
/// order. `FixtureServer.startStandard()` is a server with the pages the Electron
/// external-control tests run against (`FixtureServer+Standard.swift`). `FixtureServer.closedPort()` is a port nothing listens on (a connection
/// refused), and `start(port:)` can start a server on such a port later ("the dev
/// server comes up").
final class FixtureServer: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        var method: String
        /// The path and query, as sent.
        var target: String
        var headers: [String: String]

        var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
    }

    struct Response: Sendable {
        var status = 200
        /// The reason phrase; nil is the standard one.
        var reason: String?
        var headers: [String: String] = [:]
        var body = Data()
        /// How long to wait before answering.
        var delay: Duration = .zero
        /// Send the headers, then never finish the body: a load that never ends.
        var hangs = false

        init(
            status: Int = 200, reason: String? = nil, contentType: String = "text/html; charset=utf-8", headers: [String: String] = [:],
            body: String = "", delay: Duration = .zero, hangs: Bool = false
        ) {
            self.status = status
            self.reason = reason
            self.headers = headers
            self.headers["Content-Type"] = self.headers["Content-Type"] ?? contentType
            self.body = Data(body.utf8)
            self.delay = delay
            self.hangs = hangs
        }

        init(status: Int, contentType: String, data: Data, headers: [String: String] = [:]) {
            self.init(status: status, contentType: contentType, headers: headers)
            body = data
        }

        static func redirect(to location: String, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location": location])
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.tabs.fixture-server")
    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var fallbackHandler: Handler?
    private var log: [Request] = []
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Starts a server on `port` (any free one by default).
    static func start(port: UInt16? = nil) async throws -> FixtureServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let server = FixtureServer(listener: listener)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    server.port = listener.port?.rawValue ?? 0
                    if once.first() { continuation.resume() }
                case .failed(let error):
                    if once.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { connection in server.accept(connection) }
            listener.start(queue: server.queue)
        }
        return server
    }

    /// A port nothing listens on: bound, learned, released.
    static func closedPort() async throws -> UInt16 {
        let server = try await start()
        let port = server.port
        server.stop()
        // The kernel needs a moment to let go of it.
        try await Task.sleep(for: .milliseconds(100))
        return port
    }

    func stop() {
        listener.cancel()
    }

    /// `http://127.0.0.1:<port><path>`.
    func url(_ path: String = "/") -> String { "http://127.0.0.1:\(port)\(path)" }

    /// The same server under a name a page can't share an origin with.
    func url(_ path: String, host: String) -> String { "http://\(host):\(port)\(path)" }

    /// Answers `path` (without its query) with whatever `handler` makes of the request.
    func route(_ path: String, _ handler: @escaping Handler) {
        lock.withLock { routes[path] = handler }
    }

    func route(_ path: String, _ response: Response) {
        route(path) { _ in response }
    }

    /// Answers every path no route claims (instead of the 404), the way a server with a default page does.
    func fallback(_ handler: @escaping Handler) {
        lock.withLock { fallbackHandler = handler }
    }

    /// An HTML page with a title and a body (the head takes more, e.g. a script or style).
    func page(_ path: String, title: String? = nil, head: String = "", body: String = "", headers: [String: String] = [:]) {
        let titleTag = title.map { "<title>\($0)</title>" } ?? ""
        route(path, Response(headers: headers, body: "<!doctype html><html><head>\(titleTag)\(head)</head><body>\(body)</body></html>"))
    }

    /// Every request seen, oldest first.
    var requests: [Request] { lock.withLock { log } }

    private static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 410: "Gone",
        418: "I'm a teapot", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
    ]

    /// A page that logs every keyboard, pointer and input event it gets into `window.__log` as
    /// `type:key:code:modifiers:trusted[:data]` (`T` for a trusted event): a form, a textarea, a button, a hover target.
    static let eventsPage = """
        <style>body{margin:0} #a{position:absolute;left:10px;top:10px;width:150px;height:30px}
        #b{position:absolute;left:10px;top:60px;width:150px;height:60px}
        #btn{position:absolute;left:200px;top:10px;width:80px;height:40px}
        #hov{position:absolute;left:200px;top:100px;width:80px;height:40px;background:#eee}
        #hov:hover{background:#0f0}</style>
        <form id=f action="/submitted" method=get><input id=a name=q autocomplete=off></form>
        <textarea id=b></textarea><button id=btn>Go</button><div id=hov>hover</div>
        <script>
        window.__log = []
        const log = (type, e) => window.__log.push(type + ':' + (e.key ?? '') + ':' + (e.code ?? '') + ':' +
          [e.shiftKey ? 'S' : '', e.ctrlKey ? 'C' : '', e.altKey ? 'A' : '', e.metaKey ? 'M' : ''].join('') + ':' +
          (e.isTrusted ? 'T' : 'u') + (e.data ? ':d=' + e.data : ''))
        for (const t of ['keydown', 'keypress', 'keyup', 'input', 'beforeinput', 'mousedown', 'mouseup', 'click', 'mousemove', 'contextmenu'])
          document.addEventListener(t, (e) => log(t, e), true)
        document.getElementById('btn').addEventListener('click', () => window.__log.push('btn-click'))
        </script>
        """
    // MARK: Connections

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            // Not an HTTP request at all (a TLS handshake sent to a plain server): what a
            // real server does is close the connection.
            if let first = buffer.first, !(first >= 0x41 && first <= 0x5a) {
                connection.cancel()
                return
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(to: parse(buffer[..<end.lowerBound]), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    private func parse(_ head: Data) -> Request {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Request(method: parts.first.map(String.init) ?? "GET", target: parts.count > 1 ? String(parts[1]) : "/", headers: headers)
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let handler: Handler? = lock.withLock {
            log.append(request)
            return routes[request.path] ?? fallbackHandler
        }
        let response =
            handler?(request)
            ?? Response(status: 404, body: "<!doctype html><title>Not found</title><body>no route for \(request.path)</body>")
        let send: @Sendable () -> Void = { [self] in
            var head = "HTTP/1.1 \(response.status) \(response.reason ?? Self.reasons[response.status] ?? "Status")\r\n"
            var headers = response.headers
            headers["Content-Length"] = String(response.body.count + (response.hangs ? 1_000_000 : 0))
            headers["Connection"] = "close"
            for (key, value) in headers { head += "\(key): \(value)\r\n" }
            head += "\r\n"
            connection.send(
                content: Data(head.utf8) + response.body,
                completion: .contentProcessed { _ in
                    if !response.hangs { connection.cancel() }
                })
            _ = self
        }
        if response.delay > .zero {
            let nanoseconds = response.delay.components.seconds * 1_000_000_000 + response.delay.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: send)
        } else {
            send()
        }
    }
}
