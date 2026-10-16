// Browser's UI tests drive active pages (docs/BROWSER.md, Testing). The app's workspace windows, which UI tests never
// show, then tell WebKit they are on screen and unoccluded: TABS_TEST_WINDOWS_SEEN, which Debug builds of the app
// honour (AppDelegate.windowsCountAsSeen) and Release builds don't contain. Set as this bundle loads into the app,
// before any test makes a window (the app reads it at each ask), so only this bundle's host process has it.
#include <stdlib.h>

__attribute__((constructor)) static void tabsTestWindowsSeen(void) {
    setenv("TABS_TEST_WINDOWS_SEEN", "1", 1);
}
