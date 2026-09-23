import type { WebContents } from 'electron'

/**
 * Request/response into a renderer. Electron has no `webContents.invoke()`:
 * a request carries a `requestId`, the reply carries the same one, and this
 * matches the two. One instance per protocol; the caller wires the reply
 * channel to `resolve`, since where replies arrive is the protocol's business.
 *
 * A request settles once: on its reply, on its renderer crashing or
 * reloading (the document it went to is gone and will never answer), on
 * `refuse` (its window closed, a test reset), on a send that throws, or on
 * its optional timeout. Timeouts are opt-in because a
 * late reply is only sometimes harmless — external control times out so a
 * hung verb cannot hang the socket; the cross-window drag does not, since a
 * slow renderer still performs a request already sent (see
 * main/layoutCrossWindow.ts).
 */
interface RendererRelay<
  TRequest extends { requestId: string },
  TResponse extends { requestId: string }
> {
  /**
   * Sends `request` to `target`; resolves with its reply, or with `refused`
   * if the target is gone, crashes or reloads first, is later refused under
   * `owner`, or `timeoutMs` elapses. `R` narrows the reply to this request's
   * own kind — ids are unique per request, so nothing else can settle it.
   */
  send<R extends TResponse>(
    target: WebContents,
    owner: string,
    request: TRequest,
    refused: R,
    timeoutMs?: number
  ): Promise<R>
  /** Settles the request `response` answers; false when nothing was waiting for it. */
  resolve(response: TResponse): boolean
  /** Settles every request still waiting under `owner` (or every request, when omitted) with its own refusal. */
  refuse(owner?: string): void
}

export function createRendererRelay<
  TRequest extends { requestId: string },
  TResponse extends { requestId: string }
>(channel: string): RendererRelay<TRequest, TResponse> {
  interface Entry {
    owner: string
    refused: TResponse
    timer: ReturnType<typeof setTimeout> | undefined
    settle: (response: TResponse) => void
  }
  const pending = new Map<string, Entry>()

  function settle(requestId: string, response: TResponse): boolean {
    const entry = pending.get(requestId)
    if (!entry) return false
    pending.delete(requestId)
    if (entry.timer !== undefined) clearTimeout(entry.timer)
    entry.settle(response)
    return true
  }

  return {
    send(target, owner, request, refused, timeoutMs) {
      if (target.isDestroyed()) return Promise.resolve(refused)
      return new Promise((resolve) => {
        // `did-navigate` is main-frame only: a reload, never an in-page change.
        const gone = (): void => {
          settle(request.requestId, refused)
        }
        const timer =
          timeoutMs === undefined
            ? undefined
            : setTimeout(() => settle(request.requestId, refused), timeoutMs)
        pending.set(request.requestId, {
          owner,
          refused,
          timer,
          settle: (response) => {
            target.off('render-process-gone', gone)
            target.off('did-navigate', gone)
            // Sound by construction — see `send`'s doc on `R`.
            resolve(response as typeof refused)
          }
        })
        target.on('render-process-gone', gone)
        target.on('did-navigate', gone)
        // A send that throws never reaches the renderer, so nothing will
        // answer it: settle it here rather than reject with the entry left
        // pending for good.
        try {
          target.send(channel, request)
        } catch (error) {
          console.error('[tabs] could not relay a request into a renderer:', error)
          settle(request.requestId, refused)
        }
      })
    },
    resolve: (response) => settle(response.requestId, response),
    refuse(owner) {
      for (const [requestId, entry] of [...pending]) {
        if (owner === undefined || entry.owner === owner) settle(requestId, entry.refused)
      }
    }
  }
}
