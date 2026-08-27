/**
 * Core's content-neutral answer to "would closing this destroy live work?".
 * Content types register a provider here; core aggregates their blockers for
 * the two confirmation dialogs (pane/tab close and quit), which consume the
 * `CloseBlocker` shape. Deliberately Electron-free: the dialogs themselves,
 * their shared copy and their E2E_HIDDEN suppression live in closeDialogs.ts,
 * so this half — collecting what is still running — stays cycle-proof and
 * unit-testable.
 */

/** One thing still doing work — what the confirmation dialogs list. */
export interface CloseBlocker {
  command: string | undefined
}

export interface CloseBlockerProvider {
  /**
   * Blockers among `ids` (leaf ContentNode ids of the subtree being closed).
   * Ids the provider doesn't own must be ignored, not errors.
   */
  collectBlockers(ids: string[]): Promise<CloseBlocker[]>
  /**
   * Every blocker across this provider's own live resources, for quit. Must
   * come from the provider's registry, never a layout walk — the layout is a
   * forest, and a walk would miss floating panes — and must be fully
   * synchronous: it runs inside `before-quit`, whose no-async discipline is
   * documented in CLAUDE.md's before-quit gotcha.
   */
  listBlockersSync(): CloseBlocker[]
}

const providers = new Set<CloseBlockerProvider>()

/** Registers a content type's provider; returns its unregister function. */
export function registerCloseBlockerProvider(provider: CloseBlockerProvider): () => void {
  providers.add(provider)
  return () => providers.delete(provider)
}

/**
 * Subtree-close aggregation across every provider. A throwing provider
 * contributes nothing — fail open, the same "unknown = nothing to report"
 * rule as processProbe.ts.
 */
export async function collectCloseBlockers(ids: string[]): Promise<CloseBlocker[]> {
  const results = await Promise.all(
    [...providers].map(async (provider) => {
      try {
        return await provider.collectBlockers(ids)
      } catch {
        return []
      }
    })
  )
  return results.flat()
}

/**
 * Quit-time aggregation, synchronous throughout. Fails open like
 * collectCloseBlockers — a throw escaping into `before-quit` would skip the
 * settings flush and pty teardown that follow the dialog.
 */
export function listQuitBlockersSync(): CloseBlocker[] {
  const all: CloseBlocker[] = []
  for (const provider of providers) {
    try {
      all.push(...provider.listBlockersSync())
    } catch {
      // Fail open — see the doc comment.
    }
  }
  return all
}
