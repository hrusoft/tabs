import type { ControlResponse, PluginControlRequest } from '../shared/externalControl'

/**
 * A verb handler as a package registers it: receives its own narrowed
 * request, returns the answer, never touches the transport (a throw becomes
 * the error response — content/externalControl.ts owns dispatch).
 *
 * Generic over both the verb name and the request union it narrows against,
 * so this one definition serves every caller: a plugin instantiates it with
 * its own concrete union (defaulting to the SDK's own `PluginControlRequest`,
 * the shape every plugin verb already satisfies), and core instantiates it
 * with its own `ControlRequest` for its six built-in verbs — one type, no
 * parallel core-side copy.
 */
export type ControlVerbHandler<
  V extends string,
  R extends { type: string } = PluginControlRequest
> = (request: Extract<R, { type: V }>) => ControlResponse | Promise<ControlResponse>

/**
 * Every verb of one content type's own request union, keyed by verb name —
 * the renderer's counterpart to the main-process `MainControlVerbTable`.
 * Annotate a package's table with its own union
 * (`RendererControlVerbTable<FooRequest>`) and the compiler enforces it
 * covers exactly that union's verbs: a verb added to the union without an
 * entry fails to build, and an entry naming a verb the union no longer has
 * fails too.
 *
 * This is what a bare `ControlVerbHandler<V>` (typed against a generic
 * catch-all request) cannot give a package: `Extract<PluginControlRequest,
 * { type: 'navigate' }>` resolves to `never` for any concrete verb, since
 * `PluginControlRequest` is a single open shape, not a literal union.
 * Narrowing against the package's own concrete union instead is exact.
 */
export type RendererControlVerbTable<R extends { type: string }> = {
  [V in R['type']]: (request: Extract<R, { type: V }>) => ControlResponse | Promise<ControlResponse>
}
