import { net, type WebContents } from 'electron'
import { MAX_RESOURCE_BYTES } from '../shared/externalControl'
import { refResolverExpression } from '../shared/pageRefs'
import { acquireGuestDebugger } from './guestDebugger'
import { isAllowedResourceUrl } from './urlPolicy'

/**
 * `save-resource`'s fetch half: turning a `blob:`/`data:`/`http(s):` URL — or
 * an element's `src` — into bytes on the main side, where the routes that beat
 * a page's CSP live. Three routes, one per scheme, each measured against a
 * strict `connect-src 'self'` page during the spike that chose this design:
 *
 * - **`http`/`https`** → a main-process `net.request` on the *guest's* session
 *   (so its cookies ride along). Because it is main-initiated, not a page
 *   fetch, it is subject to neither the page's CSP nor CORS nor ORB — it
 *   retrieves any origin, which is what makes "save this CDN image" work where
 *   an in-page `fetch` cannot.
 * - **`blob`** → two complementary routes, tried in order (see
 *   fetchBlobResource): CDP `Page.getResourceContent` over the shared debugger
 *   session (guestDebugger.ts) — the only route that returned a *loaded*
 *   blob's bytes under `connect-src 'self'`; every in-page/isolated-world/
 *   universal-world `fetch` failed there, and neither `Page.setBypassCSP` nor
 *   `Network.loadNetworkResource` lifts that CSP — then a main-world fetch
 *   inside the guest, for the blobs the resource tree structurally cannot see
 *   (minted but never loaded, or anything on a null origin).
 * - **`data`** → decoded in main directly; no guest round trip.
 *
 * The scheme allowlist (`isAllowedResourceUrl`) is re-checked here on the URL
 * actually about to be read — including one resolved from an element's `src`,
 * where a hostile attribute could hold `file:` and the http(s) route's
 * `net.request` would otherwise happily read a local file.
 */

export interface FetchedResource {
  bytes: Uint8Array
  /** From the response/mediatype when the route knows it; drives extension inference. */
  contentType?: string | undefined
}

type FetchOutcome = FetchedResource | { error: string }

/**
 * Resolves an element (`ref` from a prior readPage, or a CSS `selector`) to the
 * URL of what it points at — `src`/`currentSrc`/`href`/`data`. Runs in the
 * guest's main world, the same world readPage's ref registry lives in, so a
 * ref resolves against exactly the map that minted it.
 */
export async function resolveElementSrc(
  guest: WebContents,
  target: { ref?: string | undefined; selector?: string | undefined }
): Promise<{ url: string } | { error: string }> {
  const finder =
    target.ref !== undefined
      ? refResolverExpression(target.ref)
      : `document.querySelector(${JSON.stringify(target.selector)})`
  const script = `(() => {
    let el
    try { el = ${finder} } catch (e) { return { error: 'invalid selector: ' + (e && e.message) } }
    if (!el) return { error: 'no element found for the given ${target.ref !== undefined ? 'ref' : 'selector'}' }
    const url = el.currentSrc || el.src || el.href || el.data ||
      el.getAttribute?.('src') || el.getAttribute?.('href') || ''
    if (!url) return { error: 'the element has no src/href to save' }
    return { url: String(url) }
  })()`
  let raw: unknown
  try {
    raw = await guest.executeJavaScript(script)
  } catch (error) {
    return { error: `could not read the element: ${String(error)}` }
  }
  if (raw && typeof raw === 'object' && 'error' in raw) {
    return { error: String((raw as { error: unknown }).error) }
  }
  if (raw && typeof raw === 'object' && 'url' in raw) {
    return { url: String((raw as { url: unknown }).url) }
  }
  return { error: 'could not resolve the element to a URL' }
}

/** Fetches `url` by the route its scheme dictates, or returns a caller-facing error. */
export async function fetchResource(guest: WebContents, url: string): Promise<FetchOutcome> {
  if (!isAllowedResourceUrl(url)) {
    return {
      error: `url not allowed: ${url} (save-resource reads http, https, blob and data URLs)`
    }
  }
  let protocol: string
  try {
    protocol = new URL(url).protocol
  } catch {
    return { error: `not a valid URL: ${url}` }
  }
  if (protocol === 'data:') return decodeDataUrl(url)
  if (protocol === 'blob:') return fetchBlobResource(guest, url)
  return fetchHttpResource(guest, url)
}

/** `data:[<mediatype>][;base64],<data>` decoded in main; no guest involved. Exported for its unit test. */
export function decodeDataUrl(url: string): FetchOutcome {
  const comma = url.indexOf(',')
  if (comma === -1) return { error: 'malformed data: URL' }
  const meta = url.slice(5, comma)
  const isBase64 = /;base64$/i.test(meta)
  const mediatype = (isBase64 ? meta.replace(/;base64$/i, '') : meta).split(';')[0] || undefined
  const payload = url.slice(comma + 1)
  let bytes: Uint8Array
  try {
    bytes = isBase64
      ? new Uint8Array(Buffer.from(payload, 'base64'))
      : new Uint8Array(Buffer.from(decodeURIComponent(payload), 'utf8'))
  } catch (error) {
    return { error: `could not decode data: URL: ${String(error)}` }
  }
  if (bytes.byteLength > MAX_RESOURCE_BYTES) return tooLarge(bytes.byteLength)
  return { bytes, contentType: mediatype }
}

/**
 * A `blob:` resource, by two complementary routes — because "a blob URL" is
 * really two different situations, measured separately:
 *
 * 1. **CDP `Page.getResourceContent`** finds a blob that was *loaded* as a
 *    frame's document (the embedded-PDF-viewer incident) on a real http(s)
 *    origin, and does so with no fetch at all — which is what makes it immune
 *    to the page's CSP, the case this verb was built for. But it reads the
 *    frame's resource tree, and a blob merely minted by `createObjectURL` is
 *    not in any resource tree; nor, measured directly, is a `blob:null/…`
 *    loaded into an iframe on an `about:blank` page (the child frame lists
 *    zero resources). "No resource with given URL found" therefore does not
 *    mean the blob is gone — a page-world fetch of it can still succeed.
 * 2. **A main-world fetch inside the guest** (base64'd back) covers exactly
 *    the blobs route 1 cannot see — unloaded ones, and anything on a null
 *    origin — wherever the page's own CSP permits a blob fetch, which is
 *    everywhere except a page with a restrictive `connect-src`.
 *
 * Tried in that order (1 is CSP-proof and unobservable by the page), and only
 * when *both* fail does the caller get an error — one that names both
 * failures, because "no longer available" alone sent a caller whose blob was
 * alive the whole time chasing revocation. A debugger that cannot attach
 * (DevTools open on the guest) skips route 1 rather than failing the verb.
 *
 * The lease is released whatever happens, so a transient blob save never
 * detaches a persistent network-body session (refcounted).
 */
async function fetchBlobResource(guest: WebContents, url: string): Promise<FetchOutcome> {
  const fromTree = await blobFromResourceTree(guest, url)
  if ('bytes' in fromTree) {
    if (fromTree.bytes.byteLength > MAX_RESOURCE_BYTES) return tooLarge(fromTree.bytes.byteLength)
    return fromTree
  }
  const fetched = await blobViaGuestFetch(guest, url)
  if ('bytes' in fetched) return fetched
  if ('tooLargeBytes' in fetched) return tooLarge(fetched.tooLargeBytes)
  return {
    error:
      `the blob could not be read by either route: it is not among the page's loaded resources` +
      ` (${fromTree.error}), and fetching it inside the page failed (${fetched.error})` +
      ` — a page CSP with a restrictive connect-src blocks blob fetches, and a revoked` +
      ` blob URL is gone entirely`
  }
}

/** Route 1: the frame resource tree, over the shared CDP session. */
async function blobFromResourceTree(
  guest: WebContents,
  url: string
): Promise<FetchedResource | { error: string }> {
  let lease: Awaited<ReturnType<typeof acquireGuestDebugger>>
  try {
    lease = await acquireGuestDebugger(guest)
  } catch (error) {
    return { error: String(error instanceof Error ? error.message : error) }
  }
  try {
    await lease.send('Page.enable')
    const tree = (await lease.send('Page.getFrameTree')) as {
      frameTree: { frame: { id: string }; childFrames?: { frame: { id: string } }[] }
    }
    const frameIds = [
      tree.frameTree.frame.id,
      ...(tree.frameTree.childFrames ?? []).map((child) => child.frame.id)
    ]
    let lastError = 'not found in any frame'
    for (const frameId of frameIds) {
      try {
        const content = (await lease.send('Page.getResourceContent', { frameId, url })) as {
          content: string
          base64Encoded: boolean
        }
        return {
          bytes: new Uint8Array(
            Buffer.from(content.content, content.base64Encoded ? 'base64' : 'utf8')
          )
        }
      } catch (error) {
        // Not in this frame's resource tree — try the next.
        lastError = error instanceof Error ? error.message : String(error)
      }
    }
    return { error: lastError }
  } catch (error) {
    return { error: String(error) }
  } finally {
    lease.release()
  }
}

/**
 * Route 2: a fetch in the guest's own main world, bytes base64'd back. The
 * size cap is checked inside the guest against `blob.size` *before* encoding,
 * so an oversized blob costs no giant string. Runs in the page's main world —
 * observable there, like every executeJavaScript-based verb; the boundary is
 * pane ownership, not the page (see pageScripts.ts).
 */
async function blobViaGuestFetch(
  guest: WebContents,
  url: string
): Promise<FetchedResource | { error: string } | { tooLargeBytes: number }> {
  const script = `(async () => {
    try {
      const response = await fetch(${JSON.stringify(url)})
      const blob = await response.blob()
      if (blob.size > ${MAX_RESOURCE_BYTES}) return { tooLargeBytes: blob.size }
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
  })()`
  let raw: unknown
  try {
    raw = await guest.executeJavaScript(script)
  } catch (error) {
    return { error: `could not run the fetch in the page: ${String(error)}` }
  }
  if (raw && typeof raw === 'object' && 'tooLargeBytes' in raw) {
    return { tooLargeBytes: Number((raw as { tooLargeBytes: unknown }).tooLargeBytes) }
  }
  if (raw && typeof raw === 'object' && 'b64' in raw) {
    const value = raw as { b64: string; type: string | null }
    return {
      bytes: new Uint8Array(Buffer.from(value.b64, 'base64')),
      contentType: value.type ?? undefined
    }
  }
  const message =
    raw && typeof raw === 'object' && 'error' in raw
      ? String((raw as { error: unknown }).error)
      : 'the page returned no data'
  return { error: message }
}

/**
 * An `http`/`https` resource via main's `net.request` on the guest's session.
 * Streams with a running byte cap so a runaway body is aborted mid-flight
 * rather than buffered whole and rejected after.
 */
function fetchHttpResource(guest: WebContents, url: string): Promise<FetchOutcome> {
  return new Promise((resolve) => {
    const request = net.request({ url, session: guest.session, useSessionCookies: true })
    const chunks: Buffer[] = []
    let total = 0
    let aborted = false
    request.on('response', (response) => {
      const status = response.statusCode
      if (status >= 400) {
        aborted = true
        request.abort()
        resolve({ error: `the resource returned HTTP ${status}` })
        return
      }
      const contentType = (
        Array.isArray(response.headers['content-type'])
          ? response.headers['content-type'][0]
          : response.headers['content-type']
      )?.split(';')[0]
      response.on('data', (chunk: Buffer) => {
        if (aborted) return
        total += chunk.byteLength
        if (total > MAX_RESOURCE_BYTES) {
          aborted = true
          request.abort()
          resolve(tooLarge(total))
          return
        }
        chunks.push(chunk)
      })
      response.on('end', () => {
        if (aborted) return
        resolve({ bytes: new Uint8Array(Buffer.concat(chunks)), contentType })
      })
      response.on('error', (error: Error) => {
        if (aborted) return
        aborted = true
        resolve({ error: `could not read the resource: ${error.message}` })
      })
    })
    request.on('error', (error) => {
      if (aborted) return
      aborted = true
      resolve({ error: `could not fetch the resource: ${error.message}` })
    })
    request.end()
  })
}

function tooLarge(bytes: number): { error: string } {
  const mb = (n: number): string => `${(n / (1024 * 1024)).toFixed(1)}MB`
  return {
    error: `resource is too large to save (${mb(bytes)}; the cap is ${mb(MAX_RESOURCE_BYTES)})`
  }
}

const CONTENT_TYPE_EXT: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
  'image/bmp': 'bmp',
  'application/pdf': 'pdf',
  'application/json': 'json',
  'application/zip': 'zip',
  'application/javascript': 'js',
  'text/javascript': 'js',
  'text/html': 'html',
  'text/css': 'css',
  'text/plain': 'txt',
  'text/csv': 'csv'
}

/**
 * Picks a file extension for a generated name: the content type when a route
 * knows it, else a magic-byte sniff (so a blob whose type CDP doesn't report
 * still lands as `.pdf`/`.png`/…), else the URL path's own extension, else
 * `bin`. A wrong extension is cosmetic — the caller's file reader sniffs
 * content — but a right one saves it a guess.
 */
export function extensionFor(
  url: string,
  contentType: string | undefined,
  bytes: Uint8Array
): string {
  const fromType = contentType && CONTENT_TYPE_EXT[contentType.toLowerCase()]
  if (fromType) {
    return fromType
  }
  const sniffed = sniffExtension(bytes)
  if (sniffed) return sniffed
  try {
    const path = new URL(url).pathname
    const dot = path.lastIndexOf('.')
    if (dot !== -1 && dot > path.lastIndexOf('/')) {
      const ext = path.slice(dot + 1).toLowerCase()
      if (/^[a-z0-9]{1,8}$/.test(ext)) return ext
    }
  } catch {
    // blob:/data: have no useful pathname — fall through.
  }
  return 'bin'
}

/** Magic-byte sniff for the handful of artifact types agents actually save. */
function sniffExtension(bytes: Uint8Array): string | undefined {
  const starts = (...sig: number[]): boolean => sig.every((b, i) => bytes[i] === b)
  if (starts(0x25, 0x50, 0x44, 0x46)) return 'pdf' // %PDF
  if (starts(0x89, 0x50, 0x4e, 0x47)) return 'png' // \x89PNG
  if (starts(0xff, 0xd8, 0xff)) return 'jpg'
  if (starts(0x47, 0x49, 0x46, 0x38)) return 'gif' // GIF8
  if (starts(0x50, 0x4b, 0x03, 0x04)) return 'zip' // PK..
  if (
    starts(0x52, 0x49, 0x46, 0x46) &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return 'webp' // RIFF....WEBP
  }
  return undefined
}
