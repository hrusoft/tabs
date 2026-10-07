import Foundation

/// Startup files for the launched app's shells, in place of the user's: zsh
/// reads them from `ZDOTDIR`, which `LaunchedApp` sets by default (a test can
/// launch without it: `removingEnvironment: ["ZDOTDIR"]`). Only zsh reads
/// `ZDOTDIR`; any other `$SHELL` still reads its own files.
///
/// One directory per test process. `.zprofile` exports `TABS_TEST_ZPROFILE=1`
/// and `.zshrc` sets `TABS_TEST_ZSHRC=1`; `.zshrc` also unsets `HISTFILE`
/// (`/etc/zshrc` points it into `ZDOTDIR`): no test writes history anywhere.
///
/// The end-to-end tier's copy of Tests/Support/TestShell.swift (it compiles
/// none of that folder's helpers but the socket client): keep the two alike.
enum TestShell {
    static let directory: String = {
        let url = TestTemporary.directory("test-shell")
        try! "export TABS_TEST_ZPROFILE=1\n".write(to: url.appending(path: ".zprofile"), atomically: true, encoding: .utf8)
        try! "TABS_TEST_ZSHRC=1\nunset HISTFILE\n".write(to: url.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        return url.path
    }()
}
