import type { RingLog, Sequenced } from '../../../shared/ringLog'
import { compilePattern, createRingLog, patternFilterError } from '../../../shared/ringLog'
import { NETWORK_BODY_MAX, NETWORK_LOG_CAPACITY } from '../shared/externalControl'

/**
 * Network metadata per guest `WebContents`, captured in main because that is
 * where `session.webRequest` lives (see browserGuestRegistry.ts, which owns
 * the Electron wiring and feeds this). Deliberately electron-free so the
 * parts worth getting right — eviction, redaction — are unit-testable on
 * their own.
 *
 * **Keyed by guest id, not pane id, and that is load-bearing.** A guest
 * starts fetching its document the instant it attaches, which is before the
 * renderer can tell main which pane the guest belongs to — keying by pane id
 * meant the main-frame request arrived unattributable and was dropped, so the
 * single most useful entry (the document, with its status code) was missing
 * from every freshly loaded pane while its sub-resources were captured fine.
 * Capturing against the id the request itself carries removes the race
 * entirely: attribution is only needed at *read* time, long after
 * registration has landed.
 *
 * Metadata always: method, URL, resource type, status, timings and headers.
 * Response *bodies* are opt-in per pane — `session.webRequest` never sees
 * them, so they arrive from a CDP session a caller explicitly asked for
 * (networkBodyCapture.ts) and are stored **out-of-line** from the metadata
 * ring, joined at read time by (method, url, status), newest first. The join
 * is by value rather than by id because the two capture paths share no key:
 * CDP's requestId and webRequest's details.id are different id spaces with no
 * bridge between them. The out-of-line store also keeps the two lifecycles
 * independent — eviction or dedup of metadata entries never has to carry a
 * body along, and a body whose entry was evicted simply never resurfaces.
 */
// The optional fields carry `| undefined` deliberately: entries are built by
// forwarding possibly-undefined values (an in-flight request has no status
// yet), and every path off this process is JSON, which drops the key either
// way — absent and explicitly-undefined are the same entry.
export interface NetworkEntry extends Sequenced {
  method: string
  url: string
  resourceType: string
  status?: number | undefined
  error?: string | undefined
  startedAt: number
  completedAt?: number | undefined
  requestHeaders?: Record<string, string> | undefined
  responseHeaders?: Record<string, string> | undefined
  /**
   * Present only on a collapsed entry (see dedupOnCompletion): how many
   * identical completions it stands for. Absent means one — an entry that
   * never merged keeps the exact wire shape it always had.
   */
  count?: number | undefined
  /**
   * When the collapsed run began. Every other field — `startedAt`,
   * `completedAt`, headers — describes the run's *latest* occurrence.
   */
  firstStartedAt?: number | undefined
  /** Attached only when a read asks `withBodies` and a captured body matches. */
  responseBody?: NetworkResponseBody | undefined
}

/**
 * What `withBodies` attaches to an entry. Truncation is explicit, never
 * silent — the same discipline getPageText and executeJavaScript follow:
 * `truncated` and the full `size` are always reported, so a caller knows what
 * it is missing (and that save-resource is the route to the whole thing).
 * `size` counts characters for text, decoded bytes for binary. A binary body
 * reports type and size only — base64 into the caller's context is worse than
 * useless, and the bytes belong to save-resource.
 */
export interface NetworkResponseBody {
  /** The body text, truncated at NETWORK_BODY_MAX characters. Absent for binary bodies. */
  body?: string
  truncated: boolean
  size: number
  mimeType?: string
  binary?: boolean
}

/**
 * How many captured bodies are retained per guest. Deliberately NOT
 * NETWORK_LOG_CAPACITY (the metadata ring's cap, which used to be this
 * store's too): at NETWORK_BODY_MAX per body, following the ring to 500
 * would let one guest hold ~8MB of body text where 100 bounds it at ~1.6MB —
 * and the flooding argument that raised the ring does not transfer, because
 * bodies are per-occurrence by design (dedup collapses metadata entries,
 * never bodies). The full-fidelity route to anything evicted is
 * save-resource.
 */
const BODY_CAPACITY = 100

/**
 * The other half of that bound, and the one that survives `--max-body`.
 *
 * A count alone bounds memory only while every body is the same size, which is
 * what it was until capture-bodies took a per-session limit: at
 * NETWORK_BODY_HARD_MAX the same BODY_CAPACITY entries are ~200MB of retained
 * string, per pane, held until the pane navigates or capture is turned off —
 * the count and the size multiply. Bounding characters too makes raising the
 * per-body cap *trade* body count for body size instead, so the ceiling stays
 * a constant here rather than something a caller sets.
 *
 * 4M characters is ~2.5x the old count-only ceiling, so a session capturing at
 * the default limit never evicts anything sooner than it used to.
 */
const BODY_CHAR_BUDGET = 4_000_000

/**
 * Headers stripped from both directions unless a caller explicitly opts out.
 *
 * These carry live credentials — a session cookie or bearer token read out of
 * a pane and into an agent's context is a credential leak, and the default
 * for a debugging aid should not be "hand over the session". Matched
 * case-insensitively because header casing is not normalized by anyone.
 */
const SENSITIVE_HEADERS = new Set(['authorization', 'cookie', 'set-cookie', 'proxy-authorization'])

/** Marker left in place of a stripped value, so a caller can see the header existed at all. */
export const REDACTED = '<redacted>'

/**
 * Replaces sensitive header values with `REDACTED`, keeping the header names.
 * A no-op when `unredacted` is set — the per-call opt-out for when the header
 * itself is what's being debugged.
 */
export function redactHeaders(
  headers: Record<string, string> | undefined,
  unredacted: boolean
): Record<string, string> | undefined {
  if (!headers || unredacted) return headers
  const result: Record<string, string> = {}
  for (const [name, value] of Object.entries(headers)) {
    result[name] = SENSITIVE_HEADERS.has(name.toLowerCase()) ? REDACTED : value
  }
  return result
}

/**
 * Per-guest capture state: the metadata ring plus the dedup index — the
 * latest entry per endpoint key (see dedupKey), which is the only thing a
 * completion is ever checked against for collapsing.
 */
interface GuestLog {
  log: RingLog<NetworkEntry>
  latestByKey: Map<string, NetworkEntry>
}

const guestLogs = new Map<number, GuestLog>()

/**
 * Captured response bodies per guest, oldest first, capped at BODY_CAPACITY
 * entries *and* BODY_CHAR_BUDGET characters (see their comments for why that
 * is two bounds, and why neither is the metadata ring's cap). Each carries the
 * join key its metadata entry will be matched on.
 */
interface CapturedBody {
  method: string
  url: string
  status?: number | undefined
  detail: NetworkResponseBody
}

const bodies = new Map<number, CapturedBody[]>()
/**
 * In-flight requests, so a completion event can find the entry its start
 * created. Each carries its guest id because eviction is per guest: a new
 * document in one pane must not drop another pane's pending completions —
 * request ids are session-global, but their lifecycles are not.
 */
const inFlight = new Map<number, { guestId: number; entry: NetworkEntry }>()

/**
 * Bound on the in-flight map — the same hazard networkBodyCapture's
 * PENDING_CAP guards, for the same reason: a long-lived page holding streams
 * open (long-polls, aborted requests whose error event never lands) grows it
 * without limit, each entry retaining a full NetworkEntry. Eviction is
 * oldest-first (Map insertion order); an evicted request that later
 * completes simply never gets its status filled in.
 */
const IN_FLIGHT_CAP = 500

function dropInFlightForGuest(guestId: number): void {
  for (const [requestId, flight] of inFlight) {
    if (flight.guestId === guestId) inFlight.delete(requestId)
  }
}

function guestLogFor(guestId: number): GuestLog {
  const existing = guestLogs.get(guestId)
  if (existing) return existing
  const created: GuestLog = {
    log: createRingLog<NetworkEntry>(NETWORK_LOG_CAPACITY),
    latestByKey: new Map()
  }
  guestLogs.set(guestId, created)
  return created
}

/**
 * Records a request starting. A top-level document request clears the guest's
 * log first, so the log always describes the page currently loaded rather
 * than accumulating across every page the guest has ever shown — and, because
 * the clear happens *before* this entry is added, the document request itself
 * survives as the log's first entry.
 */
export function recordRequestStart(
  guestId: number,
  requestId: number,
  entry: Omit<NetworkEntry, 'seq'>
): void {
  const guest = guestLogFor(guestId)
  if (entry.resourceType === 'mainFrame') {
    guest.log.clear()
    // Dedup runs never span documents: without this, the new page's first
    // request to an endpoint would try to merge into the old page's entry
    // (the remove() ghost-guard would refuse it, but the index would still
    // be pointing at entries the clear just destroyed).
    guest.latestByKey.clear()
    dropInFlightForGuest(guestId)
    // Bodies describe the page the log describes; a new document resets both.
    // The document's *own* body is safe: it is recorded on loadingFinished,
    // well after this start event.
    bodies.delete(guestId)
  }
  if (inFlight.size >= IN_FLIGHT_CAP) {
    const oldest = inFlight.keys().next().value
    if (oldest !== undefined) inFlight.delete(oldest)
  }
  inFlight.set(requestId, { guestId, entry: guest.log.add(entry) })
}

/**
 * Mime types whose bodies are worth inlining. Everything else is reported as
 * `binary` — type and size, no content.
 */
function isTextualMime(bare: string): boolean {
  return (
    bare.startsWith('text/') ||
    bare === 'application/json' ||
    bare === 'application/javascript' ||
    bare === 'application/xml' ||
    bare === 'application/x-www-form-urlencoded' ||
    bare.endsWith('+json') ||
    bare.endsWith('+xml')
  )
}

/** Decoded size of a base64 payload without allocating the decoded copy. */
function base64ByteLength(b64: string): number {
  const padding = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0
  return Math.floor((b64.length * 3) / 4) - padding
}

/**
 * Classifies and caps one captured body. Text (by mime type, or by CDP having
 * sent it as text when the type is unknown) is decoded if needed and truncated
 * at NETWORK_BODY_MAX characters with the full size kept; anything else keeps
 * only its type and decoded byte size. `receivedBytes` is the stream-level
 * count the CDP side summed from Network.dataReceived: for binary payloads,
 * `getResponseBody` frequently answers *empty* rather than erroring (the
 * bytes were piped to the renderer, not buffered — images, measured), so the
 * larger of the two is the honest size for a body whose content was never
 * going to be inlined anyway. For direct-piped bodies that count is itself
 * the wire-level sum (body plus transfer framing — see networkBodyCapture),
 * so a binary size is best-effort, not exact.
 */
function classifyBody(
  response: {
    mimeType?: string | undefined
    body: string
    base64Encoded: boolean
    receivedBytes?: number | undefined
  },
  limit: number
): NetworkResponseBody {
  const mimeType = response.mimeType?.split(';')[0]?.trim() || undefined
  const textual = mimeType ? isTextualMime(mimeType) : !response.base64Encoded
  if (!textual) {
    const buffered = response.base64Encoded ? base64ByteLength(response.body) : response.body.length
    const size = Math.max(buffered, response.receivedBytes ?? 0)
    return { truncated: false, size, ...(mimeType ? { mimeType } : {}), binary: true }
  }
  const text = response.base64Encoded
    ? Buffer.from(response.body, 'base64').toString('utf8')
    : response.body
  const truncated = text.length > limit
  return {
    // Copied through a Buffer, not just `slice`d: V8 answers `slice` with a
    // view onto the parent string, which keeps the *whole* decoded body alive
    // for as long as the 16KB excerpt is stored — the opposite of what the cap
    // is for. Measured: 50 excerpts of 5MB bodies retained 242MB as slices and
    // 9MB as copies. (`s.slice(0, n) + ''` does not flatten; a Buffer
    // round-trip does.) A cut landing mid-surrogate comes back as U+FFFD
    // rather than as a lone surrogate — the honest reading of a severed
    // excerpt either way.
    body: truncated ? Buffer.from(text.slice(0, limit), 'utf8').toString('utf8') : text,
    truncated,
    size: text.length,
    ...(mimeType ? { mimeType } : {})
  }
}

/**
 * Records a response body the CDP side captured (see networkBodyCapture.ts,
 * which calls this on `Network.loadingFinished` — the one reliable moment to
 * read a body). Stored against the join key, not against any metadata entry:
 * see the header for why the two stores share no id.
 */
export function recordResponseBody(
  guestId: number,
  response: {
    method: string
    url: string
    status?: number | undefined
    mimeType?: string | undefined
    body: string
    base64Encoded: boolean
    /** Stream-level byte count, the binary-size fallback — see classifyBody. */
    receivedBytes?: number | undefined
  }
): void {
  const list = bodies.get(guestId) ?? []
  list.push({
    method: response.method,
    url: response.url,
    status: response.status,
    detail: classifyBody(response, bodyLimitFor(guestId))
  })
  // Both bounds, whichever binds first — see BODY_CHAR_BUDGET. The last entry
  // is never evicted for size: a caller who raised --max-body specifically to
  // hold one large body would otherwise get an empty store back.
  let retained = list.reduce((sum, held) => sum + (held.detail.body?.length ?? 0), 0)
  while (list.length > BODY_CAPACITY || (retained > BODY_CHAR_BUDGET && list.length > 1)) {
    const dropped = list.shift()
    if (dropped === undefined) break
    retained -= dropped.detail.body?.length ?? 0
  }
  bodies.set(guestId, list)
}

/**
 * Per-guest retention caps, for the guests whose capture was started with an
 * explicit one. Absent means NETWORK_BODY_MAX.
 *
 * The cap has to be applied *at capture*, not at read, which is what makes it
 * a setting rather than a flag on the read: `classifyBody` copies the excerpt
 * through a Buffer precisely so the whole decoded body can be collected, and
 * relaxing that after the fact is not possible — the bytes are gone. Raising
 * it is therefore an explicit, per-pane opt-in to holding more in memory,
 * which is why the default is untouched and why the cost is stated where the
 * caller turns it on.
 */
const bodyLimits = new Map<number, number>()

function bodyLimitFor(guestId: number): number {
  return bodyLimits.get(guestId) ?? NETWORK_BODY_MAX
}

/**
 * Sets (or, with undefined, clears) how many characters of each response body
 * this guest retains from now on. Bodies already captured keep whatever cap
 * was in force when they arrived — there is nothing to re-expand.
 */
export function setBodyLimit(guestId: number, limit: number | undefined): void {
  if (limit === undefined) bodyLimits.delete(guestId)
  else bodyLimits.set(guestId, limit)
}

/**
 * What `--body-out` writes: one entry's captured body, or why it cannot.
 *
 * Read unredacted because nothing here looks at a header, and redaction is the
 * expensive half of a read — it clones both header maps for every entry in the
 * log to produce two objects this discards.
 */
export function findCapturedBody(
  guestId: number,
  seq: number
): { body: string } | { error: string } {
  const entries = listRequests(guestId, { withBodies: true, unredacted: true })
  const entry = entries.find((candidate) => candidate.seq === seq)
  if (!entry) {
    // Naming staleness rather than absence: a repeat of an endpoint's latest
    // entry collapses into it and *refreshes its seq* (see dedupOnCompletion),
    // so a seq a caller read a moment ago can legitimately no longer exist.
    // "No such request" would send them looking for a bug that isn't there.
    return {
      error: `no request with seq ${seq} in this pane's log — a repeated request collapses into its previous entry and takes a new seq, and the log resets on navigation, so re-read read-network and use the seq it reports now`
    }
  }
  const detail = entry.responseBody
  if (!detail) {
    return {
      error: `seq ${seq} (${entry.method} ${entry.url}) has no captured body — capture-bodies must be on *before* the response arrives, so turn it on and repeat the request`
    }
  }
  if (detail.binary === true) {
    return {
      error: `seq ${seq} is a binary body (${detail.mimeType ?? 'unknown type'}, ${detail.size} bytes) — Chromium hands those straight to the page and never buffers them, so use save-resource --url to fetch the bytes instead`
    }
  }
  return { body: detail.body ?? '' }
}

/**
 * Joins captured bodies onto the (already filtered, already cloned) entries a
 * read is about to return: newest entry takes the newest unclaimed body with
 * its (method, url, status), each body claimed at most once per read. Status
 * is part of the key so a poll loop's 200s and the failure's 500 never swap
 * bodies; the nth-occurrence pairing between identical requests is best
 * effort, which is the honest limit of a value join — and newest-first is
 * what makes a future dedup's "collapse to the latest entry" naturally keep
 * the latest body.
 */
function attachBodies(guestId: number, entries: NetworkEntry[]): void {
  const captured = bodies.get(guestId)
  if (!captured || captured.length === 0) return
  const claimed = new Set<number>()
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i]!
    for (let j = captured.length - 1; j >= 0; j--) {
      if (claimed.has(j)) continue
      const candidate = captured[j]!
      if (
        candidate.method === entry.method &&
        candidate.url === entry.url &&
        candidate.status === entry.status
      ) {
        claimed.add(j)
        entry.responseBody = candidate.detail
        break
      }
    }
  }
}

/**
 * Merges whatever a later event learned (headers, status, error) into the
 * entry. A patch that completes the request also runs the poll-loop dedup —
 * see dedupOnCompletion, which is only ever reachable from here.
 */
export function recordRequestUpdate(requestId: number, patch: Partial<NetworkEntry>): void {
  const flight = inFlight.get(requestId)
  if (!flight) return
  Object.assign(flight.entry, patch)
  if (patch.completedAt === undefined && patch.error === undefined) return
  inFlight.delete(requestId)
  dedupOnCompletion(flight.guestId, flight.entry)
}

/**
 * The identity a repeat is judged by. `resourceType` is part of it so a merge
 * can never blur what `--resource-type` filters on (a page's `<img>` and a
 * fetch of the same URL stay separate entries). Status and error are
 * deliberately *not* part of the key — they are compared against the
 * candidate instead, which is what keeps a transition unmerged (below).
 */
function dedupKey(entry: NetworkEntry): string {
  return `${entry.method} ${entry.resourceType} ${entry.url}`
}

function isCompleted(entry: NetworkEntry): boolean {
  return entry.completedAt !== undefined || entry.error !== undefined
}

/**
 * Collapses a poll loop without ever hiding a transition.
 *
 * A request completing identically to its endpoint's *latest* entry — same
 * dedupKey, same status, same error — merges into one entry carrying `count`
 * and `firstStartedAt`, every other field describing the newest occurrence.
 * The merge removes both halves and re-adds one entry rather than mutating in
 * place, which buys three things at once: it frees a buffer slot per repeat
 * (the point — a status poll stops evicting the POST that mattered), it moves
 * the entry to the tail so eviction still drops the least recently *active*,
 * and it assigns a fresh `seq`, so a `sinceSeq` poller sees the updated count
 * instead of repeats silently vanishing below its watermark.
 *
 * The rule that keeps transitions visible: only the endpoint's latest entry
 * is ever a merge candidate, and only on exact status **and** error equality.
 * A change starts a new entry, and a later return to the old status starts
 * another one — never a backwards merge — so `200 ×40, 404, 200` reads as
 * exactly three entries in true order. In-flight entries never merge (their
 * outcome isn't known yet), and a candidate the ring evicted is never merged
 * into: `remove()` answering false is that guard.
 */
function dedupOnCompletion(guestId: number, entry: NetworkEntry): void {
  const guest = guestLogs.get(guestId)
  if (!guest) return
  const key = dedupKey(entry)
  const candidate = guest.latestByKey.get(key)
  const identical =
    candidate !== undefined &&
    candidate !== entry &&
    isCompleted(candidate) &&
    candidate.status === entry.status &&
    candidate.error === entry.error
  if (identical && guest.log.remove(candidate.seq)) {
    guest.log.remove(entry.seq)
    const merged = guest.log.add({
      // add() assigns the fresh seq, overriding the stale one this spread
      // carries along with the latest occurrence's fields.
      ...entry,
      count: (candidate.count ?? 1) + 1,
      // Overlapping identical requests can complete out of start order, so
      // "when the run began" is the earliest start seen, not simply the
      // candidate's.
      firstStartedAt: Math.min(candidate.firstStartedAt ?? candidate.startedAt, entry.startedAt)
    })
    rememberCandidate(guest, key, merged)
    return
  }
  rememberCandidate(guest, key, entry)
}

/**
 * Records `entry` as the endpoint's latest merge candidate, bounded the way
 * the log itself is.
 *
 * The index is only reset by a main-frame navigation or the guest going away,
 * which is exactly the workload dedup exists for: a long-lived SPA polling
 * cache-busted URLs (`?t=<ts>`) makes every key distinct and never navigates,
 * so an unbounded index would retain one full entry — headers included — per
 * distinct URL, indefinitely. Capping it at the ring's own capacity costs
 * nothing real, because an evicted key just means "no merge" — the same answer
 * a ring-evicted candidate already gives (see `remove()` returning false).
 * Insertion order is eviction order, and re-setting an existing key deletes
 * first so a live endpoint stays young rather than ageing out mid-poll.
 */
function rememberCandidate(guest: GuestLog, key: string, entry: NetworkEntry): void {
  guest.latestByKey.delete(key)
  guest.latestByKey.set(key, entry)
  while (guest.latestByKey.size > NETWORK_LOG_CAPACITY) {
    const oldest = guest.latestByKey.keys().next().value
    if (oldest === undefined) break
    guest.latestByKey.delete(oldest)
  }
}

/** The read-time narrowing `listRequests` accepts. Every filter composes (AND). */
export interface NetworkReadOptions {
  pattern?: string | undefined
  sinceSeq?: number | undefined
  unredacted?: boolean | undefined
  withBodies?: boolean | undefined
  /**
   * A method in NETWORK_METHODS, compared case-insensitively. Anything else
   * matches nothing here — defensive only, since the verb refuses it (see
   * methodFilterError) before this module ever sees it.
   */
  method?: string | undefined
  /**
   * A spec parseStatusSpec understands. An unparsable one matches nothing —
   * defensive only, since the verb refuses it with the three forms named
   * (see statusFilterError) before this module ever sees it.
   */
  status?: string | undefined
  /** Failures only — see isFailure. */
  failed?: boolean | undefined
  /**
   * A type in NETWORK_RESOURCE_TYPES, compared exactly (Electron's own
   * values are exact-case). Anything else matches nothing here — defensive
   * only, since the verb refuses it (see resourceTypeFilterError) before
   * this module ever sees it.
   */
  resourceType?: string | undefined
}

/**
 * The HTTP methods a `--method` filter may ask for: the RFC 7231 set plus
 * PATCH (RFC 5789). An agent driving a pane has no legitimate reason to
 * filter for an exotic verb, so anything outside this list is refused (see
 * methodFilterError) rather than silently matching nothing. CONNECT and
 * TRACE never actually appear on a captured entry — both are forbidden
 * methods for `fetch`/`XMLHttpRequest`, so a page can never originate one —
 * but they stay in the accepted set for completeness: refusing a spec-legal
 * value that would just always match nothing is a worse trade than allowing
 * it.
 */
export const NETWORK_METHODS: readonly string[] = [
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'DELETE',
  'OPTIONS',
  'PATCH',
  'CONNECT',
  'TRACE'
]

/**
 * Electron's `session.webRequest` resourceType union (electron.d.ts, e.g.
 * `OnBeforeRequestListenerDetails`) — exactly the values `registerNetworkCapture`
 * (browserGuestRegistry.ts) stores on every entry, so this is a closed set
 * to validate against, not an illustrative one. There is no `fetch` or
 * `worker` value in this API: `fetch`/`XMLHttpRequest` traffic both report
 * as `xhr` (see resourceTypeFilterError's hint for that specific typo).
 */
export const NETWORK_RESOURCE_TYPES: readonly string[] = [
  'mainFrame',
  'subFrame',
  'stylesheet',
  'script',
  'image',
  'font',
  'object',
  'xhr',
  'ping',
  'cspReport',
  'media',
  'webSocket',
  'other'
]

/**
 * Parses a status filter: an exact code (`404`), a class (`4xx`), or an
 * inclusive range (`400-499`). Undefined for anything else, which the verb
 * turns into a refusal naming the three forms — silently matching nothing
 * would read as "no requests failed", a different claim entirely.
 */
export function parseStatusSpec(spec: string): { min: number; max: number } | undefined {
  if (/^\d{3}$/.test(spec)) {
    const status = Number(spec)
    return { min: status, max: status }
  }
  const statusClass = /^([1-5])xx$/i.exec(spec)
  if (statusClass) {
    const low = Number(statusClass[1]) * 100
    return { min: low, max: low + 99 }
  }
  const range = /^(\d{3})-(\d{3})$/.exec(spec)
  if (range) {
    const min = Number(range[1])
    const max = Number(range[2])
    return min <= max ? { min, max } : undefined
  }
  return undefined
}

/**
 * A finished failure: an errored request, or a completed one the server
 * answered 4xx/5xx. An in-flight entry is neither — it hasn't failed, it
 * hasn't succeeded, and `--failed` claiming it would be a guess.
 */
function isFailure(entry: NetworkEntry): boolean {
  return entry.error !== undefined || (entry.status !== undefined && entry.status >= 400)
}

/**
 * Refusal message for a `--method` outside NETWORK_METHODS, or undefined
 * when it's recognized. Every filter here refuses rather than fails open —
 * an empty result for a typo'd filter reads as "nothing matched" when the
 * real problem is the filter itself, and an agent has no legitimate query
 * for a method that cannot exist.
 */
export function methodFilterError(method: string): string | undefined {
  if (NETWORK_METHODS.includes(method.toUpperCase())) return undefined
  return `unrecognized method ${JSON.stringify(method)} — use one of ${NETWORK_METHODS.join(', ')}`
}

/**
 * Refusal message for a `--status` spec parseStatusSpec can't parse, or
 * undefined when it can.
 */
export function statusFilterError(status: string): string | undefined {
  if (parseStatusSpec(status) !== undefined) return undefined
  return `unrecognized status filter ${JSON.stringify(status)} — use an exact code (404), a class (4xx), or a range (400-499)`
}

/**
 * Refusal message for a `--resource-type` outside NETWORK_RESOURCE_TYPES, or
 * undefined when it's recognized. `fetch` gets a named hint rather than just
 * appearing in the accepted-values list: SKILL.md and tabs-ctl's own flag doc
 * already say "fetch reports as xhr", so a caller who read that and typed the
 * subject of the sentence rather than its object is the specific typo worth
 * calling out, not just any other unrecognized string.
 */
export function resourceTypeFilterError(resourceType: string): string | undefined {
  if (NETWORK_RESOURCE_TYPES.includes(resourceType)) return undefined
  const hint = resourceType.toLowerCase() === 'fetch' ? ' (fetch requests report as xhr)' : ''
  return `unrecognized resource type ${JSON.stringify(resourceType)}${hint} — use one of ${NETWORK_RESOURCE_TYPES.join(', ')}`
}

/**
 * Why a readNetworkRequests call's filters cannot run as given, or undefined
 * if they all can. Checked once, before any of them touch the log — the
 * single place the verb handler needs to call, so a caller with several bad
 * flags at once gets one clear reason rather than the request half-running.
 * `pattern`'s check (patternFilterError) lives in ringLog.ts, shared with
 * read-console's identical check on the same flag — see its own comment for
 * why an unparsable pattern is refused here rather than silently searched
 * for as literal text the way compilePattern's own fallback would.
 */
export function networkFilterError(options: {
  method?: string | undefined
  status?: string | undefined
  resourceType?: string | undefined
  pattern?: string | undefined
}): string | undefined {
  return (
    (options.method !== undefined ? methodFilterError(options.method) : undefined) ??
    (options.status !== undefined ? statusFilterError(options.status) : undefined) ??
    (options.resourceType !== undefined
      ? resourceTypeFilterError(options.resourceType)
      : undefined) ??
    (options.pattern !== undefined ? patternFilterError(options.pattern) : undefined)
  )
}

/**
 * A guest's captured requests, redacted unless `unredacted`, narrowed by the
 * read filters (URL pattern, `sinceSeq`, method, status, failed,
 * resourceType — all ANDed). `withBodies` joins captured response bodies onto
 * the returned copies (never onto the stored entries — the stores stay
 * independent). Bodies are deliberately *not* touched by `unredacted`: they
 * are gated by the double opt-in (capture-bodies + withBodies) instead, and
 * no content scrubbing is attempted — pretending to redact arbitrary JSON
 * would be worse than saying plainly that bodies come back whole.
 */
export function listRequests(
  guestId: number | undefined,
  options: NetworkReadOptions = {}
): NetworkEntry[] {
  if (guestId === undefined) return []
  const unredacted = options.unredacted === true
  const matches = compilePattern(options.pattern)
  const method = options.method?.toUpperCase()
  const statusRange = options.status === undefined ? undefined : parseStatusSpec(options.status)
  const entries = (guestLogs.get(guestId)?.log.list(options.sinceSeq) ?? [])
    .filter(
      (entry) =>
        matches(entry.url) &&
        (method === undefined || entry.method.toUpperCase() === method) &&
        (options.resourceType === undefined || entry.resourceType === options.resourceType) &&
        (options.failed !== true || isFailure(entry)) &&
        (options.status === undefined ||
          (statusRange !== undefined &&
            entry.status !== undefined &&
            entry.status >= statusRange.min &&
            entry.status <= statusRange.max))
    )
    .map((entry) => ({
      ...entry,
      requestHeaders: redactHeaders(entry.requestHeaders, unredacted),
      responseHeaders: redactHeaders(entry.responseHeaders, unredacted)
    }))
  if (options.withBodies === true) attachBodies(guestId, entries)
  return entries
}

/**
 * Drops a guest's log — its pane closed, or a structural reparent replaced it
 * with a new guest (see browserGuestRegistry.ts). Without this the old
 * guest's entries would be unreachable but still held.
 */
export function forgetGuestRequests(guestId: number): void {
  guestLogs.delete(guestId)
  bodies.delete(guestId)
  bodyLimits.delete(guestId)
  dropInFlightForGuest(guestId)
}

export function resetNetworkLogsForTests(): void {
  guestLogs.clear()
  bodies.clear()
  bodyLimits.clear()
  inFlight.clear()
}
