import AppKit
import Foundation
import ImageIO

@main
@MainActor
struct SkinPackageStoreRegression {
    private struct Entry {
        var name: String
        var data: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var mode: UInt32 = 0x81a4
        var extra = Data()
        var badCRC = false
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skin-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try layoutIdentity(root)
        try pageMotions(root)
        try hiddenPageMotions(root)
        try archiveCases(root)
        try transactions(root)
        try packageLimits(root)
        try recovery(root)
        try derivedAppearance(root)
        try reviewTransactions(root)
        print("Skin ZIP/store regressions passed")
    }
    static func layoutIdentity(_ root: URL) throws {
        let directory = try makePackage("layout-identity", "1", 0, nil, root)
        var layout = WorkspaceBuiltinLayouts.makeDefault()
        let widths = [640.0, 960.0, 1280.0]
        layout.breakpointLayouts = Dictionary(uniqueKeysWithValues: widths.map {
            (WorkspaceBreakpoint(minimumWidth: $0), layout.pages)
        })
        let hidden = Array(layout.pages.prefix(4).map(\.id))
        let collapsed = Array(WorkspaceLayoutTraversal.componentInstanceIDs(in: layout).prefix(4))
        layout.hiddenPageIDs = Set(hidden)
        layout.collapsedInstanceIDs = Set(collapsed)
        var manifest = try SkinPackageValidator.validate(directoryURL: directory).manifest
        manifest.layout = layout
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
        let initial = try SkinPackageValidator.validate(directoryURL: directory)
        let digest = try SkinPackageCodec.contentDigest(for: initial)
        // Schema 1 packages written before stable encoding may have any collection order.
        var legacyManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var legacyLayout = legacyManifest["layout"] as! [String: Any]
        let pairs = legacyLayout["breakpointLayouts"] as! [Any]
        legacyLayout["breakpointLayouts"] = stride(from: pairs.count - 2, through: 0, by: -2).flatMap {
            Array(pairs[$0...($0 + 1)])
        }
        legacyLayout["hiddenPageIDs"] = Array((legacyLayout["hiddenPageIDs"] as! [String]).reversed())
        legacyLayout["collapsedInstanceIDs"] = Array((legacyLayout["collapsedInstanceIDs"] as! [String]).reversed())
        legacyManifest["layout"] = legacyLayout
        try JSONSerialization.data(withJSONObject: legacyManifest).write(to: manifestURL)
        let legacyPackage = try SkinPackageValidator.validate(directoryURL: directory)
        check(legacyPackage.manifest.layout == layout, "old schema 1 collection ordering still decodes")
        check(try SkinPackageCodec.contentDigest(for: legacyPackage) == digest, "legacy ordering retains canonical Skin identity")
        for offset in 0..<16 {
            var equivalent = layout
            equivalent.breakpointLayouts = [:]
            equivalent.hiddenPageIDs = []
            equivalent.collapsedInstanceIDs = []
            for index in widths.indices {
                let width = widths[(index + offset) % widths.count]
                equivalent.breakpointLayouts[WorkspaceBreakpoint(minimumWidth: width)] = layout.pages
            }
            for index in hidden.indices {
                equivalent.hiddenPageIDs.insert(hidden[(index + offset) % hidden.count])
            }
            for index in collapsed.indices {
                equivalent.collapsedInstanceIDs.insert(collapsed[(index + offset) % collapsed.count])
            }
            check(equivalent == layout, "reordered collections retain the same presentation")
            manifest.layout = equivalent
            try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
            let decoded = try SkinPackageValidator.validate(directoryURL: directory)
            guard try SkinPackageCodec.contentDigest(for: decoded) == digest else {
                throw TestError.layoutIdentityChanged
            }
        }
        let archive = root.appendingPathComponent("layout-identity.iinaskin")
        try SkinArchive.create(from: directory, to: archive)
        let storeURL = root.appendingPathComponent("layout-identity-store")
        let store = SkinStore(rootURL: storeURL)
        let review = try store.prepareReview(archiveURL: archive)
        guard case .installed(let installed) = try store.installReviewed(review, select: true) else {
            fatalError("reviewed Layout Skin must install")
        }
        check(try SkinPackageCodec.contentDigest(for: installed) == review.digest, "install preserves reviewed Layout identity")
        check(try SkinStore(rootURL: storeURL).selectedPackage()?.manifest.layout == layout, "selected Layout Skin survives reopening")
        let repeated = try store.prepareReview(directoryURL: directory)
        check(try store.replacementRequired(for: repeated) == nil, "equivalent Layout is not a changed Skin revision")
        guard case .unchanged = try store.installReviewed(repeated, select: true) else {
            fatalError("equivalent Layout Skin must deduplicate")
        }
        let exported = root.appendingPathComponent("layout-identity-export.iinaskin")
        try store.exportSkin(id: installed.manifest.id, to: exported, mode: .original)
        let clean = SkinStore(rootURL: root.appendingPathComponent("layout-identity-clean"))
        guard case .installed(let imported) = try clean.importSkin(from: exported) else {
            fatalError("original Layout Skin must import into a clean store")
        }
        check(try SkinPackageCodec.contentDigest(for: imported) == digest, "original export retains Layout Skin identity")
        print("PASS: equal Layout collections retain Skin digest through review, install, deduplication, reopen and original export/import")
    }
    static func pageMotions(_ root: URL) throws {
        let directory = try makePackage("page-motion", "1", 0, nil, root)
        let legacy = try SkinPackageValidator.validate(directoryURL: directory)
        check(legacy.pageMotion == nil, "legacy Skin without an XML entry retains no motion default")
        let path = "motions/page.xml"
        let motionURL = directory.appendingPathComponent(path)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let fadeXML = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <pageMotion version="1" duration="0.2" opacity="0" offsetX="0" offsetY="0" scale="1" curve="easeOut"/>
            """.utf8)
        var authorLayout = WorkspaceBuiltinLayouts.makeDefault()
        authorLayout.pages[0].motion = WorkspacePageMotion(
            duration: 0.6, opacity: 0.3, offsetX: 12, offsetY: -10, scale: 0.94, curve: .easeInOut)
        let nestedPage = WorkspacePage(
            title: "Nested motion", root: .empty(id: UUID()), motion: .zoom)
        authorLayout.pages.append(WorkspacePage(
            title: "Tabs", root: .tabs(id: UUID(), selectedPageID: nestedPage.id, pages: [nestedPage]),
            motion: .slide))
        var narrowPages = authorLayout.pages
        narrowPages[0].motion = .fade
        authorLayout.breakpointLayouts = [WorkspaceBreakpoint(minimumWidth: 640): narrowPages]
        var manifest = legacy.manifest
        manifest.entryPaths["pageMotion"] = path
        manifest.layout = authorLayout
        try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
        func reject(_ expected: SkinPackageValidationError, _ reason: String) throws {
            do {
                _ = try SkinPackageValidator.validate(directoryURL: directory)
                fatalError("Expected page motion rejection: \(reason)")
            } catch let error as SkinPackageValidationError {
                check(error == expected, "\(reason) reports its motion file or entry")
            }
        }
        try reject(.missingFile(path), "explicit missing XML")
        for unsafe in ["../page.xml", "/page.xml", "motions\\page.xml", "https://invalid.example/page.xml"] {
            manifest.entryPaths["pageMotion"] = unsafe
            try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
            try reject(.invalidManifest("entryPaths"), "unsafe XML entry")
        }
        manifest.entryPaths["pageMotion"] = path
        try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
        try FileManager.default.createDirectory(
            at: motionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for invalid in [
            "<pageMotion/>",
            "<!DOCTYPE pageMotion SYSTEM \"file:///etc/passwd\">" + String(decoding: fadeXML, as: UTF8.self),
            String(decoding: fadeXML, as: UTF8.self).replacingOccurrences(of: "duration=\"0.2\"", with: "duration=\"6\""),
            String(decoding: fadeXML, as: UTF8.self).replacingOccurrences(of: "/>", with: " script=\"run\"/>"),
        ] {
            try Data(invalid.utf8).write(to: motionURL)
            try reject(.malformedFile(path), "invalid XML")
        }
        var maximumXML = fadeXML
        maximumXML.append(Data(
            repeating: 0x20, count: WorkspacePageMotion.maximumXMLBytes - maximumXML.count))
        try maximumXML.write(to: motionURL)
        check(
            try SkinPackageValidator.validate(directoryURL: directory).pageMotion == .fade,
            "XML at the exact 16 KiB boundary is accepted")
        maximumXML.append(0x20)
        try maximumXML.write(to: motionURL)
        try reject(.fileTooLarge(path), "XML exceeds 16 KiB")
        let rejectedArchive = root.appendingPathComponent("page-motion-oversize.iinaskin")
        try zip([
            Entry(name: "manifest.json", data: Data(contentsOf: manifestURL)),
            Entry(name: "theme.json", data: Data(contentsOf: directory.appendingPathComponent("theme.json"))),
            Entry(name: path, data: maximumXML),
        ], rejectedArchive)
        let rejectedStore = SkinStore(rootURL: root.appendingPathComponent("page-motion-rejected-store"))
        fails("oversized page XML import") { _ = try rejectedStore.importSkin(from: rejectedArchive) }
        check(try rejectedStore.installedSkins().isEmpty, "invalid XML import installs no Skin")
        try fadeXML.write(to: motionURL)
        manifest.entryPaths.removeValue(forKey: "pageMotion")
        try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
        try reject(.unexpectedFile(path), "unlisted XML is not auto-loaded")
        manifest.entryPaths["pageMotion"] = path
        try SkinPackageCodec.canonicalData(for: manifest).write(to: manifestURL)
        let source = try SkinPackageValidator.validate(directoryURL: directory)
        check(source.pageMotion == .fade, "listed XML decodes as the Skin default")
        check(source.manifest.layout == authorLayout, "Skin XML does not rewrite author page motions")
        let digest = try SkinPackageCodec.contentDigest(for: source)
        let slideXML = Data(String(decoding: fadeXML, as: UTF8.self)
            .replacingOccurrences(of: "offsetY=\"0\"", with: "offsetY=\"16\"").utf8)
        try slideXML.write(to: motionURL)
        let changed = try SkinPackageValidator.validate(directoryURL: directory)
        fails("in-memory motion differs from XML") { try SkinPackageValidator.validate(source) }
        check(
            try SkinPackageCodec.contentDigest(for: changed) != digest,
            "editing only XML changes Skin identity")
        try (fadeXML + Data("\n".utf8)).write(to: motionURL)
        let reformatted = try SkinPackageValidator.validate(directoryURL: directory)
        let reformattedDigest = try SkinPackageCodec.contentDigest(for: reformatted)
        check(
            reformatted.pageMotion == source.pageMotion
                && reformattedDigest != digest,
            "raw XML bytes participate in Skin identity even for equivalent decoded motion")
        try fadeXML.write(to: motionURL)
        let archive = root.appendingPathComponent("page-motion.iinaskin")
        try SkinArchive.create(from: directory, to: archive)
        let storeURL = root.appendingPathComponent("page-motion-store")
        let store = SkinStore(rootURL: storeURL)
        guard case .installed(let installed) = try store.importSkin(from: archive) else {
            fatalError("motion Skin must install")
        }
        try store.selectSkin(id: installed.manifest.id)
        check(installed.pageMotion == .fade, "install retains Skin XML motion")
        check(installed.manifest.layout == authorLayout, "install retains base, breakpoint and tab page motions")
        check(
            try SkinStore(rootURL: storeURL).selectedPackage()?.pageMotion == .fade,
            "selected Skin XML motion survives store reopening")
        let exports: [(String, SkinExportMode, WorkspaceLayout?, WorkspaceLayout?)] = [
            ("original", .original, nil, authorLayout),
            ("derived-layout", .derived, authorLayout, authorLayout),
            ("derived-no-layout", .derived, nil, nil),
        ]
        for (name, mode, layout, expectedLayout) in exports {
            let destination = root.appendingPathComponent("page-motion-\(name).iinaskin")
            try store.exportSkin(
                id: installed.manifest.id, to: destination, mode: mode, layout: layout,
                overrides: SkinPersonalOverrides(theme: ["spacing": .number(18)]))
            let clean = SkinStore(rootURL: root.appendingPathComponent("page-motion-\(name)-store"))
            guard case .installed(let imported) = try clean.importSkin(from: destination) else {
                fatalError("motion \(name) export must import into a clean store")
            }
            check(imported.pageMotion == .fade, "\(name) export/import preserves the Skin default")
            let importedXML = try Data(contentsOf: imported.directoryURL.appendingPathComponent(path))
            check(
                imported.manifest.entryPaths["pageMotion"] == path
                    && importedXML == fadeXML,
                "\(name) export/import preserves the XML entry and exact bytes")
            check(imported.manifest.layout == expectedLayout, "\(name) preserves the selected Layout policy and page motions")
            switch mode {
            case .original:
                check(try SkinPackageCodec.contentDigest(for: imported) == digest, "original XML export retains author identity")
            case .derived:
                check(imported.manifest.id != installed.manifest.id, "derived XML export gets its own identity")
                check(
                    try SkinAppearance(package: imported, scheme: .light).resolve(slot: .list).spacing == 18,
                    "derived XML export also retains personal appearance")
            }
        }
        check(
            try store.selectedPackage()?.manifest.layout == authorLayout,
            "export without Layout leaves installed author page motions untouched")
    }
    static func hiddenPageMotions(_ root: URL) throws {
        let cases = [
            ("hidden-motion-file", ".motion.xml"),
            ("hidden-motion-parent", ".motions/page.xml"),
        ]
        let xml = Data(
            """
            <pageMotion version="1" duration="0.35" opacity="0.2" offsetX="14" offsetY="-6" scale="0.96" curve="easeInOut"/>
            """.utf8)
        let motion = WorkspacePageMotion(
            duration: 0.35, opacity: 0.2, offsetX: 14, offsetY: -6, scale: 0.96, curve: .easeInOut)
        for (id, path) in cases {
            let directory = try makePackage(id, "1", 0, nil, root)
            var manifest = try SkinPackageValidator.validate(directoryURL: directory).manifest
            manifest.entryPaths["pageMotion"] = path
            try SkinPackageCodec.canonicalData(for: manifest).write(
                to: directory.appendingPathComponent("manifest.json"))
            let motionURL = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: motionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: motionURL)
            let store = SkinStore(rootURL: root.appendingPathComponent("\(id)-store"))
            let review = try store.prepareReview(directoryURL: directory)
            check(review.package.pageMotion == motion, "\(path) is an accepted XML entry")
            guard case .installed(let installed) = try store.installReviewed(review) else {
                fatalError("hidden motion Skin must install")
            }
            check(installed.pageMotion == motion, "\(path) installation retains actual motion")
            let exports: [(String, SkinExportMode)] = [("original", .original), ("derived", .derived)]
            for (name, mode) in exports {
                let destination = root.appendingPathComponent("\(id)-\(name).iinaskin")
                try store.exportSkin(id: id, to: destination, mode: mode)
                let clean = SkinStore(rootURL: root.appendingPathComponent("\(id)-\(name)-store"))
                guard case .installed(let imported) = try clean.importSkin(from: destination) else {
                    fatalError("hidden motion \(name) export must import into a clean store")
                }
                check(
                    imported.pageMotion == motion,
                    "\(path) \(name) export/import preserves actual motion, not a fallback")
                let importedXML = try Data(contentsOf: imported.directoryURL.appendingPathComponent(path))
                check(
                    imported.manifest.entryPaths["pageMotion"] == path
                        && importedXML == xml,
                    "\(path) \(name) export/import preserves the exact entry and XML bytes")
                if mode == .original {
                    check(
                        try SkinPackageCodec.contentDigest(for: imported) == review.digest,
                        "\(path) original export/import retains package identity")
                }
            }
            let changedXML = Data(String(decoding: xml, as: UTF8.self)
                .replacingOccurrences(of: "offsetX=\"14\"", with: "offsetX=\"24\"").utf8)
            try changedXML.write(to: motionURL)
            let changedReview = try store.prepareReview(directoryURL: directory)
            guard let change = try store.replacementRequired(for: changedReview) else {
                fatalError("changed hidden motion must require replacement")
            }
            check(
                change.changedFiles == [path],
                "replacement reports the changed hidden XML at \(path)")
            guard case .replaced(let replacement, let previousDigest) = try store.installReviewed(
                changedReview, replacing: change)
            else { fatalError("approved hidden motion replacement must replace the prior package") }
            check(previousDigest == review.digest, "replacement identifies the superseded hidden-motion package")
            var changedMotion = motion
            changedMotion.offsetX = 24
            check(
                replacement.pageMotion == changedMotion,
                "\(path) replacement retains the changed actual motion")
        }
    }
    static func reviewTransactions(_ root: URL) throws {
        let storeURL = root.appendingPathComponent("review-store")
        let store = SkinStore(rootURL: storeURL)
        let author = try makePackage("review", "1", 1, nil, root)
        let archive = root.appendingPathComponent("review.iinaskin")
        try SkinArchive.create(from: author, to: archive)
        var cancelled: SkinReviewPackage? = try store.prepareReview(archiveURL: archive)
        let stagingURL = cancelled!.package.directoryURL
        _ = try SkinAppearance(package: cancelled!.package, scheme: .light).resolve(slot: .list)
        check(try store.installedSkins().isEmpty && store.selectedPackage() == nil, "preview does not install or select")
        check(!FileManager.default.fileExists(atPath: storeURL.path), "cancel on clean profile does not create persistent storage")
        cancelled = nil
        check(!FileManager.default.fileExists(atPath: stagingURL.path), "cancel releases staged package")
        let first = try store.prepareReview(directoryURL: author)
        _ = try store.installReviewed(first, select: true)
        let catalogURL = storeURL.appendingPathComponent("catalog-v1.json")
        let before = try Data(contentsOf: catalogURL)
        let oldDigest = try SkinPackageCodec.contentDigest(for: store.selectedPackage()!)
        let themeURL = author.appendingPathComponent("theme.json")
        let changedTheme = SkinTheme(light: ["spacing": .number(18)], dark: ["spacing": .number(20)])
        try SkinPackageCodec.canonicalData(for: changedTheme).write(to: themeURL)
        let reloaded = try store.prepareReview(directoryURL: author)
        check(reloaded.digest != first.digest, "author reload reads changed package")
        check(try SkinPackageCodec.contentDigest(for: first.package) == first.digest, "prior review remains an isolated snapshot")
        check(try Data(contentsOf: catalogURL) == before, "reload does not mutate catalog")
        guard let change = try store.replacementRequired(for: reloaded) else { fatalError("replacement diff required") }
        check(change.changedFiles.contains("theme.json"), "same-ID replacement reports changed theme")
        fails("replacement without approval") { _ = try store.installReviewed(reloaded, select: true) }
        fails("failed activation after review") {
            _ = try store.installReviewed(reloaded, replacing: change, select: true, validateForActivation: { _ in throw TestError.preflight })
        }
        fails("Layout activation failure rolls back committed catalog") {
            _ = try store.installReviewed(reloaded, replacing: change, select: true, activate: { throw TestError.preflight })
        }
        check(try Data(contentsOf: catalogURL) == before, "post-commit activation rollback preserves catalog bytes")
        fails("selection activation failure") {
            try store.selectSkin(id: nil, activate: { throw TestError.preflight })
        }
        check(try store.selectedPackage()?.manifest.id == "review", "selection activation failure restores selected skin")
        do {
            _ = try store.installReviewed(reloaded, replacing: change, select: true, activate: {
                try FileManager.default.removeItem(at: catalogURL)
                try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
                throw TestError.preflight
            })
            fatalError("expected compound rollback failure")
        } catch {
            check(error.localizedDescription.contains("rollback also failed"), "rollback failure reports compound error instead of claiming previous selection")
        }
        try FileManager.default.removeItem(at: catalogURL)
        try before.write(to: catalogURL, options: .atomic)
        check(try SkinPackageCodec.contentDigest(for: store.selectedPackage()!) == oldDigest, "rollback failure preserves old revision for recovery")
        check(try SkinPackageCodec.contentDigest(for: first.package) == first.digest, "fault leaves review snapshot intact")
        check(try Data(contentsOf: catalogURL) == before, "failed replacement retains catalog bytes")
        check(try SkinPackageCodec.contentDigest(for: store.selectedPackage()!) == oldDigest, "failed replacement preserves selection and assets")
        try Data("{\"light\":{\"spacing\":\"invalid\"},\"dark\":{},\"system\":{}}".utf8).write(to: themeURL)
        do {
            _ = try store.prepareReview(directoryURL: author)
            fatalError("bad author reload")
        } catch {
            let description = error.localizedDescription
            check(description.contains("theme.json") && description.contains("light") && description.contains("spacing"), "author errors locate file and field")
        }
        check(try Data(contentsOf: catalogURL) == before, "bad reload keeps installed package")
        let manifestURL = author.appendingPathComponent("manifest.json")
        var malformed = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        malformed["version"] = 42
        try JSONSerialization.data(withJSONObject: malformed).write(to: manifestURL)
        do {
            _ = try store.prepareReview(directoryURL: author)
            fatalError("malformed manifest")
        } catch {
            check(error.localizedDescription.contains("manifest.json") && error.localizedDescription.contains("version"), "decode errors locate file and coding field")
        }
        _ = try store.installReviewed(reloaded, replacing: change, select: true)
        check(try SkinPackageCodec.contentDigest(for: store.selectedPackage()!) == reloaded.digest, "apply installs reviewed snapshot even if author source changed")
        let selected = WorkspaceBuiltinLayouts.makeDefault()
        let withLayout = root.appendingPathComponent("review-with-layout.iinaskin")
        try store.exportSkin(id: "review", to: withLayout, mode: .derived, layout: selected)
        let shared = try store.prepareReview(archiveURL: withLayout)
        check(shared.package.manifest.layout == selected, "selected presentation layout round trips through shared codec")
        let noLayout = root.appendingPathComponent("review-without-layout.iinaskin")
        let importedLayout = try store.installReviewed(shared)
        let derivedID: String
        switch importedLayout {
        case .installed(let package), .unchanged(let package), .replaced(let package, _): derivedID = package.manifest.id
        }
        try store.exportSkin(id: derivedID, to: noLayout, mode: .derived, layout: nil)
        check(try store.prepareReview(archiveURL: noLayout).package.manifest.layout == nil, "no-layout export does not silently inherit author layout")
    }
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func fails(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            fatalError("Expected failure: \(message)")
        } catch {}
    }
    static func archiveCases(_ root: URL) throws {
        let empty = root.appendingPathComponent("empty.zip")
        try zip([], empty)
        try SkinArchive.extract(from: empty, to: root.appendingPathComponent("empty-out"))
        let emptyFile = root.appendingPathComponent("empty-file.zip")
        try zip([Entry(name: "empty", data: Data())], emptyFile)
        let emptyOut = root.appendingPathComponent("empty-file-out")
        try SkinArchive.extract(from: emptyFile, to: emptyOut)
        check(
            try Data(contentsOf: emptyOut.appendingPathComponent("empty")).isEmpty,
            "empty stored file")
        let dirs = root.appendingPathComponent("dirs.zip")
        try zip([Entry(name: "folder/", data: Data(), mode: 0x41ed)], dirs)
        try SkinArchive.extract(from: dirs, to: root.appendingPathComponent("dirs-out"))
        let png = pngData()
        func reject(_ label: String, _ entries: [Entry]) throws {
            let url = root.appendingPathComponent("reject-\(UUID().uuidString).zip")
            try zip(entries, url)
            fails(label) {
                try SkinArchive.extract(
                    from: url, to: root.appendingPathComponent("reject-out-\(UUID().uuidString)"))
            }
        }
        try reject("traversal", [Entry(name: "../x", data: Data([1]))])
        try reject("absolute path", [Entry(name: "/tmp/x", data: Data([1]))])
        try reject("backslash", [Entry(name: "a\\b", data: Data([1]))])
        try reject("drive path", [Entry(name: "C:/x", data: Data([1]))])
        try reject(
            "case collision", [Entry(name: "A.png", data: png), Entry(name: "a.PNG", data: png)])
        try reject(
            "Unicode normalization collision",
            [Entry(name: "é.png", data: png), Entry(name: "e\u{301}.png", data: png)])
        try reject(
            "ancestor collision",
            [Entry(name: "parent", data: Data([1])), Entry(name: "parent/child", data: Data([2]))])
        try reject("symlink", [Entry(name: "link", data: Data("target".utf8), mode: 0xa1ff)])
        var hardLink = Data()
        put16(0x000d, &hardLink)
        put16(1, &hardLink)
        hardLink.append(1)
        try reject("hard-link extra field", [Entry(name: "link", data: Data([1]), extra: hardLink)])
        try reject("encryption", [Entry(name: "encrypted", data: Data([1]), flags: 1)])
        try reject("unsupported method", [Entry(name: "unknown", data: Data([1]), method: 12)])
        try reject("nested archive ext", [Entry(name: "nested.zip", data: Data([1]))])
        try reject(
            "nested archive magic", [Entry(name: "renamed.bin", data: Data([0x1f, 0x8b, 0, 0]))])
        try reject("CRC mismatch", [Entry(name: "bad.png", data: png, badCRC: true)])
        let deflated = root.appendingPathComponent("deflated.zip")
        try zip(
            [
                Entry(
                    name: "hello.txt", data: Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 7, 0]), method: 8)
            ], deflated, crcOverride: ["hello.txt": 0x3610_a686])
        let out = root.appendingPathComponent("deflated-out")
        try SkinArchive.extract(from: deflated, to: out)
        check(
            try Data(contentsOf: out.appendingPathComponent("hello.txt")) == Data("hello".utf8),
            "raw DEFLATE support")
        let badDeflate = root.appendingPathComponent("truncated-deflate.zip")
        try zip(
            [Entry(name: "bad", data: Data([0xcb, 0x48, 0xcd]), method: 8)], badDeflate,
            crcOverride: ["bad": 0x3610_a686])
        fails("truncated DEFLATE") {
            try SkinArchive.extract(
                from: badDeflate, to: root.appendingPathComponent("bad-deflate-out"))
        }
        try reject(
            "over entry count",
            (0...SkinArchive.maximumEntryCount).map { Entry(name: "f\($0)", data: Data()) })
    }
    static func transactions(_ root: URL) throws {
        let store = SkinStore(rootURL: root.appendingPathComponent("store"))
        let v1 = try makePackage("transaction", "1", 0, nil, root)
        let a1 = root.appendingPathComponent("v1.iinaskin")
        try SkinArchive.create(from: v1, to: a1)
        guard case .installed(let first) = try store.importSkin(from: a1) else {
            fatalError("install")
        }
        try store.selectSkin(id: "transaction")
        try store.setColorScheme(.dark)
        let overrides = SkinPersonalOverrides(theme: ["spacing": .number(14)])
        try store.saveOverrides(overrides, for: "transaction")
        check(try store.loadOverrides(for: "transaction") == overrides, "override persistence")
        let v2 = try makePackage("transaction", "2", 0, nil, root)
        let a2 = root.appendingPathComponent("v2.iinaskin")
        try SkinArchive.create(from: v2, to: a2)
        var confirmation: SkinReplacementConfirmation?
        do {
            _ = try store.importSkin(from: a2)
            fatalError("replacement needs confirmation")
        } catch SkinStoreError.replacementConfirmationRequired(let value) { confirmation = value }
        check(
            confirmation?.changedFiles.contains("manifest.json") == true,
            "replacement diff includes manifest")
        fails("activation callback rollback") {
            _ = try store.importSkin(from: a2, replacing: confirmation, validateForActivation: { _ in
                throw TestError.preflight
            })
        }
        check(
            try store.selectedPackage()?.manifest.version == "1",
            "activation failure keeps old selection")
        check(
            try SkinPackageCodec.contentDigest(for: store.selectedPackage()!)
                == SkinPackageCodec.contentDigest(for: first),
            "activation failure keeps old revision")
        guard
            case .replaced(let replaced, _) = try store.importSkin(
                from: a2, replacing: confirmation)
        else { fatalError("confirmed replacement") }
        check(
            replaced.manifest.version == "2" && store.colorScheme == .dark,
            "replacement preserves global scheme")
        check(
            try store.loadOverrides(for: "transaction") == overrides,
            "replacement retains personal overrides")
        let original = root.appendingPathComponent("original.iinaskin")
        try store.exportSkin(id: "transaction", to: original, mode: .original)
        let occupied = root.appendingPathComponent("occupied.iinaskin")
        let preserved = Data([0x41, 0x42])
        try preserved.write(to: occupied)
        fails("existing export target") {
            try store.exportSkin(id: "transaction", to: occupied, mode: .original)
        }
        check(
            try Data(contentsOf: occupied) == preserved,
            "atomic export preserves existing target bytes")
        let clean = SkinStore(rootURL: root.appendingPathComponent("clean-profile"))
        guard case .installed(let imported) = try clean.importSkin(from: original) else {
            fatalError("original export reimport")
        }
        check(imported.manifest.id == "transaction", "original ID preserved")
        let derived = root.appendingPathComponent("derived.iinaskin")
        try store.exportSkin(id: "transaction", to: derived, mode: .derived, overrides: overrides)
        let cleanDerived = SkinStore(rootURL: root.appendingPathComponent("derived-profile"))
        guard case .installed(let derivedPackage) = try cleanDerived.importSkin(from: derived)
        else { fatalError("derived export reimport") }
        check(
            derivedPackage.manifest.id != "transaction"
                && derivedPackage.manifest.provenance["derivedFrom"] == "transaction",
            "derived ID/provenance")
        check(
            try SkinAppearance(package: derivedPackage, scheme: .light).resolve(slot: .list).spacing
                == 14, "derived package renders personal spacing in clean profile")
        try store.removeSkin(id: "transaction")
        check(
            try store.selectedPackage() == nil && (try store.installedSkins()).isEmpty,
            "remove active skin returns to builtin")
        let dedup = SkinStore(rootURL: root.appendingPathComponent("dedup"))
        _ = try dedup.importSkin(from: a1)
        guard case .unchanged = try dedup.importSkin(from: a1) else {
            fatalError("same content dedupe")
        }
    }

    static func derivedAppearance(_ root: URL) throws {
        let source = try makePackage("cascade", "1", 2, nil, root)
        let components = SkinComponents(
            slots: [
                "primaryAction": SkinSlotStyle(
                    values: ["fontSize": .number(14)],
                    states: [
                        "normal": ["iconAsset": .string("icon0")],
                        "hover": ["iconAsset": .string("icon1")],
                    ])
            ],
            overrides: [
                "search.results": [
                    "primaryAction": SkinSlotStyle(states: [
                        "normal": ["iconAsset": .string("icon1")],
                        "pressed": ["fontSize": .number(17)],
                    ])
                ]
            ])
        try SkinPackageCodec.canonicalData(for: components).write(
            to: source.appendingPathComponent("components.json"))
        let archive = root.appendingPathComponent("cascade.iinaskin")
        try SkinArchive.create(from: source, to: archive)
        let store = SkinStore(rootURL: root.appendingPathComponent("cascade-store"))
        guard case .installed(let package) = try store.importSkin(from: archive) else {
            fatalError("cascade install")
        }
        let personal = SkinPersonalOverrides(
            theme: ["fontSize": .number(20)],
            slots: [
                "primaryAction": SkinSlotStyle(states: [
                    "normal": ["iconAsset": .string("icon0")], "pressed": ["fontSize": .number(24)],
                ])
            ])
        let before = try SkinAppearance(package: package, overrides: personal, scheme: .light)
        check(
            before.resolve(slot: .primaryAction, componentID: "search.results", state: .pressed)
                .font.pointSize == 24, "personal state wins over author component")
        let exported = root.appendingPathComponent("cascade-derived.iinaskin")
        try store.exportSkin(id: "cascade", to: exported, mode: .derived, overrides: personal)
        let clean = SkinStore(rootURL: root.appendingPathComponent("cascade-clean"))
        guard case .installed(let derived) = try clean.importSkin(from: exported) else {
            fatalError("derived cascade import")
        }
        let after = try SkinAppearance(package: derived, scheme: .light)
        for componentID: String? in [nil, "search.results"] {
            for state in SkinControlState.allCases {
                let expected = before.resolve(
                    slot: .primaryAction, componentID: componentID, state: state)
                let actual = after.resolve(
                    slot: .primaryAction, componentID: componentID, state: state)
                check(
                    actual.font.pointSize == expected.font.pointSize,
                    "clean derived package preserves state font precedence")
                check(
                    actual.assetIDs == expected.assetIDs,
                    "clean derived package preserves replacement asset-group fallback")
            }
        }
    }

    static func packageLimits(_ root: URL) throws {
        let store = SkinStore(rootURL: root.appendingPathComponent("limits-store"))
        let max = try makePackage(
            "boundary", "1", 4, SkinPackageValidator.maximumPackageBytes, root)
        let maxArchive = root.appendingPathComponent("maximum.iinaskin")
        try SkinArchive.create(from: max, to: maxArchive)
        guard case .installed(let package) = try store.importSkin(from: maxArchive) else {
            fatalError("maximum valid Skin rejected")
        }
        check(
            try packageSize(package.directoryURL) == SkinPackageValidator.maximumPackageBytes,
            "full store import at exact 64MiB expanded maximum")
        try store.selectSkin(id: "boundary")
        let over = try makePackage(
            "boundary", "2", 4, SkinPackageValidator.maximumPackageBytes + 1, root)
        let overArchive = root.appendingPathComponent("over-total.iinaskin")
        try zip(try entries(over), overArchive)
        fails("package expanded total +1") { _ = try store.importSkin(from: overArchive) }
        check(
            try store.selectedPackage()?.manifest.version == "1",
            "over-total keeps catalog unchanged")
        let singleOver = try makePackage("single-over", "1", 1, nil, root)
        var image = pngData()
        image.append(
            Data(repeating: 0, count: SkinPackageValidator.maximumAssetBytes + 1 - image.count))
        try image.write(to: singleOver.appendingPathComponent("asset0.png"))
        let singleArchive = root.appendingPathComponent("over-single.iinaskin")
        try zip(try entries(singleOver), singleArchive)
        fails("asset max +1") { _ = try store.importSkin(from: singleArchive) }
        let maxCount = try makePackage(
            "count-max", "1", SkinArchive.maximumEntryCount - 2, nil, root)
        let maxCountArchive = root.appendingPathComponent("count-max.iinaskin")
        try SkinArchive.create(from: maxCount, to: maxCountArchive)
        guard case .installed = try store.importSkin(from: maxCountArchive) else {
            fatalError("256-entry valid package rejected")
        }
        let countOver = try makePackage(
            "count-over", "1", SkinArchive.maximumEntryCount - 1, nil, root)
        let countOverArchive = root.appendingPathComponent("count-over.iinaskin")
        try zip(try entries(countOver), countOverArchive)
        fails("package count max +1") { _ = try store.importSkin(from: countOverArchive) }
    }
    static func recovery(_ root: URL) throws {
        let dir = root.appendingPathComponent("catalog-recovery")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalog = dir.appendingPathComponent("catalog-v1.json")
        let original = Data("bad catalog".utf8)
        try original.write(to: catalog)
        let store = SkinStore(rootURL: dir)
        check(try store.installedSkins().isEmpty, "catalog recover to builtin")
        check(
            store.recoveryNotice != nil && !FileManager.default.fileExists(atPath: catalog.path),
            "recovery notice and original preserved")
        let backups = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("corrupt") }
        check(backups.count == 1, "one preserved corrupt catalog")
        check(
            try Data(contentsOf: backups[0]) == original, "corrupt catalog backup is byte-for-byte")
    }
    static func makePackage(
        _ id: String, _ version: String, _ count: Int, _ total: Int?, _ root: URL
    ) throws -> URL {
        let dir = root.appendingPathComponent("pkg-\(id)-\(version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let assets = Dictionary(
            uniqueKeysWithValues: (0..<count).map { ("icon\($0)", "asset\($0).png") })
        let manifest = try SkinPackageCodec.canonicalData(
            for: SkinManifest(
                id: id, version: version, name: "Regression", license: "MIT", assets: assets))
        let theme = try SkinPackageCodec.canonicalData(for: SkinTheme())
        try manifest.write(to: dir.appendingPathComponent("manifest.json"))
        try theme.write(to: dir.appendingPathComponent("theme.json"))
        for i in 0..<count {
            var data = pngData()
            if let total {
                let size =
                    count == 4 && i < 3
                    ? SkinPackageValidator.maximumAssetBytes
                    : total - manifest.count - theme.count - (count - 1)
                        * SkinPackageValidator.maximumAssetBytes
                guard size >= data.count && size <= SkinPackageValidator.maximumAssetBytes else {
                    throw TestError.fixture
                }
                if size > data.count { data.append(Data(repeating: 0, count: size - data.count)) }
            }
            try data.write(to: dir.appendingPathComponent("asset\(i).png"))
        }
        return dir
    }
    static func packageSize(_ dir: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
    private static func entries(_ dir: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map {
            Entry(name: $0.lastPathComponent, data: try Data(contentsOf: $0))
        }
    }
    static func pngData() -> Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p6sAAAAASUVORK5CYII="
        )!
    }
    private static func zip(_ entries: [Entry], _ url: URL, crcOverride: [String: UInt32] = [:])
        throws
    {
        var body = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc =
                crcOverride[entry.name]
                ?? entry.data.withUnsafeBytes {
                    skin_zip_crc32(
                        $0.baseAddress?.assumingMemoryBound(to: UInt8.self), entry.data.count)
                }
            let recorded = entry.badCRC ? crc ^ 1 : crc
            let expanded: UInt32 = entry.method == 8 ? 5 : UInt32(entry.data.count)
            let offset = UInt32(body.count)
            put32(0x0403_4b50, &body)
            put16(20, &body)
            put16(entry.flags, &body)
            put16(entry.method, &body)
            put16(0, &body)
            put16(0, &body)
            put32(recorded, &body)
            put32(UInt32(entry.data.count), &body)
            put32(expanded, &body)
            put16(UInt16(name.count), &body)
            put16(UInt16(entry.extra.count), &body)
            body.append(name)
            body.append(entry.extra)
            body.append(entry.data)
            put32(0x0201_4b50, &central)
            put16(0x0314, &central)
            put16(20, &central)
            put16(entry.flags, &central)
            put16(entry.method, &central)
            put16(0, &central)
            put16(0, &central)
            put32(recorded, &central)
            put32(UInt32(entry.data.count), &central)
            put32(expanded, &central)
            put16(UInt16(name.count), &central)
            put16(UInt16(entry.extra.count), &central)
            put16(0, &central)
            put16(0, &central)
            put16(0, &central)
            put32(entry.mode << 16, &central)
            put32(offset, &central)
            central.append(name)
            central.append(entry.extra)
        }
        let centralOffset = UInt32(body.count)
        body.append(central)
        put32(0x0605_4b50, &body)
        put16(0, &body)
        put16(0, &body)
        put16(UInt16(entries.count), &body)
        put16(UInt16(entries.count), &body)
        put32(UInt32(central.count), &body)
        put32(centralOffset, &body)
        put16(0, &body)
        try body.write(to: url, options: .atomic)
    }
    static func put16(_ value: UInt16, _ data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }
    static func put32(_ value: UInt32, _ data: inout Data) {
        put16(UInt16(value & 0xffff), &data)
        put16(UInt16(value >> 16), &data)
    }
    enum TestError: Error { case preflight, fixture, layoutIdentityChanged }
}
