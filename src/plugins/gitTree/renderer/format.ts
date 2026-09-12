/** A hash as it reads in conversation — the first seven characters, everywhere this package abbreviates one. */
export function shortHash(hash: string): string {
  return hash.slice(0, 7)
}
