/**
 * A bounded, sequence-numbered log — the shape both capture buffers in the
 * external-control surface need (console messages in the renderer, network
 * metadata in main), which is why it lives here rather than in either.
 *
 * Two properties matter for how it's used:
 *
 * - **Bounded, and old entries are the ones that go.** A page in a redirect
 *   loop or a chatty `console.log` in a `setInterval` must not grow the
 *   buffer without limit, and what a caller wants when that happens is the
 *   most recent activity.
 * - **`seq` keeps increasing across eviction and is never reused.** That's
 *   what makes `sinceSeq` polling correct: a caller that read up to seq 40
 *   asks for everything after 40 and gets exactly the entries it hasn't seen,
 *   whether or not older ones have since been evicted. `clear()` (a new
 *   document) deliberately does *not* reset it, so a stale `sinceSeq` from
 *   the previous page returns the new page's entries rather than replaying
 *   everything.
 */
export interface Sequenced {
  seq: number
}

export interface RingLog<T extends Sequenced> {
  /**
   * Appends an entry, assigning it the next `seq`. Returns the stored object
   * so a caller can keep mutating it — the network log completes an in-flight
   * request this way. Mutating an entry that has since been evicted is
   * harmless: it is simply no longer in the log.
   */
  add: (entry: Omit<T, 'seq'>) => T
  /**
   * Removes the entry carrying `seq`, reporting whether it was still present.
   * `false` means it was already evicted, cleared, or never existed — the
   * network log's dedup reads that answer as "never merge into a ghost"; the
   * console log never removes.
   */
  remove: (seq: number) => boolean
  /** Drops every entry, e.g. because the pane started loading a new document. */
  clear: () => void
  /** Entries with `seq` greater than `sinceSeq`, oldest first. */
  list: (sinceSeq?: number) => T[]
}

export function createRingLog<T extends Sequenced>(capacity: number): RingLog<T> {
  let entries: T[] = []
  let nextSeq = 1

  return {
    add(entry) {
      const stored = { ...entry, seq: nextSeq++ } as T
      entries.push(stored)
      // Adds are one at a time, so at most one entry is ever over — shift()
      // avoids reallocating the whole buffer per add on a chatty page.
      if (entries.length > capacity) entries.shift()
      return stored
    },
    remove(seq) {
      const index = entries.findIndex((entry) => entry.seq === seq)
      if (index === -1) return false
      entries.splice(index, 1)
      return true
    },
    clear() {
      entries = []
    },
    list(sinceSeq) {
      return sinceSeq === undefined ? [...entries] : entries.filter((e) => e.seq > sinceSeq)
    }
  }
}

/**
 * Compiles a caller-supplied filter into a text predicate, so filtering a
 * whole log compiles the pattern once rather than per entry. Tried as a
 * regular expression first, falling back to a plain substring test when it
 * doesn't compile — a caller filtering for `console.log(` shouldn't have to
 * know it wrote an unbalanced group, and an error there would be far less
 * useful than the obvious interpretation.
 */
export function compilePattern(pattern?: string): (text: string) => boolean {
  if (!pattern) return () => true
  try {
    const regex = new RegExp(pattern)
    return (text) => regex.test(text)
  } catch {
    return (text) => text.includes(pattern)
  }
}

/**
 * Refusal message for a `--pattern` value that doesn't parse as a regular
 * expression, or `undefined` when it does (or is absent). Deliberately kept
 * separate from `compilePattern` rather than folded into it: that function's
 * silent substring fallback is a considered design (see its own comment) for
 * callers that want the "obvious interpretation" of a pattern that merely
 * contains stray regex punctuation. This is for the opposite case — a caller
 * whose flag should refuse an unparseable pattern outright rather than
 * silently searching for it as literal text (an unterminated `[` is a typo
 * far more often than it's an intentional literal). Both verbs that accept
 * `--pattern` (read-console, read-network) call this before ever reaching
 * `compilePattern`, so its fallback branch never fires for either.
 */
export function patternFilterError(pattern?: string): string | undefined {
  if (!pattern) return undefined
  try {
    new RegExp(pattern)
    return undefined
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    return `invalid --pattern regex ${JSON.stringify(pattern)}: ${detail}`
  }
}
