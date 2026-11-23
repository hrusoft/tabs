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

    /// Wraps `console.log/info/debug/warn/error`, `dir`, `table`, `group`,
    /// `groupCollapsed`, `trace` and `assert` (a failing one), posting `{level, text,
    /// source, line}`; `count`, `time`, `groupEnd` and the rest aren't captured.
    /// The call's script URL and line are the first frame of the wrapper's own
    /// stack that isn't the wrapper: it runs in the page's world, so the page's
    /// frames are in it (measured: `@user-script:4:37:82` then
    /// `global code@http://…/page:2:12`). A call with no such frame (from injected
    /// script) carries neither.
    /// The text is what the console previews: a string as is, any other value
    /// rendered (`inspect`: `{a: 1}`, `[1, 2]`, `Map(1) {"k" => 1}`, `<div#id.class>`,
    /// `10n`, a cycle `[Circular]`; it used to be `String(…)`'s `[object Object]`), the
    /// first argument's `%s %d %i %f %o %O %c %%` directives applied as the console
    /// applies them, and the whole cut at `BrowserLimits.consoleMessageMax`.
    ///
    /// The rendering is bounded and runs no page code it can avoid: three levels deep
    /// and a hundred entries per level, each checked before anything below is rendered
    /// (a million-entry array costs a hundred); an own property is read from its
    /// descriptor, so a getter shows as `[Getter]` rather than running (as a console
    /// preview doesn't run it, and a framework's reactive getters would start tracking);
    /// and a console call made while a value renders (a Proxy's trap that logs) isn't
    /// captured, so nothing recurses. `JSON.stringify`, `Object.keys`,
    /// `Object.getOwnPropertyDescriptor`, `Array.isArray`, `ArrayBuffer.isView`,
    /// `Object.prototype.toString` and the Map and Set iterators are captured at
    /// document start, before any page script runs.
    static let pageScript = #"""
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tabsConsole
          if (!handler || window.__tabsConsoleWrapped) return
          Object.defineProperty(window, '__tabsConsoleWrapped', { value: true })
          const post = handler.postMessage.bind(handler)
          const quote = JSON.stringify.bind(JSON)
          const keysOf = Object.keys
          const descriptorOf = Object.getOwnPropertyDescriptor
          const isArray = Array.isArray
          const isView = ArrayBuffer.isView
          const toTag = Function.prototype.call.bind(Object.prototype.toString)
          const mapEntries = Function.prototype.call.bind(Map.prototype.entries)
          const setValues = Function.prototype.call.bind(Set.prototype.values)
          const maxDepth = 3
          const maxEntries = 100
          // At most `maxEntries` of what `iterator` yields, rendered by `render`, and how many it had.
          const firstOf = (iterator, render) => {
            const shown = []
            for (const item of { [Symbol.iterator]: () => iterator }) {
              if (shown.length === maxEntries) break
              shown.push(render(item))
            }
            return shown
          }
          const more = (count) => (count > maxEntries ? ', … ' + (count - maxEntries) + ' more' : '')
          const inspect = (value, depth, ancestors) => {
            if (value === null) return 'null'
            switch (typeof value) {
              case 'undefined': return 'undefined'
              case 'string': return depth === 0 ? value : quote(value)
              case 'bigint': return String(value) + 'n'
              case 'function': return value.name ? '[Function: ' + value.name + ']' : '[Function]'
              case 'object': break
              default: return String(value)
            }
            if (ancestors.includes(value)) return '[Circular]'
            if (value instanceof Error) return String(value)
            if (value instanceof Date) return isNaN(value) ? 'Invalid Date' : value.toISOString()
            if (value instanceof RegExp) return String(value)
            if (value instanceof Element) {
              const id = value.id ? '#' + value.id : ''
              const classes = typeof value.className === 'string' && value.className.trim() ? '.' + value.className.trim().split(/\s+/).join('.') : ''
              return '<' + value.tagName.toLowerCase() + id + classes + '>'
            }
            if (value instanceof Node) return value.nodeName
            const name = toTag(value).slice(8, -1)
            if (depth >= maxDepth) return isArray(value) ? '[Array]' : name === 'Object' ? '[Object]' : name
            const inner = [...ancestors, value]
            const below = (item) => inspect(item, depth + 1, inner)
            // An own property as stored: a getter is page code, shown rather than run.
            const own = (key) => {
              const descriptor = descriptorOf(value, key)
              if (!descriptor) return 'undefined'
              if ('value' in descriptor) return below(descriptor.value)
              return descriptor.get ? '[Getter]' : '[Setter]'
            }
            if (isArray(value)) {
              const shown = []
              for (let index = 0; index < value.length && index < maxEntries; index++) shown.push(own(String(index)))
              return '[' + shown.join(', ') + more(value.length) + ']'
            }
            if (isView(value) && typeof value.length === 'number') {
              const shown = []
              for (let index = 0; index < value.length && index < maxEntries; index++) shown.push(below(value[index]))
              return name + '(' + value.length + ') [' + shown.join(', ') + more(value.length) + ']'
            }
            if (value instanceof Map) {
              const shown = firstOf(mapEntries(value), ([key, item]) => below(key) + ' => ' + below(item))
              return 'Map(' + value.size + ') {' + shown.join(', ') + more(value.size) + '}'
            }
            if (value instanceof Set) {
              const shown = firstOf(setValues(value), below)
              return 'Set(' + value.size + ') {' + shown.join(', ') + more(value.size) + '}'
            }
            const keys = keysOf(value)
            const shown = keys.slice(0, maxEntries).map((key) => (/^[A-Za-z_$][\w$]*$/.test(key) ? key : quote(key)) + ': ' + own(key))
            return (name === 'Object' ? '' : name + ' ') + '{' + shown.join(', ') + more(keys.length) + '}'
          }
          const text = (value) => {
            try {
              return inspect(value, 0, [])
            } catch (error) {
              return toTag(value)
            }
          }
          const cut = (message) => (message.length > \#(BrowserLimits.consoleMessageMax) ? message.slice(0, \#(BrowserLimits.consoleMessageMax)) + '…' : message)
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
          // Each method's level and its text, or null for a call that prints nothing (an assert that holds).
          const methods = {
            log: ['info', format], info: ['info', format], debug: ['verbose', format], warn: ['warning', format], error: ['error', format],
            dir: ['info', (args) => (args.length ? text(args[0]) : '')],
            table: ['info', (args) => (args.length ? text(args[0]) : '')],
            group: ['info', (args) => (args.length ? format(args) : 'console.group')],
            groupCollapsed: ['info', (args) => (args.length ? format(args) : 'console.groupCollapsed')],
            trace: ['info', (args) => (args.length ? 'Trace: ' + format(args) : 'Trace')],
            assert: ['error', (args) => (args[0] ? null : 'Assertion failed' + (args.length > 1 ? ': ' + format(args.slice(1)) : ''))]
          }
          // A call made while a value renders (page code the rendering ran: a Proxy's trap) isn't captured.
          let rendering = false
          for (const [method, [level, render]] of Object.entries(methods)) {
            if (typeof console[method] !== 'function') continue
            const original = console[method].bind(console)
            console[method] = (...args) => {
              if (!rendering) {
                rendering = true
                try {
                  const message = render(args)
                  if (message !== null) post({ level, text: cut(message), ...callSite() })
                } catch (error) {
                } finally {
                  rendering = false
                }
              }
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
