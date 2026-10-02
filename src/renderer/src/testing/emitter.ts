/**
 * The fake bridges' subscription primitive, shared by core's fake bridge
 * (./fakeApi.ts) and the fake content bridge (./content/). Test-harness
 * surface only: a package's own fake never sees it, emitting through the
 * `FakeContentHost` it is handed instead.
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
