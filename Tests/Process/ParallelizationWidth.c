// How many of this bundle's tests Swift Testing runs at once, when the scheme
// makes the bundle parallelizable: the target's TEST_PARALLELIZATION_WIDTH
// build setting (project.yml, a plugin's plugin.yml). 0, the default, leaves
// Swift Testing's own, which starts every test of the bundle at once: fine for
// tests that wait off the main thread, not for a bundle whose tests all need it
// (Browser's, on WebKit), which queued there for seconds, past every budget.
//
// Set as the bundle loads, before Swift Testing reads its configuration; a
// width given to the run wins (TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH
// for xcodebuild). A scheme can't do this: its environment is every bundle's.
// The variable is experimental, as its name says: a Swift Testing that stops
// reading it ignores it without a word.

#include <stdlib.h>

#if defined(TABS_TEST_PARALLELIZATION_WIDTH) && TABS_TEST_PARALLELIZATION_WIDTH > 0
#define TABS_STRING(value) #value
#define TABS_DECIMAL(value) TABS_STRING(value)

__attribute__((constructor)) static void limitParallelizationWidth(void) {
    setenv("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH", TABS_DECIMAL(TABS_TEST_PARALLELIZATION_WIDTH), 0);
}
#endif
