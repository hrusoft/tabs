#!/usr/bin/env python3
"""Scaffold a new plugin: a folder, and nothing else to edit.

    Scripts/new-plugin.py <id> [--name Name] [--content-type]

Creates Plugins/<Name>/:
    Info.plist           the manifest (TabsPlugin) and principal class
    Sources/<Name>Plugin.swift
    Tests/<Name>PluginTests.swift   unit tests against the real core (PluginHarness)
    plugin.yml           its bundle, its test target, its place in the app

`make project` picks the folder up (every Plugins/*/plugin.yml is included),
so no shared file changes. With --content-type the plugin declares and
registers a content type named after its id, with a minimal pane.

Then run `make check`.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    sys.exit(f"new-plugin: {message}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("id", help="plugin id: lowercase letters, digits and dashes (e.g. git-tree)")
    parser.add_argument("--name", help="type-name stem (default: the id in UpperCamelCase)")
    parser.add_argument("--content-type", action="store_true", help="declare and register a content type named <id>")
    args = parser.parse_args()

    plugin_id = args.id
    if not re.fullmatch(r"[a-z][a-z0-9-]*", plugin_id) or plugin_id in {"tabs", "core", "sdk"}:
        fail(f'"{plugin_id}" is not a valid plugin id (lowercase letters, digits, dashes; not tabs/core/sdk)')
    name = args.name or "".join(part.capitalize() for part in plugin_id.split("-"))
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name):
        fail(f'"{name}" is not a valid type name')
    target = f"{name}Plugin"
    display = " ".join(part.capitalize() for part in plugin_id.split("-"))

    directory = ROOT / "Plugins" / name
    if directory.exists():
        fail(f"{directory.relative_to(ROOT)} already exists")
    # Every plugin (test fixtures included) owns its id: the bundle's name.
    for spec in [ROOT / "project.yml", *ROOT.glob("Plugins/*/plugin.yml")]:
        if re.search(rf"pluginID:\s*{re.escape(plugin_id)}\s*[,}}]", spec.read_text()):
            fail(f"{spec.relative_to(ROOT)} already uses plugin id {plugin_id}")
        if re.search(rf"^  {target}:\s*$", spec.read_text(), re.M):
            fail(f"{spec.relative_to(ROOT)} already has a target {target}")

    (directory / "Sources").mkdir(parents=True)
    (directory / "Tests").mkdir()
    (directory / "Info.plist").write_text(info_plist(plugin_id, display, target, args.content_type))
    (directory / "Sources" / f"{target}.swift").write_text(entry_class(plugin_id, display, target, args.content_type))
    (directory / "Tests" / f"{target}Tests.swift").write_text(tests(plugin_id, display, target, args.content_type))
    (directory / "plugin.yml").write_text(plugin_spec(plugin_id, name, target))

    print(f"created Plugins/{name}/ ({target}, {target}Tests)")
    print("next: make project && make check")


def plugin_spec(plugin_id: str, name: str, target: str) -> str:
    key = plugin_id.upper().replace("-", "_")
    return f"""# The {name} plugin: its bundle, its unit tests, and its place in the app.
# `make project` includes this file; nothing else in the build names it.
targets:
  {target}:
    templates: [Plugin]
    templateAttributes: {{ pluginID: {plugin_id}, pluginDir: Plugins/{name} }}
  {target}Tests:
    templates: [PluginTests]
    templateAttributes: {{ pluginDir: Plugins/{name} }}
  Tabs:
    dependencies:
      - target: {target}
        link: false
        embed: true
        copy: {{ destination: plugins }}
    settings:
      base:
        TABS_BUNDLED_PLUGIN_{key}: {plugin_id}
schemes:
  Tabs:
    test:
      targets: [{target}Tests]
  Plugins:
    test:
      targets: [{target}Tests]
"""


def tests(plugin_id: str, display: str, target: str, content_type: bool) -> str:
    pane_test = (
        f"""

    @Test func opensAPane() throws {{
        let pane = try #require(harness.open("{plugin_id}"))
        #expect(harness.config(of: pane.id) == [:])
    }}"""
        if content_type
        else ""
    )
    return f"""import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// {display} against the real core runtime, without the app (docs/PLUGINS.md, Testing).
@MainActor
@Suite struct {target}Tests {{
    let harness: PluginHarness

    init() throws {{
        harness = try PluginHarness {{ {target}() }}
    }}

    @Test func activatesAsItsManifestDeclares() {{
        #expect(harness.record?.state == .active)
    }}{pane_test}
}}
"""


def info_plist(plugin_id: str, display: str, target: str, content_type: bool) -> str:
    types = f"<string>{plugin_id}</string>" if content_type else ""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>NSPrincipalClass</key>
	<string>$(PRODUCT_MODULE_NAME).{target}</string>
	<key>TabsPlugin</key>
	<dict>
		<key>id</key>
		<string>{plugin_id}</string>
		<key>displayName</key>
		<string>{display}</string>
		<key>summary</key>
		<string></string>
		<key>contentTypes</key>
		<array>{types}</array>
		<key>canDisable</key>
		<true/>
		<key>sortOrder</key>
		<integer>100</integer>
	</dict>
</dict>
</plist>
"""


def entry_class(plugin_id: str, display: str, target: str, content_type: bool) -> str:
    if not content_type:
        body = "        // Register contributions here (docs/PLUGINS.md), e.g. context.register(CommandContribution(...))."
        pane = ""
    else:
        body = f"""        context.register(
            ContentTypeContribution(id: "{plugin_id}", displayName: "{display}", symbolName: "square") {{ pane in
                {target.removesuffix("Plugin")}PaneController(pane: pane)
            }})"""
        pane = f"""

@MainActor
final class {target.removesuffix("Plugin")}PaneController: PaneController {{
    let view: NSView = NSView()
    private let pane: any PaneContext

    init(pane: any PaneContext) {{
        self.pane = pane
    }}

    func currentConfig() -> JSONValue {{ pane.initialConfig }}
}}"""
    return f"""import AppKit
import TabsPluginSDK

/// {display}.
@MainActor
final class {target}: NSObject, TabsPlugin {{
    func activate(_ context: any PluginContext) throws {{
{body}
    }}
}}{pane}
"""


if __name__ == "__main__":
    main()
