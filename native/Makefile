# Native core/plugin prototype. `make help` lists targets.
XCODEGEN ?= mise exec xcodegen@2.46.0 -- xcodegen
CONFIG   ?= Debug
DERIVED  := build/DerivedData
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Tabs.app
DMG      := build/Tabs.dmg
SWIFT    := Sources Plugins Tests
# xcodebuild for a scheme: $(call XCB,<scheme>)
XCB       = xcodebuild -project Tabs.xcodeproj -scheme $(1) -configuration $(CONFIG) \
            -derivedDataPath $(DERIVED) -destination 'platform=macOS' -skipPackagePluginValidation

.PHONY: help project build test test-core test-plugins test-ui test-e2e verify lint warnings format check check-release bundle report run visual visual-electron visual-native clean

help:
	@echo "check          everything a change must pass: lint + no warnings + every test + packaging gate (Debug)"
	@echo "check-release  build Release (universal, optimized) and run the packaging gate on it"
	@echo "bundle         check-release, then the dmg ($(DMG))"
	@echo "test           every tier: core, plugins, app and UI, end to end"
	@echo "test-core      core logic, unhosted; builds only the SDK and core (fastest)"
	@echo "test-plugins   every plugin's unit tests, unhosted; ONLY=TerminalPluginTests for one"
	@echo "test-ui        the in-process UI tier: synthesized input against the real shell"
	@echo "test-e2e       the app as its own process, driven over the control socket"
	@echo "verify         build, then the packaging gate (Scripts/verify-app.sh)"
	@echo "lint           swift-format lint --strict (config: .swift-format), the plugin boundary lint, and the About window's generated config"
	@echo "warnings       a clean build of every target, tests included, that fails on any compiler or linker warning"
	@echo "format         swift-format in place"
	@echo "project        generate Tabs.xcodeproj from project.yml and every Plugins/*/plugin.yml"
	@echo "build          build Tabs.app ($(APP))"
	@echo "report         print the headless plugin report for the built app"
	@echo "run            build and launch the app with a scratch data directory"
	@echo "visual         render Visual/scenarios in both apps and compare them (build/visual/compare/index.html)"
	@echo "visual-electron  the Electron captures only (needs npm ci at the repository root)"
	@echo "visual-native  the native captures only (Debug build)"

# Plugins are folders: their specs are gathered here, then XcodeGen runs only
# if something changed (the cache also notices added and removed files). The
# version comes from the root package.json (Config/Base.xcconfig), rewritten
# only when it changes so an unchanged version re-signs nothing.
project:
	@mkdir -p build
	@Scripts/plugin-includes.sh > build/plugins.yml
	@Scripts/version-xcconfig.sh > build/Version.xcconfig.new
	@cmp -s build/Version.xcconfig.new build/Version.xcconfig \
	  && rm build/Version.xcconfig.new || mv build/Version.xcconfig.new build/Version.xcconfig
	$(XCODEGEN) generate --spec project.yml --quiet --use-cache

build: project
	$(call XCB,Tabs) -quiet build

test: project
	$(call XCB,Tabs) -quiet test

test-core: project
	$(call XCB,Core) -quiet test

test-plugins: project
	$(call XCB,Plugins) -quiet test $(if $(ONLY),-only-testing:$(ONLY))

test-ui: project
	$(call XCB,Tabs) -quiet test -only-testing:TabsAppTests/UITests

test-e2e: project
	$(call XCB,Tabs) -quiet test -only-testing:TabsEndToEndTests

verify: build
	Scripts/verify-app.sh "$(APP)"

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT)
	Scripts/lint-plugin-boundaries.py
	Scripts/sync-app-config.py --check

# A clean build of its own (Scripts/check-warnings.sh says why).
warnings: project
	CONFIG=$(CONFIG) Scripts/check-warnings.sh

format:
	xcrun swift-format format --in-place --recursive $(SWIFT)

check: lint warnings test verify

check-release:
	$(MAKE) verify CONFIG=Release

# What a release ships: the Release app, packaging gate passed, in a dmg.
bundle: check-release
	Scripts/make-dmg.sh "$(DERIVED)/Build/Products/Release/Tabs.app" "$(DMG)"

report: build
	TABS_DATA_DIR="$$(mktemp -d)" "$(APP)/Contents/MacOS/Tabs" --plugin-report

run: build
	TABS_DATA_DIR="$(CURDIR)/build/dev-data" "$(APP)/Contents/MacOS/Tabs"

# The look, against the Electron app (docs/LAYOUT.md). The Electron side is
# rendered by the repository's own renderer in headless Chromium.
visual-electron:
	node Visual/capture-electron.mjs $(ONLY)

visual-native: build
	Visual/capture-native.sh $(ONLY)

visual: visual-electron visual-native
	python3 Visual/compare.py $(ONLY)

clean:
	rm -rf build Tabs.xcodeproj
