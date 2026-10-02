import Foundation
import TabsPluginSDK

/// The Resource verb, `save-resource` (`main/browserExternalControl.ts`'s `handleSaveResource`,
/// docs/BROWSER.md J-22): fetch a page resource's bytes (`ResourceFetch` has the per-scheme routes)
/// and write them to disk, returning the path, never the bytes.
@MainActor
enum ResourceVerbs {
    static func all(services: BrowserServices) -> [ControlVerbContribution] { [saveResource(files: services.agentFiles)] }

    /// Budget: unbounded (30 s), a fetch of arbitrary size, matching `execute-js`'s tier. The http(s)
    /// fetch aborts itself inside it (`ResourceFetch.httpTimeoutSeconds`); core's deadline bounds the rest.
    private static func saveResource(files: AgentFiles) -> ControlVerbContribution {
        ControlVerbContribution(
            name: "browser.saveResource",
            summary:
                "Save a page resource — a blob:/data:/http(s) URL, or an element’s src — to a local file and return the path (never the bytes). The way to get a PDF, image or any binary out of a page: save it, then read the file. Pass exactly one of --url, --ref, --selector.",
            arguments: [
                ControlArgument("url", .string, summary: "A blob:, data:, http:, or https: URL to fetch."),
                ControlArgument("ref", .string, summary: "A read-page ref whose element’s src/href is saved."),
                ControlArgument("selector", .string, summary: "A CSS selector whose element’s src/href is saved.", placeholder: "css"),
                ControlArgument(
                    "outPath", .path,
                    summary: "Where to write it, resolved against your shell’s cwd. Default: a temp file swept after ~10 minutes.",
                    placeholder: "path", flag: "out"),
            ],
            target: .ownedPane(ofTypes: ["browser"]), timeout: .seconds(30),
            command: "save-resource", wireType: "saveResource",
            resultShape: ["path": "string", "bytes": "number", "contentType": "string"]
        ) { invocation in
            let pane = try VerbSupport.pane(invocation)

            // The wire doc promises exactly one of url/ref/selector, "enforced where the request is
            // handled": a preference chain here would silently ignore the losers, saving an artifact
            // the caller didn't name.
            let givenURL = invocation["url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let given = [
                givenURL != nil ? "--url" : nil, invocation["ref"] != nil ? "--ref" : nil,
                invocation["selector"] != nil ? "--selector" : nil,
            ]
            .compactMap { $0 }
            if given.count > 1 {
                throw ControlVerbError(
                    "save-resource takes exactly one of --url, --ref or --selector — got \(given.joined(separator: " and "))")
            }

            let resourceURL: String
            if let givenURL {
                resourceURL = givenURL
            } else if invocation["ref"] != nil || invocation["selector"] != nil {
                switch await ResourceFetch.resolveElementSrc(
                    in: pane.page, ref: invocation["ref"]?.stringValue, selector: invocation["selector"]?.stringValue)
                {
                case .failure(let failure): throw ControlVerbError(failure.message)
                case .success(let url): resourceURL = url
                }
            } else {
                throw ControlVerbError("save-resource needs one of --url, --ref or --selector")
            }

            let fetched: FetchedResource
            switch await ResourceFetch.fetch(resourceURL, page: pane.page) {
            case .failure(let failure): throw ControlVerbError(failure.message)
            case .success(let resource): fetched = resource
            }

            let ext = ResourceFetch.extensionFor(url: resourceURL, contentType: fetched.contentType, bytes: fetched.bytes)
            switch files.write(
                fetched.bytes, out: invocation["outPath"], subdirectory: AgentFiles.Subdirectory.resources, ext: ext, what: "resource")
            {
            case .failure(let failure): throw ControlVerbError(failure.message)
            case .success(let path):
                var result: [String: JSONValue] = ["path": .string(path), "bytes": .int(Int64(fetched.bytes.count))]
                if let type = fetched.contentType, !type.isEmpty { result["contentType"] = .string(type) }
                return .object(result)
            }
        }
    }
}
