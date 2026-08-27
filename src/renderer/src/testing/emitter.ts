/**
 * The fake bridge's subscription primitive, shared by core's fake and each
 * content type's (see ./content/). Its own module only because those now live
 * in separate files.
 */
export class Emitter<T> {
  private listeners = new Set<(value: T) => void>()

  subscribe(callback: (value: T) => void): () => void {
    this.listeners.add(callback)
    return () => {
      this.listeners.delete(callback)
    }
  }

  emit(value: T): void {
    for (const callback of [...this.listeners]) callback(value)
  }
}
