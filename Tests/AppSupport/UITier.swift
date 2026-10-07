import Testing

/// The in-process UI tier: the real shell, the bundled plugins and the real
/// main menu, driven by synthesized clicks, drags, typing and shortcuts in
/// windows that are never shown. What a user does, and what they'd see.
///
/// Serialized, with every suite that drives windows nested inside it
/// (`extension UITests`), in core's tier and in each plugin's: a drag or a
/// resize runs a nested run loop, where another test must not start and post
/// input of its own.
@MainActor
@Suite(.serialized) struct UITests {}
