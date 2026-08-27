/**
 * The guest-side global names readPage parks its ref → element map under, and
 * the counter/capacity that discipline it. These are the *names of globals in
 * the guest page's main world*, not code that runs in any of our processes —
 * every consumer interpolates them into a script string.
 *
 * They live in `shared/` rather than beside the renderer scripts that mint them
 * because main reads the same registry: `save-resource` resolves a `--ref` to
 * an element's `src` by evaluating `window.<REF_REGISTRY>.get(ref)` in the
 * guest (see main/resourceFetch.ts). A second spelling of any of these on the
 * main side would be a ref namespace that silently never resolves — the exact
 * hazard the renderer's own scripts already share these constants to avoid.
 * The plugin-boundary ledger keeps a package's `shared/` importable from both
 * its `renderer/` and its `main/`, which is why this is the right home.
 *
 * `pageScripts.ts` re-exports all three, and `refResolverExpression` with them,
 * so the renderer keeps importing them from where it always has.
 */
export const REF_REGISTRY = '__tabsPageRefs'
export const REF_COUNTER = '__tabsPageRefSeq'

/** Refs retained per page before the oldest start dropping (a dropped ref fails like a stale one). */
export const REF_CAPACITY = 1000

/**
 * Guest expression resolving a readPage ref to its element, or null for a ref
 * the current page doesn't know — most often because it navigated since,
 * which drops the registry along with the rest of the old document's globals.
 *
 * The single spelling of the read, for the reason this module exists: both
 * processes resolve refs (the renderer's input verbs, main's `save-resource
 * --ref`), and two spellings could disagree about a ref the registry no longer
 * holds — with main's the copy nothing else exercises.
 *
 * This is the ref-shaped instance of `hitTestPointScript`'s resolver contract:
 * an expression evaluating to `Element | null | { error: string }`. A future
 * target shape (matching by role/name/selector) plugs in as its own resolver
 * expression and reuses the hit-test script unchanged; `{ error }` is how a
 * resolver reports a failure richer than "nothing matched" (say, an ambiguous
 * match) without the script knowing what kind of targeting produced it.
 */
export function refResolverExpression(ref: string): string {
  return `((window.${REF_REGISTRY} instanceof Map ? window.${REF_REGISTRY}.get(${JSON.stringify(ref)}) : null) ?? null)`
}
