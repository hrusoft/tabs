/**
 * The browser content type's half of the external-control wire protocol — the
 * page-semantics verbs and the types they speak in.
 *
 * ## What is here and what is not
 *
 * The split is by *type shape*, not by which module registers the handler.
 * `activatePane`, `closePane`, `listOwnedPanes` and `getPaneInfo` are all
 * registered by this content type today (see
 * src/plugins/browser/renderer/browserExternalControl.ts), but their request types
 * name nothing about a page — they take a pane id and act on the layout — so
 * they stay in core's ../../externalControl.ts. If those verbs ever gain a
 * second implementor, core's protocol will already be the right shape for it.
 * Moving a handler to make the type line come out neater would be the tail
 * wagging the dog.
 *
 * `readNetworkRequests`, `captureNetworkBodies` and `saveResource` are the
 * mirror-image cases and live here: main answers each from machinery it owns
 * (the capture buffer, the CDP body session, the fetch routes) without ever
 * relaying to a renderer, but every one is about a page, so their types are
 * browser types.
 *
 * ## The wire is frozen
 *
 * Every verb name, field name and constant below is what `tabs-ctl` and the
 * bundled skill (resources/skills/tabs) already send, and what any shell
 * currently sitting in a terminal pane will send after an upgrade. Splitting
 * the declarations across files changes nothing an external caller can see,
 * and nothing here may be renamed for tidiness.
 */

/**
 * The semantic form of an `ElementTarget`: matched inside the guest against
 * the same role/accessible-name derivation `readPage` reports, and/or a CSS
 * selector, then acted on in the same pass — no prior `readPage` round trip.
 *
 * Criteria AND-combine: `selector` defines the candidate pool (any element,
 * where role/name alone search the interactive set `readPage` extracts), and
 * `role`/`name` filter it. Name matching is a strictness ladder — exact, then
 * case-insensitive exact, then case-insensitive substring, all
 * whitespace-normalized — and the strictest non-empty tier wins. More than
 * one match in that tier fails listing the candidates rather than guessing;
 * `nth` (0-based, document order) indexes into that tier's list. Elements the
 * page hides (zero-size, `display: none`, `visibility: hidden`) never match.
 *
 * At least one of `role`/`name`/`selector` must be present — enforced where
 * the target is resolved, since what arrives over the socket is untyped wire
 * input regardless of what this union says.
 */
export interface SemanticTarget {
  role?: string
  name?: string
  selector?: string
  nth?: number
}

/**
 * What an input verb aims at: an opaque `ref` handed out by a previous
 * `readPage` on the *current* page, a raw viewport coordinate, or semantic
 * criteria matched at act time (see `SemanticTarget`).
 *
 * Ref and coordinate resolve to the same CSS-pixel space — the guest's own
 * viewport, which is what `getBoundingClientRect` reports inside the page and
 * what `sendInputEvent` expects. Note that a screenshot's pixel dimensions
 * are *device* pixels, `scaleFactor`× larger on a HiDPI display; divide
 * before using a coordinate read off an image.
 */
export type ElementTarget = { ref: string } | { x: number; y: number } | SemanticTarget

export type KeyModifier = 'shift' | 'control' | 'alt' | 'meta'

/**
 * The editing commands `key --command` exposes, run in the guest through
 * `document.execCommand` (`select-all` → `selectAll`). Deliberately not the
 * clipboard trio: `copy`/`cut`/`paste` cross into the user's own system
 * clipboard, which an agent driving a page must not do as an invisible side
 * effect.
 *
 * Stated as a list rather than a bare union so the runtime check and the type
 * cannot drift — what arrives over the socket is untyped, so the verb has to
 * validate the name it was given anyway.
 */
export const EDITING_COMMANDS = ['select-all', 'undo', 'redo', 'delete'] as const

export type EditingCommand = (typeof EDITING_COMMANDS)[number]

/** One element from a `readPage` extraction. Rect is in the guest's CSS-pixel viewport space. */
export interface PageElement {
  ref: string
  role: string
  name: string
  tag: string
  rect: { x: number; y: number; width: number; height: number }
  value?: string
}

/**
 * How `click` reports the element involved, derived with the same
 * `roleFor`/`nameFor` readPage uses so the vocabulary matches `PageElement`.
 * A ref click returns the ref'd element's description, confirmed at dispatch
 * time to be what actually sits at the click point (a mismatch fails the verb
 * instead); a coordinate click returns whatever is at the point — reporting,
 * never a gate, since the caller named the exact spot. Absent when the guest
 * couldn't be asked (a Chromium error page) or nothing is at the point.
 */
export interface ElementDescription {
  role: string
  name: string
  tag: string
}

/**
 * Every request whose meaning is a page's — loading one, reading one, driving
 * one. Each carries `paneId` (the caller's own pane, for the ownership check)
 * plus `targetPaneId`, the browser pane it acts on, which must be one this
 * caller created via `createBrowserPane`.
 */
export type BrowserControlRequest =
  | { type: 'createBrowserPane'; paneId: string; url: string }
  | {
      type: 'navigate'
      paneId: string
      targetPaneId: string
      url: string
      /**
       * Re-issue the navigation once when the first attempt settles somewhere
       * other than the requested URL (see `isTrivialUrlChange`) — the auth
       * bounce whose first hit establishes the session and whose second
       * succeeds. Off by default: a redirect is frequently correct, and
       * silently fighting it would be worse than reporting it.
       */
      retryOnRedirect?: boolean
    }
  | { type: 'reload'; paneId: string; targetPaneId: string }
  | { type: 'goBack'; paneId: string; targetPaneId: string }
  | { type: 'goForward'; paneId: string; targetPaneId: string }
  | {
      type: 'screenshot'
      paneId: string
      targetPaneId: string
      /**
       * Fail a hidden pane rather than revealing it. By default `screenshot`
       * brings a backgrounded pane to the front itself (reporting
       * `activated: true`), because a hidden guest has no frame to capture —
       * this flag is for a caller that would rather fail than change which
       * tab the user is looking at.
       */
      noActivate?: boolean
      /**
       * Clip the capture to one element's bounding rect instead of taking the
       * whole viewport — a `readPage` ref, or a CSS selector resolved at
       * capture time. At most one; enforced where the request is handled,
       * since the socket delivers untyped input.
       *
       * The rect is in **CSS pixels**, which is what `capturePage` takes and
       * what the guest measures, while the PNG that comes back is in *device*
       * pixels — the same split `scaleFactor` already reports, and the reason
       * the two are never mixed here. It is clamped to the viewport before
       * capture: `capturePage` can only return pixels the guest is showing, so
       * an element taller than the screen would otherwise ask for rows that do
       * not exist.
       *
       * There is deliberately no full-page capture. Electron can capture only
       * the visible frame, so the alternatives are resizing the guest — which
       * reflows the user's own visible pane under them — or scrolling and
       * stitching N captures, which silently repeats every fixed header and
       * sticky nav in the seams. `scroll` plus repeated `screenshot` is the
       * honest version of that loop, and reports an exact position to drive it.
       */
      selector?: string
      ref?: string
    }
  | { type: 'getPageText'; paneId: string; targetPaneId: string; maxLength?: number }
  /**
   * `selector`/`role`/`offset` narrow what comes back, because the 200-element
   * cap is spent long before the interesting control on a real listing page —
   * measured on a product grid where brand checkboxes took over half the slots
   * and the `<select>` that mattered was the last entry to fit.
   *
   * They are three answers to three different questions, not three spellings
   * of one: `selector` names a pool the default candidate set would never have
   * listed (an `<img>`, a card container), `role` picks a control *kind* out
   * of a crowded page in one call, and `offset` pages through what is left.
   * Offset alone would not have fixed the measured case — you would still page
   * through the checkboxes — which is why it is the least important of the
   * three rather than the whole feature. Validated host-side (see
   * readPageFilterError): what arrives over the socket is untyped wire input.
   */
  | {
      type: 'readPage'
      paneId: string
      targetPaneId: string
      selector?: string
      role?: string
      offset?: number
    }
  | { type: 'find'; paneId: string; targetPaneId: string; description: string; maxResults?: number }
  | { type: 'click'; paneId: string; targetPaneId: string; target: ElementTarget }
  /**
   * Moves the pointer onto a target without pressing it — the same targets
   * `click` takes, resolved through the same hit-test, dispatching `mouseMove`
   * and nothing else.
   *
   * It exists because `click` was the only verb that moved the pointer and it
   * always commits the press, which makes a menu that *opens* on hover and
   * *navigates* on click structurally unreachable: hovering it clicked it.
   * Chromium holds hover state until the next pointer event, so the follow-up
   * read that inspects what appeared needs no second hover to keep it open.
   */
  | { type: 'hover'; paneId: string; targetPaneId: string; target: ElementTarget }
  | {
      type: 'type'
      paneId: string
      targetPaneId: string
      target: ElementTarget
      text: string
      submit?: boolean
    }
  | {
      type: 'scroll'
      paneId: string
      targetPaneId: string
      direction: 'up' | 'down' | 'left' | 'right'
      amount?: number
    }
  /**
   * One keystroke, or one of Chromium's own editing commands — exactly one of
   * `key`/`command`, enforced where the request is handled since the socket
   * delivers untyped input.
   *
   * The two exist because a synthesized key event **cannot** reach the editing
   * layer, measured on a real guest: `key: 'a', modifiers: ['meta']` arrives at
   * the page with `metaKey: true` and `defaultPrevented: false` — the page's
   * own keydown listeners fire normally — while the field's selection stays
   * exactly where it was (`selectionStart === selectionEnd === 8` on an
   * 8-character value). Chromium derives edit commands from the *native* key
   * path that `sendInputEvent` bypasses, so there is nothing to fix in how the
   * event is built. `command` runs `document.execCommand` inside the guest
   * instead, which reaches the editing pipeline the chord cannot.
   *
   * Note it is specifically *not* `WebContents.selectAll()` and friends: those
   * were measured inert against a guest — even called from main, on the guest
   * directly, with the field focused — because they route to the focused
   * widget of a focused window and a `<webview>` never becomes the window's
   * first responder. See editingCommandScript in ../renderer/pageScripts.ts.
   *
   * Only the non-clipboard commands are exposed. `copy`/`cut`/`paste` would
   * read or overwrite the *user's* system clipboard as a side effect of an
   * agent driving a page, which is not a thing a verb should do silently.
   */
  | {
      type: 'key'
      paneId: string
      targetPaneId: string
      key?: string
      modifiers?: KeyModifier[]
      command?: EditingCommand
    }
  | {
      type: 'readConsoleMessages'
      paneId: string
      targetPaneId: string
      pattern?: string
      sinceSeq?: number
    }
  | {
      type: 'readNetworkRequests'
      paneId: string
      targetPaneId: string
      pattern?: string
      sinceSeq?: number
      unredacted?: boolean
      /** Only entries with exactly this HTTP method, compared case-insensitively. */
      method?: string
      /**
       * Only entries whose status matches: an exact code (`404`), a class
       * (`4xx`), or an inclusive range (`400-499`) — see parseStatusSpec in
       * main/networkLog.ts, whose refusal of anything else the verb surfaces
       * as an error rather than an empty list.
       */
      status?: string
      /** Only failures: a 4xx/5xx status or a network error. The "what broke" filter. */
      failed?: boolean
      /** Only entries with exactly this Electron resource type (`mainFrame`, `xhr`, `script`, …). */
      resourceType?: string
      /**
       * Attach captured response bodies to the entries they belong to (and
       * report `bodyCapture: 'on' | 'off'` alongside). Only bodies captured
       * while `captureNetworkBodies` was on exist to attach — the double
       * opt-in is the whole redaction story for bodies, which unlike headers
       * cannot be selectively scrubbed. Off by default so the metadata read
       * stays small.
       */
      withBodies?: boolean
      /**
       * Drop the header maps and keep only the identity/outcome fields. A real
       * page load measured 146 requests at 323 KB of JSON, almost all of it
       * response headers — unreadable for the "what happened here" question
       * this verb is usually asked. The full form stays for when headers are
       * the subject.
       */
      brief?: boolean
      /**
       * Write the whole result to a file instead of returning it inline, the
       * same two-form contract `executeJavaScript`'s `outPath` uses (`true`
       * for a generated path under main's swept directory, a string for a path
       * tabs-ctl resolved against the caller's cwd).
       */
      outPath?: string | true
      /**
       * Write **one** entry's captured response body to a file, named by its
       * `seq`. The escape hatch for a body larger than the retention cap left
       * inline, and for one whose endpoint cannot be re-fetched with a GET
       * (`saveResource --url` issues one, so a POST-only endpoint 404s there).
       * Answers with the file rather than with `requests`.
       */
      bodySeq?: number
      bodyOutPath?: string | true
    }
  /**
   * Starts (or, with `enabled: false`, stops) retaining response bodies for a
   * pane, from this moment forward — a body must be captured as the response
   * arrives, so this cannot be a flag on the read. Attaches a CDP `Network`
   * session to the pane's guest (shared, refcounted — see
   * main/guestDebugger.ts); fails with the reason when a debugger cannot
   * attach (DevTools open on that pane), and every later capture failure
   * degrades to metadata-only entries rather than failing any verb. Answered
   * entirely in main, which owns the session.
   */
  | {
      type: 'captureNetworkBodies'
      paneId: string
      targetPaneId: string
      enabled?: boolean
      /**
       * Retain this many characters of each body instead of NETWORK_BODY_MAX,
       * up to NETWORK_BODY_HARD_MAX. Opt-in and per pane because the cap is
       * applied *at capture* — the excerpt is copied out of the decoded body
       * so the rest can be collected (measured: 50 excerpts of 5MB bodies
       * retained 242MB as slices and 9MB as copies), which means nothing can
       * recover a body after the fact and raising it is a real memory cost the
       * caller is choosing to pay for this pane.
       */
      maxBodyChars?: number
    }
  /**
   * `outPath` opts the result out of the inline EXECUTE_RESULT_MAX cap and
   * onto disk: the renderer hands main the *full* serialization under
   * EXECUTE_OUTPUT_KEY, main writes the file and answers with
   * `{path, bytes, format, truncated: false}` — the value itself never rides
   * the socket. `true` (tabs-ctl's bare `--out`) means a generated path under
   * main's swept directory; a string is an absolute path tabs-ctl resolved
   * against the *caller's* cwd (main's would be wrong), written `wx` — the
   * same two-form contract as saveResource's `outPath`. Absent, the inline
   * path and its cap are exactly what they always were.
   */
  | {
      type: 'executeJavaScript'
      paneId: string
      targetPaneId: string
      code: string
      outPath?: string | true
    }
  | {
      type: 'formInput'
      paneId: string
      targetPaneId: string
      fields: { target: ElementTarget; value: string }[]
    }
  /**
   * Waits inside the page until a condition holds — one call in place of a
   * caller's sleep-and-poll loop, with the polling run by the guest itself
   * (a MutationObserver plus a fallback timer) so the cost is one round trip
   * however long the wait runs, and the wait survives the page navigating
   * mid-condition (the renderer re-arms the guest side on each navigation).
   *
   * Exactly one primary condition per request — `text`, `selector`,
   * `urlContains` or `idle` — enforced where the request is handled, since
   * what arrives over the socket is untyped wire input. `gone` inverts
   * `text`/`selector` (resolve when it *stops* holding) and is meaningless
   * with the other two. `selector` matches only elements the page actually
   * shows (readPage's visibility predicate), so a hidden template can't
   * satisfy "wait for the modal" and a spinner turned `display: none` counts
   * as gone; a match reports a readPage-compatible `ref` so the natural next
   * step (click it) needs no separate readPage. `timeoutMs`/`pollMs` are
   * clamped by the shared clamps below — see them for why main must use the
   * identical arithmetic.
   */
  | {
      type: 'waitFor'
      paneId: string
      targetPaneId: string
      text?: string
      selector?: string
      gone?: boolean
      urlContains?: string
      idle?: boolean
      timeoutMs?: number
      pollMs?: number
    }
  /**
   * `waitFor`'s single-shot twin: check that a condition holds *now* and fail
   * when it doesn't, rather than returning data for the caller to inspect —
   * the step that makes a batch self-verifying (the transcript names the
   * premise that broke instead of a pile of successful reads the caller must
   * re-read). Same condition vocabulary minus `idle` — "stopped mutating" is
   * a claim about a period, not an instant — and minus the timing knobs: the
   * check is bounded by ASSERT_CHECK_BUDGET_MS below, not by a caller wait.
   */
  | {
      type: 'assert'
      paneId: string
      targetPaneId: string
      text?: string
      selector?: string
      gone?: boolean
      urlContains?: string
    }
  /**
   * Writes a page resource — a `blob:`/`data:`/`http(s):` URL, or the `src` of
   * an element named by `ref`/`selector` — to a local file and returns the
   * path, never the bytes (`tabs-ctl`'s stdout is the caller's context; a
   * megabyte of base64 there is worse than useless, the same discipline
   * `screenshot` follows). Exactly one of `url`/`ref`/`selector` is present,
   * enforced where the request is handled since the socket delivers untyped
   * input. `outPath`, when given, is an absolute path tabs-ctl resolved against
   * the *caller's* cwd (main's would be wrong); absent, main generates one
   * under its own swept directory. This verb is answered entirely in main — it
   * owns the fetch routes (see main/resourceFetch.ts) — so it never relays.
   */
  | {
      type: 'saveResource'
      paneId: string
      targetPaneId: string
      url?: string
      ref?: string
      selector?: string
      outPath?: string
    }

/**
 * This type's verb names at runtime, and the compile-time leg that keeps them
 * honest: a verb added to `BrowserControlRequest` without a key here fails to
 * build, and a key naming a verb that no longer exists fails too (excess
 * properties on an annotated literal).
 *
 * Core folds this into the protocol-wide marker rather than re-listing every
 * name, so the exhaustiveness survives the split intact — see
 * CONTROL_REQUEST_TYPE_MARKER in ../../externalControl.ts.
 */
export const BROWSER_CONTROL_REQUEST_MARKER: Record<BrowserControlRequest['type'], true> = {
  createBrowserPane: true,
  navigate: true,
  reload: true,
  goBack: true,
  goForward: true,
  screenshot: true,
  getPageText: true,
  readPage: true,
  find: true,
  click: true,
  hover: true,
  type: true,
  key: true,
  scroll: true,
  readConsoleMessages: true,
  readNetworkRequests: true,
  captureNetworkBodies: true,
  executeJavaScript: true,
  formInput: true,
  waitFor: true,
  assert: true,
  saveResource: true
}

/**
 * Cap on the bytes a single `save-resource` will write, checked before the
 * file is created — a runaway artifact (a video mistaken for the target) is
 * refused with an error naming its size and this cap rather than filling the
 * disk. 50 MB clears any plausible PDF or image with wide margin; anything
 * larger is a sign the wrong URL is in play.
 */
export const MAX_RESOURCE_BYTES = 50 * 1024 * 1024

/**
 * Key the renderer stashes a screenshot's raw PNG bytes under on its way back
 * to main, which strips it and answers the socket with a file path instead.
 * Image bytes must never reach the socket: `tabs-ctl`'s stdout is literally
 * the calling agent's context, and a megabyte of base64 there is worse than
 * useless. Named here so the two ends can't drift.
 */
export const SCREENSHOT_BYTES_KEY = 'pngBytes'

/**
 * Caps that keep a response from blowing up the caller's context. Page text
 * is truncated (always reported via `truncated: true`, never silently), and
 * a caller's own `maxLength` can lower the default but not raise it past the
 * hard cap.
 */
export const DEFAULT_PAGE_TEXT_MAX = 50_000
export const PAGE_TEXT_HARD_MAX = 200_000

/**
 * Cap on an `executeJavaScript` result, measured on its serialized form. Past
 * this the value comes back as a truncated JSON *string* with
 * `truncated: true` rather than as the value itself — a script that returns
 * the whole DOM shouldn't be able to bury its caller. The opt-out for a
 * result genuinely needed in full is the request's `outPath` (see the union
 * above): the file sink has no cap, because the caller asked for a file
 * precisely because the value is large.
 */
export const EXECUTE_RESULT_MAX = 50_000

/**
 * SCREENSHOT_BYTES_KEY's twin for `executeJavaScript` with `outPath`: the key
 * the renderer stashes the full serialized result under on its way to main,
 * which strips it, writes the file and answers the socket with a path. Same
 * discipline for the same reason — the serialization is unbounded on this
 * path, and `tabs-ctl`'s stdout is the calling agent's context.
 */
export const EXECUTE_OUTPUT_KEY = 'serializedResult'

/**
 * Cap on one captured response body, in characters, as stored and as
 * returned. Deliberately far below the page-text caps: `readNetworkRequests
 * --withBodies` returns up to a whole log's worth of bodies at once, and the
 * case bodies exist for — the error detail in a failed POST's JSON — fits in
 * a fraction of this. Truncation is explicit (`truncated: true` plus the full
 * `size`), and the full-fidelity escape hatch for anything bigger is
 * saveResource.
 */
export const NETWORK_BODY_MAX = 16_384

/**
 * The ceiling `captureNetworkBodies`'s `maxBodyChars` may raise the per-pane
 * cap to. Generous enough for the case that motivated it (a 56 KB JSON POST
 * response cut at 16 KB, with no way to recover the rest) with room to spare,
 * and still bounded, so an unbounded knob cannot just relocate the problem the
 * capture-time cap exists to prevent. What actually holds the per-pane total
 * down is BODY_CHAR_BUDGET in main/networkLog.ts, not this: raising the
 * per-body cap trades how *many* bodies a pane retains for how big they are,
 * rather than multiplying the two.
 */
export const NETWORK_BODY_HARD_MAX = 2_000_000

/**
 * How many request entries the per-pane network log retains before the oldest
 * start dropping. Stated here like the caps above so tabs-ctl's `describe`
 * and SKILL.md can quote it without drifting — tabsCtlDescribe.test.ts pins
 * the restatement. Deliberately a constant rather than a setting: dedup
 * (networkLog.ts's dedupOnCompletion) is what actually stops a poll loop from
 * flooding the log — this is just headroom for a heavy SPA's page load.
 * The *body* store keeps its own smaller cap on purpose; see BODY_CAPACITY
 * in main/networkLog.ts for why it does not follow this one.
 */
export const NETWORK_LOG_CAPACITY = 500

/**
 * How long the renderer waits on a guest page: `LOAD_WAIT_MS` for a
 * navigation to settle before answering `loaded: false`, plus `MOUNT_WAIT_MS`
 * before that for `createBrowserPane`, which first waits for React to mount
 * the new pane's webview. Defined here rather than renderer-side so main can
 * *derive* each verb's relay budget from the wait it must outlive (see
 * BROWSER_CONTROL_VERBS in src/plugins/browser/main/browserExternalControl.ts)
 * — the renderer's bounded "still loading" answer is useful to a caller, a
 * relay timeout is not, so the relay must always be the one that fires later.
 */
export const LOAD_WAIT_MS = 15_000
export const MOUNT_WAIT_MS = 5_000

/**
 * `waitFor`'s bounds. The default is deliberately above "a couple of seconds"
 * — the flag-free cases (an auth handshake, a list hydrating) routinely take
 * 3-8s, and a wrong condition costing 10s is cheaper than the caller's retry
 * round trip. The ceiling exists for the measured worst case this verb was
 * built for (a 230-second AI generation) with margin; a request may lower the
 * wait to zero (one immediate check) but never raise it past the ceiling.
 */
export const WAIT_DEFAULT_TIMEOUT_MS = 10_000
export const WAIT_MAX_TIMEOUT_MS = 300_000

/**
 * How long the DOM must stay mutation-free for `idle` to resolve. A constant
 * rather than a wire field (Playwright's networkidle uses the same figure);
 * the machinery underneath takes it as a parameter (domIdleScript in
 * src/plugins/browser/renderer/waitScripts.ts, which the `idle` branch of
 * waitForPageCondition passes this constant to), so a flag can be added
 * compatibly if a real case ever needs a different quiet period.
 *
 * Also the quiet period behind the read verbs' `settled` field (READINESS_JS
 * in src/plugins/browser/renderer/pageScripts.ts): "the page is settled" and
 * "waitFor --idle would resolve now" are deliberately the same measurement of
 * the same tracker, so a caller who reads `settled: false` and reaches for
 * `--idle` is waiting for exactly the condition the read said was missing.
 */
export const WAIT_IDLE_QUIET_MS = 500

/**
 * The in-guest fallback check interval, and the floor that keeps a caller's
 * `pollMs` from turning the guest's mutation bursts into a busy-loop. The
 * MutationObserver is the primary signal; the interval only catches changes
 * it cannot see, so there is no ceiling worth enforcing beyond the wait
 * itself.
 */
export const WAIT_DEFAULT_POLL_MS = 250
export const WAIT_MIN_POLL_MS = 50

/**
 * The one wait arithmetic, used by *both* ends: the renderer runs its wait on
 * exactly this number, and main prices the verb's relay budget as this number
 * plus RELAY_HEADROOM_MS (see the waitFor entry in
 * src/plugins/browser/main/browserExternalControl.ts's table). Sharing the
 * clamp is what makes "the relay always outlives the wait" hold per request
 * rather than per verb — computing either side differently would reopen the
 * gap this constant block exists to close. Anything non-numeric (untyped wire
 * input) falls back to the default rather than the ceiling.
 */
export function clampWaitTimeout(requested?: unknown): number {
  if (typeof requested !== 'number' || !Number.isFinite(requested)) return WAIT_DEFAULT_TIMEOUT_MS
  return Math.min(WAIT_MAX_TIMEOUT_MS, Math.max(0, Math.round(requested)))
}

/**
 * How long an `assert`'s check may take end to end. Not a caller wait: the
 * in-guest check runs synchronously on injection, so a condition that holds
 * settles on the first look — this budget bounds the machinery around it (an
 * injection retried against a mid-load document, a navigation racing the
 * check, a contended machine), and is therefore how long a *failing* assert
 * takes to say so. A knowing consequence, kept deliberately: a condition that
 * arrives within this window passes — an assert is "holds now", with "now"
 * measured to this tolerance, the same auto-retrying stance Playwright's
 * expect takes. A literal one-shot was rejected because it loses a race it
 * shouldn't: injection latency on a busy machine would fail an assert whose
 * condition genuinely holds. Main prices the verb's relay budget from this
 * constant plus RELAY_HEADROOM_MS, the same derivation every waiting verb
 * uses (see BROWSER_CONTROL_VERBS).
 */
export const ASSERT_CHECK_BUDGET_MS = 1_000

/** `clampWaitTimeout`'s twin for the poll interval. */
export function clampWaitPoll(requested?: unknown): number {
  if (typeof requested !== 'number' || !Number.isFinite(requested)) return WAIT_DEFAULT_POLL_MS
  return Math.max(WAIT_MIN_POLL_MS, Math.round(requested))
}
