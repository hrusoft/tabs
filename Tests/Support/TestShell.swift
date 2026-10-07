import Foundation

/// Startup files for the shells tests start, in place of the user's: zsh
/// reads them from `ZDOTDIR` (only zsh does; any other `$SHELL` still reads
/// its own). A login shell then starts in milliseconds, and nothing the user
/// installed — a framework's update prompt eating the first typed key, a
/// prompt hook stalling a command — comes between a test and its shell.
///
/// One directory per test process. `.zprofile` exports `TABS_TEST_ZPROFILE=1`
/// and `.zshrc` sets `TABS_TEST_ZSHRC=1`, so a test can tell a login shell ran
/// both; `.zshrc` also unsets `HISTFILE` (`/etc/zshrc` points it into
/// `ZDOTDIR`): no test writes history anywhere.
///
/// The end-to-end tier keeps its own copy (Tests/EndToEndSupport), as it
/// compiles none of this folder's helpers but the socket client.
enum TestShell {
    /// What a pane's environment needs for its shell to start on these files.
    static var environment: [String: String] { ["ZDOTDIR": directory] }

    static let directory: String = {
        let url = TestTemporary.directory("test-shell")
        try! "export TABS_TEST_ZPROFILE=1\n".write(to: url.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        try! "TABS_TEST_ZSHRC=1\nunset HISTFILE\n".write(to: url.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        return url.path
    }()
}
