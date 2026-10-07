# Tabs. `make help` lists targets.
SHELL    := /bin/bash
XCODEGEN ?= mise exec xcodegen@2.46.0 -- xcodegen
CONFIG   ?= Debug
# How many lanes of test bundles run at once (Scripts/test-lanes.py).
LANES    ?= 4
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Tabs.app
DMG      := build/Tabs.dmg
SWIFT    := Sources Plugins Tests
# Each plugin's UI and end-to-end test targets (<Name>PluginUITests,
# <Name>PluginE2ETests), by the folders that hold them: Plugins/<Name>/Tests/{UI,E2E}.
PLUGIN_UI_TESTS  := $(foreach dir,$(wildcard Plugins/*/Tests/UI),$(word 2,$(subst /, ,$(dir)))PluginUITests)
PLUGIN_E2E_TESTS := $(foreach dir,$(wildcard Plugins/*/Tests/E2E),$(word 2,$(subst /, ,$(dir)))PluginE2ETests)
# xcodebuild for a scheme: $(call XCB,<scheme>)
XCB       = xcodebuild -project Tabs.xcodeproj -scheme $(1) -configuration $(CONFIG) \
            -derivedDataPath $(DERIVED) -destination 'platform=macOS' -skipPackagePluginValidation

.PHONY: help project build build-tests test test-verbose test-core test-plugins test-ui test-e2e verify verify-built lint warnings warnings-clean check-scaffold format check check-release bundle report run visual-baseline visual visual-golden clean

# Test runs never meet Oh My Zsh's update prompt: a shell started on someone's
# real dotfiles would take the first typed key as its answer.
check test test-verbose test-core test-plugins test-ui test-e2e check-scaffold: export DISABLE_AUTO_UPDATE := true
check test test-verbose test-core test-plugins test-ui test-e2e check-scaffold: export TEST_RUNNER_DISABLE_AUTO_UPDATE := true

help:
	@echo "check          everything a change must pass: lint + no warnings + every test + packaging gate + the scaffold (Debug), side by side"
	@echo "check-release  build Release (universal, optimized) and run the packaging gate on it"
	@echo "bundle         check-release, then the dmg ($(DMG))"
	@echo "test           every tier: core, plugins, app and UI, end to end; bundles in LANES=$(LANES) concurrent lanes"
	@echo "test-verbose   every tier, printing each test as it starts and finishes (for watching a run by hand)"
	@echo "test-core      core logic, unhosted; builds only the SDK and core (fastest)"
	@echo "test-plugins   every plugin's unit tests, unhosted; ONLY=TerminalPluginTests for one (or several, space-separated)"
	@echo "test-ui        the in-process UI tier: synthesized input against the real shell"
	@echo "test-e2e       the app as its own process, driven over the control socket"
	@echo "verify         build, then the packaging gate (Scripts/verify-app.sh)"
	@echo "verify-built   the packaging gate on the app the last build made, without building"
	@echo "lint           swift-format lint --strict (config: .swift-format), the plugin boundary lint, where tests keep their files, and the About window's generated config"
	@echo "warnings       build every target, tests included; fail on any warning standing in it"
	@echo "warnings-clean the same from a clean build of its own (make check-release)"
	@echo "check-scaffold Scripts/new-plugin.py's blank and content-type plugins, in a copy of the tree: lint, build, gate, their tests"
	@echo "format         swift-format in place"
	@echo "project        generate Tabs.xcodeproj from project.yml and every Plugins/*/plugin.yml"
	@echo "build          build Tabs.app ($(APP))"
	@echo "build-tests    build every target, tests included (what test and warnings share)"
	@echo "report         print the headless plugin report for the built app"
	@echo "run            build and launch the app with a scratch data directory"
	@echo "visual-baseline  render Visual/scenarios with the Debug build, as the baseline (before a change)"
	@echo "visual         render them again and compare with the baseline (build/visual/compare/index.html)"
	@echo "visual-golden  re-record the geometry goldens (Visual/golden) from the Debug build"

# Plugins are folders: their specs are gathered here, then XcodeGen runs only
# if something changed (the cache also notices added and removed files).
project:
	@mkdir -p build
	@Scripts/plugin-includes.sh > build/plugins.yml
	$(XCODEGEN) generate --spec project.yml --quiet --use-cache

build: project
	$(call XCB,Tabs) -quiet build

# Every target, tests included, built and nothing run. Its log is what
# warnings reads for the warnings no compiler wrote a .dia of (a script's).
build-tests: project
	set -o pipefail; $(call XCB,Tabs) -quiet build-for-testing 2>&1 | tee build/build-tests.log

# Every bundle, in concurrent lanes (Scripts/test-lanes.py says why); results in
# build/test-results.noindex.
test: build-tests
	Scripts/test-lanes.py --lanes $(LANES)

# Swift Testing's per-test lines (◇ started, ✔ passed, ✘ failed with its
# expectation) as they happen, one bundle after another. The build stays quiet:
# unquieted, its script phases print their whole environment.
test-verbose: build-tests
	$(call XCB,Tabs) test-without-building

test-core: project
	$(call XCB,Core) -quiet test

test-plugins: project
	$(call XCB,Plugins) -quiet test $(foreach test,$(ONLY),-only-testing:$(test))

test-ui: project
	$(call XCB,Tabs) -quiet test -only-testing:TabsAppTests/UITests $(foreach test,$(PLUGIN_UI_TESTS),-only-testing:$(test))

test-e2e: project
	$(call XCB,Tabs) -quiet test -only-testing:TabsEndToEndTests $(foreach test,$(PLUGIN_E2E_TESTS),-only-testing:$(test))

verify: build
	Scripts/verify-app.sh "$(APP)"

# check builds the app for its tests: the gate needs no build of its own.
verify-built:
	Scripts/verify-app.sh "$(APP)"

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT)
	Scripts/lint-plugin-boundaries.py
	Scripts/lint-test-files.py
	Scripts/sync-app-config.py --check

# What the last build left (Scripts/check-warnings.py says why that is every
# warning a clean build would print).
warnings: build-tests
	CONFIG=$(CONFIG) Scripts/check-warnings.py build/build-tests.log

# A clean build of its own: also the warnings of steps the last build didn't run
# again (an asset catalog, a script).
warnings-clean: project
	CONFIG=$(CONFIG) Scripts/check-warnings.py --clean

format:
	xcrun swift-format format --in-place --recursive $(SWIFT)

# A copy of the tree of its own (Scripts/check-scaffold.sh says why).
check-scaffold:
	CONFIG=$(CONFIG) Scripts/check-scaffold.sh

# Lint beside the build, then the tests beside the warnings check, the gate and
# the scaffold (Scripts/check.sh says why).
check:
	CONFIG=$(CONFIG) Scripts/check.sh $(LANES)

check-release: warnings-clean
	$(MAKE) verify CONFIG=Release

# What a release ships: the Release app, packaging gate passed, in a dmg.
bundle: check-release
	Scripts/make-dmg.sh "$(DERIVED)/Build/Products/Release/Tabs.app" "$(DMG)"

report: build
	TABS_DATA_DIR="$$(mktemp -d)" "$(APP)/Contents/MacOS/Tabs" --plugin-report

run: build
	TABS_DATA_DIR="$(CURDIR)/build/dev-data" "$(APP)/Contents/MacOS/Tabs"

# The look (Visual/README.md): the scenarios rendered by the Debug build.
# visual-baseline before a change, visual after it; ONLY="name …" for some.
visual-baseline: build
	Visual/capture.sh build/visual/baseline $(ONLY)

visual: build
	Visual/capture.sh build/visual/current $(ONLY)
	python3 Visual/compare.py $(ONLY)

# After an intended change to the chrome: the geometry GeometryGoldenTests holds.
visual-golden: build
	rm -rf build/visual/golden
	Visual/capture.sh build/visual/golden $(ONLY)
	Visual/golden.py build/visual/golden

clean:
	rm -rf build Tabs.xcodeproj
