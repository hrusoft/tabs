/**
 * The generic content bridge: the one `window.api` surface content-type
 * packages speak IPC through, and the channel scheme behind it.
 *
 * A `contextBridge` surface is frozen at window construction, so a
 * per-type surface would be the one boundary a package structurally could
 * not extend — this generic one is core's forever, and a package's typed
 * client lives in the package instead (see e.g. the terminal's renderer
 * bridge), built over the type-scoped `ipc` its activation context carries.
 *
 * Channels are derived, never hand-named: `plugin:<type>:m:<method>` for
 * renderer-initiated calls (invoke and fire-and-forget alike) and
 * `plugin:<type>:e:<event>` for main-initiated events. The derivation is what
 * makes collisions between packages impossible by construction, and the
 * `plugin:` prefix is what keeps this surface off core's own channels — a
 * type name may not contain `:`, which `assertPluginTypeName` enforces at
 * every entry point that takes one. Event names *may* embed ids
 * (`data:<paneId>`), which is what keeps a per-pane stream on its own channel
 * instead of every listener filtering every pane's traffic.
 */

export interface ContentBridgeApi {
  /** Calls a method a package's main entry registered with `ipc.handle`. */
  invoke(type: string, method: string, ...args: unknown[]): Promise<unknown>
  /** Fire-and-forget to a method registered with `ipc.on`. */
  send(type: string, method: string, ...args: unknown[]): void
  /** Subscribes to a main-emitted event; returns the unsubscribe function. */
  on(type: string, event: string, listener: (...args: unknown[]) => void): () => void
}

export function assertPluginTypeName(type: string): void {
  if (type.length === 0 || type.includes(':')) {
    throw new Error(`invalid content-type name for the plugin bridge: "${type}"`)
  }
}

export function pluginMethodChannel(type: string, method: string): string {
  assertPluginTypeName(type)
  return `plugin:${type}:m:${method}`
}

export function pluginEventChannel(type: string, event: string): string {
  assertPluginTypeName(type)
  return `plugin:${type}:e:${event}`
}
