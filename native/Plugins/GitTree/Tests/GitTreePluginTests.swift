import AppKit
import TabsPluginSDK
import Testing

@testable import TabsCore

/// The git tree plugin against the real core runtime, without the app
/// (docs/PLUGINS.md, Testing): what it contributes. Case ids are
/// docs/GIT-TREE.md's.
@MainActor
@Suite struct GitTreePluginTests {
    let bed: GitTreeTestBed

    init() throws {
        bed = try GitTreeTestBed()
    }

    @Test func activatesAsItsManifestDeclares() {
        #expect(bed.harness.record?.state == .active)
        #expect(bed.harness.manifest.contentTypes == ["git-tree"])
        #expect(bed.harness.manifest.displayName == "Git tree")
    }

    @Test func contributesTheContentType() throws {
        let contribution = try #require(bed.harness.runtime.registry.contribution(to: .contentTypes, id: "git-tree"))
        #expect(contribution.value.displayName == "Git tree")
        guard case .image(let icon) = contribution.value.icon else { Issue.record("the icon isn't the Electron app's image"); return }
        #expect(icon.isTemplate && icon.size == NSSize(width: 16, height: 16))
        #expect(contribution.value.resolvedCreationLabel == "New git tree")
    }

    /// ST-1…ST-3
    @Test func contributesASettingsPage() throws {
        let page = try #require(bed.harness.runtime.registry.contribution(to: .settingsPages, id: "git-tree"))
        #expect(page.value.title == "Git tree")
    }

    @Test func opensAPaneWithNoDirectoryUntilItAdoptsOne() async throws {
        bed.git.defaultDirectoryAnswer = "/repo"
        let (id, pane) = try #require(bed.open())
        #expect(pane.log == nil)
        #expect(await eventually { bed.harness.config(of: id) == ["cwd": "/repo"] })
    }

    /// PS-1, PS-2: only its four keys are its own; everything else survives.
    @Test func savesItsStateInTheConfigAndKeepsUnknownKeys() async throws {
        let (id, pane) = try await bed.openRepo(extra: ["somethingElse": 1])
        pane.chooseBranchScope(.local)
        pane.commitSplit(DetailSplit(fraction: 0.3, collapsed: false))
        #expect(
            bed.harness.config(of: id)
                == ["cwd": "/repo", "somethingElse": 1, "branchScope": "local", "detailFraction": 0.3, "detailCollapsed": false])
    }
}
