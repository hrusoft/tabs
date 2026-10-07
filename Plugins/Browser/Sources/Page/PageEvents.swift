import Foundation

/// What a page tells whoever is listening (`BrowserPage.events`): the events
/// the header and the wait supervisor read, named for what they mean.
enum PageEvent: Equatable {
    case didStartLoading
    case didStopLoading
    /// A new main-frame document committed at this URL (a page, or the error
    /// page a failed load commits).
    case didNavigate(String)
    /// The same document moved to another URL (a `pushState`, a hash, a history
    /// step within the document).
    case didNavigateInPage(String)
    /// A main-frame load failed, by its `ERR_*` name.
    case didFailLoad(String)
    case titleDidChange
    /// The page is going away for good (its pane closed).
    case destroyed
}

/// A registration on `PageEvents`, ended by `cancel()`.
@MainActor
final class PageSubscription {
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}

/// A page's events, to any number of listeners, in the order they happened.
@MainActor
final class PageEvents {
    private var handlers: [(token: Int, handler: @MainActor (PageEvent) -> Void)] = []
    private var nextToken = 0

    @discardableResult
    func subscribe(_ handler: @escaping @MainActor (PageEvent) -> Void) -> PageSubscription {
        nextToken += 1
        let token = nextToken
        handlers.append((token, handler))
        return PageSubscription { [weak self] in self?.handlers.removeAll { $0.token == token } }
    }

    func emit(_ event: PageEvent) {
        for entry in handlers { entry.handler(event) }
    }

    /// How many listeners there are now: how a test sees that a host-side wait is listening.
    var listenerCount: Int { handlers.count }
}

/// A value decided exactly once by whichever of several racing sources gets
/// there first, and awaited once: the shape of "the page's answer, or the page
/// navigating, or the deadline". Later `resolve`s are ignored, which is what
/// lets a loser (a page evaluation a navigation orphaned for good) be simply
/// abandoned.
@MainActor
final class OneShot<Value: Sendable> {
    private var result: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Sleep, as an async call that a cancelled task cuts short.
func delay(milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}
