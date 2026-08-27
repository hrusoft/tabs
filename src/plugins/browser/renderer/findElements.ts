import type { PageElement } from '../shared/externalControl'

/**
 * Ranks `readPage`'s extracted elements against a plain-language description.
 *
 * Explicitly a heuristic — substring and token matching over the accessible
 * name, with small nudges from role and tag — not a model-backed semantic
 * search. It exists so a caller can say "the submit button" instead of
 * eyeballing a 200-element list, and it will happily miss an element whose
 * visible wording shares no tokens with the description. When precision
 * matters, read the list from `readPage` and pick a ref directly.
 *
 * Kept free of DOM and Electron on purpose: this is the one genuinely
 * fiddly piece of `find`, so it lives where a unit test can reach it.
 */

/** A match, carrying the element plus why it scored. Score is 0–1, higher is better. */
interface ElementMatch {
  element: PageElement
  score: number
}

const DEFAULT_MAX_RESULTS = 10

/** Words too common to carry signal — they'd otherwise let any element token-match anything. */
const STOP_WORDS = new Set(['the', 'a', 'an', 'of', 'for', 'to', 'on', 'in', 'and', 'or'])

function normalize(text: string): string {
  return text.toLowerCase().replace(/\s+/g, ' ').trim()
}

function tokenize(text: string): string[] {
  return normalize(text)
    .split(/[^a-z0-9]+/)
    .filter((token) => token.length > 0 && !STOP_WORDS.has(token))
}

/**
 * How well one element answers `description`, 0 (no match) to 1 (exact).
 *
 * The tiers are ordered by how much the match tells you: an exact name is
 * unambiguous, a prefix nearly so, a substring likely, and a scattering of
 * shared tokens only suggestive. Role and tag contribute a small bonus rather
 * than a tier of their own — "button" in a description usually qualifies a
 * name rather than replacing it.
 */
export function scoreElement(element: PageElement, description: string): number {
  const query = normalize(description)
  // An empty query matches nothing — which also means the comparisons below
  // need no guard for an element with an empty name, since none of them can
  // be true against a non-empty query.
  if (!query) return 0
  const name = normalize(element.name)
  const queryTokens = tokenize(description)

  let score = 0
  if (name === query) score = 1
  else if (name.startsWith(query)) score = 0.9
  else if (name.includes(query)) score = 0.75
  else if (queryTokens.length > 0) {
    const nameTokens = new Set(tokenize(element.name))
    const hits = queryTokens.filter((token) => nameTokens.has(token)).length
    if (hits > 0) score = 0.3 + 0.3 * (hits / queryTokens.length)
  }

  // A role or tag named in the description corroborates a weak name match,
  // but can't manufacture one on its own — otherwise "button" would return
  // every button on the page ranked above the one actually named.
  const corroborates =
    queryTokens.includes(normalize(element.role)) || queryTokens.includes(normalize(element.tag))
  if (score > 0 && corroborates) score = Math.min(1, score + 0.1)

  return score
}

/** The best `maxResults` matches for `description`, strongest first. Unmatched elements are dropped. */
export function findElements(
  elements: PageElement[],
  description: string,
  maxResults = DEFAULT_MAX_RESULTS
): ElementMatch[] {
  return elements
    .map((element) => ({ element, score: scoreElement(element, description) }))
    .filter((match) => match.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, Math.max(0, maxResults))
}
