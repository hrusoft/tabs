import type { NodeId } from './types'

export function createId(): NodeId {
  return crypto.randomUUID()
}
