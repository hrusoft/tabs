import Foundation

/// How the page's console reaches the host. `WKWebView` reports no `console.*`
/// call and no uncaught error, so the page is made to say so: a document-start
/// script wraps `console.*` and posts each call to a message handler, and a
/// second script listens for uncaught errors and unhandled rejections.
///
/// Two worlds, on purpose (both measured):
///
/// - **The `console.*` wrapper runs in the page's own world**, since each world
///   has its own `console`: a wrapper in another world would never see the page's
///   calls. It captures its handler before any page script runs, so a page that
///   later deletes `window.webkit` can't silence it, and it is invisible except by
///   inspecting `console.log.toString()`.
/// - **The error listener runs in a private world**: uncaught-error and
///   unhandled-rejection events reach listeners in every world (measured), and
///   from there a page can neither remove the listener nor tamper with what it
///   posts.
enum ConsoleCapture {
    static let pageHandlerName = "tabsConsole"
    static let errorHandlerName = "tabsErrors"
    static let errorWorldName = "tabs-console-errors"

    /// Wraps `console.log/info/debug/warn/error`, posting `{level, text, source, line}`.
    /// The call's script URL and line are the first frame of the wrapper's own
    /// stack that isn't the wrapper: it runs in the page's world, so the page's
    /// frames are in it (measured: `@user-script:4:37:82` then
    /// `global code@http://…/page:2:12`). A call with no such frame (from injected
    /// script) carries neither.
    /// The text is the browser's own rendering: a string as is, anything else
    /// through `String(…)` (`[object Object]`, `1,2`, `null`, `undefined`), and the
    /// first argument's `%s %d %i %f %o %O %c %%` directives applied as the
    /// console applies them.
    static let pageScript = #"""
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tabsConsole
          if (!handler || window.__tabsConsoleWrapped) return
          Object.defineProperty(window, '__tabsConsoleWrapped', { value: true })
          const post = handler.postMessage.bind(handler)
          const text = (value) => {
            try {
              return typeof value === 'string' ? value : String(value)
            } catch (error) {
              return Object.prototype.toString.call(value)
            }
          }
          const number = (value) => (typeof value === 'symbol' ? 'NaN' : String(Number(value)))
          const format = (args) => {
            if (typeof args[0] === 'string' && args.length > 1 && args[0].includes('%')) {
              let next = 1
              const first = args[0].replace(/%([sdifoOc%])/g, (match, directive) => {
                if (directive === '%') return '%'
                if (next >= args.length) return match
                const value = args[next++]
                switch (directive) {
                  case 's': case 'o': case 'O': return text(value)
                  case 'd': return number(value)
                  case 'i': return typeof value === 'symbol' ? 'NaN' : String(parseInt(value))
                  case 'f': return typeof value === 'symbol' ? 'NaN' : String(parseFloat(value))
                  default: return ''
                }
              })
              return [first, ...args.slice(next).map(text)].join(' ')
            }
            return args.map(text).join(' ')
          }
          // The first frame below the wrapper's: `name@url:line:column`. Never the reason a
          // message is lost: a page that broke what this reads gets the message without it.
          const callSite = () => {
            try {
              for (const frame of String(new Error().stack ?? '').split('\n')) {
                const match = /@(.+):(\d+):\d+$/.exec(frame)
                if (match && !match[1].startsWith('user-script:')) return { source: match[1], line: Number(match[2]) }
              }
            } catch (error) {}
            return {}
          }
          for (const [method, level] of [['log', 'info'], ['info', 'info'], ['debug', 'verbose'], ['warn', 'warning'], ['error', 'error']]) {
            const original = console[method].bind(console)
            console[method] = (...args) => {
              try {
                post({ level, text: format(args), ...callSite() })
              } catch (error) {}
              return original(...args)
            }
          }
        })()
        """#

    /// Reports uncaught errors and unhandled rejections as the console prints them.
    static let errorScript = #"""
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tabsErrors
          if (!handler) return
          const post = handler.postMessage.bind(handler)
          window.addEventListener('error', (event) => {
            const message = String(event.message || '')
            post({ level: 'error', text: message.startsWith('Uncaught') ? message : 'Uncaught ' + message, source: event.filename || undefined, line: event.lineno || undefined })
          })
          window.addEventListener('unhandledrejection', (event) => {
            let reason
            try {
              reason = String(event.reason)
            } catch (error) {
              reason = Object.prototype.toString.call(event.reason)
            }
            post({ level: 'error', text: 'Uncaught (in promise) ' + reason })
          })
        })()
        """#
}

/// How the host learns that the page has *processed* the input it sent. An
/// `NSEvent` handed to the web view is queued: WebKit sends a mouse-up only after
/// the page acknowledged the mouse-down, and each key after the one before it, so
/// a script evaluated right after sending can run before the page has seen the
/// events (measured: a read straight after a click sees only its `mousedown`).
///
/// A capturing listener in the private world (page scripts can neither see nor
/// stop it: it is registered first, on `window`) counts the events that end a
/// gesture: `mouseup`, `keyup`, `input` (which text inserted with no key
/// behind it produces), and `mousemove` (a hover's only event). The count is
/// read back from that world.
enum InputAcknowledgement {
    static let counters = "__tabsInputSeen"

    static let script = #"""
        (() => {
          const seen = { mouseup: 0, keyup: 0, input: 0, mousemove: 0 }
          Object.defineProperty(window, '__tabsInputSeen', { value: seen })
          for (const type of Object.keys(seen)) window.addEventListener(type, () => { seen[type]++ }, true)
        })()
        """#
}
