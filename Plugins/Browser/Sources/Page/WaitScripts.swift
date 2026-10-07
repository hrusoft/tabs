import Foundation

// The page-side halves of the `wait-for` verb (the host supervisor that injects
// them is `PageWait`): long-lived promise scripts that watch the page from inside,
// so a wait costs one evaluation however long it runs, instead of a poll per
// interval from outside.
//
// Both scripts observe the same contract:
//
// - **They always resolve, never reject**, settling `{ settled: false }` at their
//   own `budgetMs`: so on a page that simply never satisfies the condition, the
//   supervisor gets a clean answer rather than a promise it must abandon. The one
//   case they cannot cover is the page *navigating* mid-wait, which destroys this
//   context and everything in it: a pending evaluation then never settles at all
//   (measured on WebKit), which is what the supervisor's race against navigation
//   events exists for.
// - **The MutationObserver is the primary signal; timers are fallback.** A
//   backgrounded or hidden page throttles timers but delivers observer callbacks
//   unthrottled (they ride the microtask queue), so a condition wait against a pane
//   the user isn't looking at still resolves promptly on the mutation that satisfies
//   it. The interval only catches changes no mutation announces, and the in-page
//   budget timer firing late in a throttled page is harmless: the supervisor's own
//   deadline is host-side and exact. The idle wait inverts the roles: mutations are
//   *stamped* by the persistent tracker's observer and the timer only reads the
//   timestamps, so throttling delays its verdict without ever falsifying it.

/// A condition over the page's content: text or selector, optionally inverted.
struct WaitConditionSpec: Equatable, Sendable {
    var text: String?
    var selector: String?
    /// Resolve when the condition *stops* holding instead.
    var gone = false

    init(text: String? = nil, selector: String? = nil, gone: Bool = false) {
        self.text = text
        self.selector = selector
        self.gone = gone
    }
}

/// Resolves when `spec` holds (or stops holding, under `gone`).
///
/// Text is matched against `innerText`: the same probe `get-page-text` reads, and
/// the reason "rendered text" is the promise: script bodies and hidden nodes never
/// match. A selector matches only elements the page actually shows
/// (`visibleElementJS`, `read-page`'s own visibility fragment), so a hidden
/// `<template>` clone can't satisfy "wait for the modal" and a spinner turned
/// `display: none` counts as gone. A visible selector match is registered in the
/// shared ref registry through `read-page`'s own minting fragment (`mintRefJS`) and
/// reported as `{ ref, tag, rect }`, so the caller's next verb can target it
/// directly.
///
/// Mutation bursts are coalesced to at most one check per `pollMs` (trailing-edge),
/// because the text check serializes the whole document's innerText: cheap once,
/// hostile at every-mutation frequency on a busy page.
func waitConditionScript(_ spec: WaitConditionSpec, budgetMs: Int, pollMs: Int) -> String {
    let currentMatch: String
    if let selector = spec.selector {
        currentMatch = #"""
            () => {
                  let candidates
                  try {
                    candidates = document.querySelectorAll(\#(jsonQuoted(selector)))
                  } catch {
                    return { invalid: true }
                  }
                  for (const el of candidates) {
                    if (isVisible(el)) return { el }
                  }
                  return null
                }
            """#
    } else {
        currentMatch = #"""
            () => {
                  const text = (document.body ?? document.documentElement)?.innerText ?? ''
                  return text.includes(\#(jsonQuoted(spec.text ?? ""))) ? {} : null
                }
            """#
    }
    let finishing: String
    if spec.gone {
        finishing = "if (match) return\n      finish({ settled: true })"
    } else {
        finishing = #"""
            if (!match) return
                  if (match.el) {
                    return finish({
                      settled: true,
                      ref: mintRef(match.el),
                      tag: match.el.tagName.toLowerCase(),
                      rect: roundRect(match.el.getBoundingClientRect())
                    })
                  }
                  finish({ settled: true })
            """#
    }
    return #"""
        (() => new Promise((resolve) => {
            \#(visibleElementJS)
            \#(mintRefJS)
            const finishers = []
            let done = false
            const finish = (value) => {
              if (done) return
              done = true
              for (const cancel of finishers) cancel()
              resolve(value)
            }
            const currentMatch = \#(currentMatch)
            const check = () => {
              // Stamped here rather than only in requestCheck's timer, so the interval
              // below counts toward the coalescing window too. Without it a mutation
              // landing just after an interval tick saw a stale lastCheck, computed a
              // zero wait and ran a second whole-document check immediately — up to
              // twice the intended rate of an innerText serialization, sustained for
              // the life of the wait.
              lastCheck = Date.now()
              const match = currentMatch()
              if (match && match.invalid) {
                return finish({ error: 'invalid selector: ' + \#(jsonQuoted(spec.selector ?? "")) })
              }
              \#(finishing)
            }
            let scheduled
            let lastCheck = 0
            const requestCheck = () => {
              if (done || scheduled !== undefined) return
              const wait = Math.max(0, \#(pollMs) - (Date.now() - lastCheck))
              scheduled = setTimeout(() => {
                scheduled = undefined
                check()
              }, wait)
            }
            const observer = new MutationObserver(requestCheck)
            observer.observe(document.documentElement ?? document, {
              subtree: true,
              childList: true,
              characterData: true,
              attributes: true
            })
            const interval = setInterval(requestCheck, \#(pollMs))
            const budget = setTimeout(() => finish({ settled: false }), \#(budgetMs))
            finishers.push(
              () => observer.disconnect(),
              () => clearInterval(interval),
              () => clearTimeout(budget),
              () => clearTimeout(scheduled)
            )
            check()
          }))()
        """#
}

/// Resolves once the DOM has stayed mutation-free for `quietMs`: the "wait until
/// this page settles" fallback for pages with no specific marker to key on.
///
/// Quiet is *measured*, not debounced: the persistent DOM-activity tracker
/// (`ensureDomActivityJS`, the same timestamps behind the read verbs' `settled`
/// field, so "idle" and "settled" cannot drift apart) stamps every mutation, and
/// this script is only a self-rescheduling timer over those timestamps: check how
/// long the page has been quiet, and if not long enough, sleep exactly the remainder
/// and check again. Three properties fall out. Quiet that predates the wait counts:
/// a page already still for quietMs resolves immediately instead of paying a fresh
/// quiet period. A supervisor re-injection (after the page's own budget runs out)
/// resumes the same measurement rather than restarting the clock. And a throttled
/// timer in a hidden page can only *delay* the verdict, never falsify it: whenever
/// the check finally runs, it judges from timestamps, so an idle verdict is never
/// reached early.
func domIdleScript(quietMs: Int, budgetMs: Int) -> String {
    #"""
    (() => new Promise((resolve) => {
        \#(ensureDomActivityJS)
        let done = false
        let timer
        const finish = (value) => {
          if (done) return
          done = true
          clearTimeout(timer)
          clearTimeout(budget)
          resolve(value)
        }
        const budget = setTimeout(() => finish({ settled: false }), \#(budgetMs))
        const check = () => {
          if (done) return
          const remaining = \#(quietMs) - (Date.now() - Math.max(activity.installedAt, activity.lastAt))
          if (remaining <= 0) return finish({ settled: true })
          timer = setTimeout(check, remaining)
        }
        check()
      }))()
    """#
}
