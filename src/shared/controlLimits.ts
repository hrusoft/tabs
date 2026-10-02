/**
 * `MAX_BATCH_SIZE` on its own, leaf module — no further imports, so anything
 * that needs just this one number (core's own `ControlVerbSpec` for `batch`,
 * `src/shared/coreControlSpec.ts`) doesn't have to pull in the rest of
 * `externalControl.ts`, which imports the content-type census
 * (`CONTENT_TYPE_MANIFESTS`) at module scope and throws outside a Vite-built
 * context (see `content/registry.ts`'s `loadManifestModules`). A plain
 * bundled script (this repo's `esbuild`-based doc-comparison tooling
 * included) can import this constant without tripping that guard.
 * `externalControl.ts` re-exports it rather than defining it, so its own
 * existing importers see no change.
 */
export const MAX_BATCH_SIZE = 50
