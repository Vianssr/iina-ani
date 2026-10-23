import Foundation

@main
@MainActor
struct WorkspaceLayoutRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func ids(_ pages: [WorkspacePage]) -> Set<UUID> {
        Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: WorkspaceLayout(pages: pages)))
    }

    static func favoriteSplit(_ page: WorkspacePage) -> WorkspaceNode {
        guard case .verticalStack(_, let children) = page.root, children.count == 2,
            case .split = children[1]
        else { fatalError("favorites must show updates above its two native panels") }
        return children[1]
    }

    static func main() async throws {
        let validator = WorkspaceValidator(registry: WorkspaceRegistry.builtins)
        let layout = WorkspaceBuiltinLayouts.makeDefault()
        let favorite = layout.pages.first { $0.id == WorkspacePageID.favorites }!
        guard case .split(_, let workNode, let linkNode, _) = favoriteSplit(favorite),
            case .component(let workID, _, _, _, _) = workNode,
            case .component(let linkID, _, _, _, _) = linkNode
        else {
            fatalError("restored favorites must expose two separate native panels")
        }
        for width in [960.0, 1280.0] {
            let pages = WorkspaceLayoutTraversal.pages(forWidth: width, in: layout)
            check(Set(pages.map(\.id)) == Set(layout.pages.map(\.id)), "resizing cannot remove navigation")
            guard case .split(_, let first, let second, _) = favoriteSplit(pages.first(where: { $0.id == favorite.id })!) else {
                fatalError("minimum window must preserve the favorites split")
            }
            check(first.id == workID && second.id == linkID, "resize must keep list instance identities")
            guard case .verticalStack(_, let home) = pages.first(where: { $0.id == WorkspacePageID.discover })!.root,
                home.count == 3 else { fatalError("home must show Trends, continue watching and recommendations") }
            let types = home.compactMap { node -> WorkspaceComponentID? in
                if case .component(_, let type, _, _, _) = node { return type }; return nil
            }
            check(types == ["discovery.recommendations", "playback.continue", "discovery.feed"], "home section order is fixed at both widths")
            guard case .component(_, _, _, _, let trendSize) = home[0] else { fatalError("Trends missing") }
            check(trendSize.height == 210, "builtin Trends height is compact")
        }
        let encoded = try WorkspaceLayoutCodec.encode(layout, validator: validator)
        let decoded = try WorkspaceLayoutCodec.decode(encoded, validator: validator)
        check(decoded == layout, "layout persistence must preserve identities and dimensions")
        let localizationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: localizationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localizationRoot) }
        let fixtureTitles = Dictionary(uniqueKeysWithValues: decoded.pages.map { ($0.title, "localized-\($0.id)") })
        let fixtureStrings = fixtureTitles.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try fixtureStrings.write(to: localizationRoot.appendingPathComponent("Localizable.strings"),
                                 atomically: true, encoding: .utf8)
        guard let localizationBundle = Bundle(url: localizationRoot) else { fatalError("localization fixture bundle missing") }
        for page in decoded.pages {
            check(page.displayTitle(bundle: localizationBundle) == fixtureTitles[page.title],
                  "saved canonical built-in names resolve through the selected localization bundle")
            var renamed = page
            renamed.title = "My page \(page.id)"
            check(renamed.displayTitle(bundle: localizationBundle) == renamed.title, "renamed built-in pages keep their authored title")
            let authored = WorkspacePage(title: page.title, root: page.root)
            check(authored.displayTitle(bundle: localizationBundle) == authored.title, "custom and Skin-authored pages do not localize canonical-looking titles")
            let skinNamed = WorkspacePage(id: page.id, title: "Skin page \(page.id)", root: page.root)
            check(skinNamed.displayTitle(bundle: localizationBundle) == skinNamed.title, "authored titles on built-in IDs remain verbatim")
        }
        let beforeDisplay = try WorkspaceLayoutCodec.encode(decoded, validator: validator)
        _ = decoded.pages.map { $0.displayTitle(bundle: localizationBundle) }
        let afterDisplay = try WorkspaceLayoutCodec.encode(decoded, validator: validator)
        check(afterDisplay == beforeDisplay, "display localization must not rewrite serialized page titles")

        do {
            try validator.validate(WorkspaceLayout(schemaVersion: 99, pages: layout.pages))
            fatalError("schema accepted")
        } catch WorkspaceValidationError.unsupportedSchema(99) {}
        let unknown = WorkspacePage(
            title: "bad",
            root: .component(
                id: UUID(), componentID: "unknown", contractVersion: 1, parameters: [:],
                size: .init(width: 320, height: 200)))
        do {
            try validator.validate(WorkspaceLayout(pages: [unknown]))
            fatalError("unknown component accepted")
        } catch WorkspaceValidationError.unknownComponent("unknown") {}
        let wrongVersion = WorkspacePage(
            title: "bad",
            root: .component(
                id: UUID(), componentID: "favorites.works", contractVersion: 2, parameters: [:],
                size: .init(width: 300, height: 200)))
        do {
            try validator.validate(WorkspaceLayout(pages: [wrongVersion]))
            fatalError("component version accepted")
        } catch WorkspaceValidationError.unsupportedComponentVersion("favorites.works", 2) {}
        let badSize = WorkspacePage(
            title: "bad",
            root: .component(
                id: UUID(), componentID: "favorites.works", contractVersion: 1, parameters: [:],
                size: .init(width: 1, height: 200)))
        do {
            try validator.validate(WorkspaceLayout(pages: [badSize]))
            fatalError("size accepted")
        } catch WorkspaceValidationError.invalidSize("favorites.works") {}
        do {
            try validator.validate(WorkspaceLayout(pages: [favorite, favorite]))
            fatalError("duplicate page accepted")
        } catch WorkspaceValidationError.duplicatePage(favorite.id) {}
        let duplicateInstance = WorkspacePage(title: "duplicate", root: workNode)
        do {
            try validator.validate(WorkspaceLayout(pages: [favorite, duplicateInstance]))
            fatalError("duplicate instance accepted")
        } catch WorkspaceValidationError.duplicateIdentity(workID) {}
        let badRatio = WorkspacePage(
            title: "ratio", root: .split(id: UUID(), first: workNode, second: linkNode, ratio: 1))
        do {
            try validator.validate(WorkspaceLayout(pages: [badRatio]))
            fatalError("split ratio accepted")
        } catch WorkspaceValidationError.invalidRatio {}

        let simple = WorkspaceLayout(pages: [WorkspacePage(title: "single", root: workNode)])
        var object =
            try JSONSerialization.jsonObject(with: WorkspaceLayoutCodec.encode(simple, validator: validator))
            as! [String: Any]
        object["future"] = true
        do {
            _ = try WorkspaceLayoutCodec.decode(JSONSerialization.data(withJSONObject: object), validator: validator)
            fatalError("unknown key accepted")
        } catch is DecodingError {}
        object.removeValue(forKey: "future")
        var pages = object["pages"] as! [[String: Any]]
        var root = pages[0]["root"] as! [String: Any]
        root["children"] = []
        pages[0]["root"] = root
        object["pages"] = pages
        do {
            _ = try WorkspaceLayoutCodec.decode(JSONSerialization.data(withJSONObject: object), validator: validator)
            fatalError("inapplicable node field accepted")
        } catch is DecodingError {}
        let nested = Data((String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)).utf8)
        do {
            _ = try WorkspaceLayoutCodec.decode(nested, validator: validator)
            fatalError("JSON depth accepted")
        } catch WorkspaceValidationError.excessiveDepth {}
        do {
            _ = try WorkspaceLayoutCodec.decode(
                Data(repeating: 32, count: validator.maximumDocumentBytes + 1), validator: validator)
            fatalError("document byte limit ignored")
        } catch WorkspaceDocumentError.tooLarge {}
        let deep = (0..<40).reduce(workNode) { child, _ in WorkspaceNode.group(id: UUID(), children: [child]) }
        do {
            try validator.validate(WorkspaceLayout(pages: [WorkspacePage(title: "deep", root: deep)]))
            fatalError("tree depth accepted")
        } catch WorkspaceValidationError.excessiveDepth {}
        var inconsistent = simple
        inconsistent.breakpointLayouts[.init(minimumWidth: 960)] = [
            WorkspacePage(
                id: simple.pages[0].id, title: "single",
                root: .component(
                    id: workID, componentID: "favorites.links", contractVersion: 1, parameters: [:],
                    size: .init(width: 420, height: 480)))
        ]
        do {
            try validator.validate(inconsistent)
            fatalError("same instance rebound to different owner")
        } catch WorkspaceValidationError.inconsistentInstance(workID) {}

        let session = try WorkspaceSessionState(storeURL: nil)
        let transient = WorkspaceInstanceState(
            query: "private query", filter: "title", page: 2, selection: "selection", scrollPosition: 42)
        try session.update(transient, for: workID)
        let moved = try WorkspaceTransaction.move(instanceID: workID, to: WorkspacePageID.search, in: layout)
        let movedAgain = try WorkspaceLayoutCodec.decode(
            WorkspaceLayoutCodec.encode(moved, validator: validator), validator: validator)
        for variant in [movedAgain.pages] + Array(movedAgain.breakpointLayouts.values) {
            check(
                ids([variant.first { $0.id == WorkspacePageID.search }!]).contains(workID),
                "move must reach destination in every active variant")
            check(!ids([variant.first { $0.id == favorite.id }!]).contains(workID), "move must remove its old location")
        }
        let movedState = session.state(for: workID)
        check(movedState == transient, "move cannot reset the component query or selection")
        let copied = try WorkspaceTransaction.copy(instanceID: workID, to: WorkspacePageID.search, in: layout)
        let copiedAgain = try WorkspaceLayoutCodec.decode(
            WorkspaceLayoutCodec.encode(copied, validator: validator), validator: validator)
        let newIDs = ids(copiedAgain.pages).subtracting(ids(layout.pages))
        check(newIDs.count == 1 && !newIDs.contains(workID), "copy must create exactly one independent instance")
        for variant in copiedAgain.breakpointLayouts.values {
            check(
                ids(variant).subtracting(ids(layout.pages)) == newIDs,
                "copy must use the same new identity across breakpoints")
        }
        let copyState = session.state(for: newIDs.first!)
        check(copyState == WorkspaceInstanceState(), "copy must not inherit private selection or query")
        let removed = try WorkspaceTransaction.remove(instanceID: workID, from: layout)
        let removedAgain = try WorkspaceLayoutCodec.decode(
            WorkspaceLayoutCodec.encode(removed, validator: validator), validator: validator)
        check(
            !Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: removedAgain)).contains(workID),
            "remove must affect every variant")
        check(ids(removedAgain.pages).contains(linkID), "remove cannot delete neighboring panels")
        try session.retainInstances(in: removedAgain)
        let cleared = session.state(for: workID)
        check(cleared == WorkspaceInstanceState(), "removed instance state must be released")

        var hiddenDestination = layout
        hiddenDestination.breakpointLayouts[.init(minimumWidth: 960)] = [favorite]
        do {
            _ = try WorkspaceTransaction.move(instanceID: workID, to: WorkspacePageID.search, in: hiddenDestination)
            fatalError("move silently loses a component at a breakpoint")
        } catch WorkspaceTransactionError.invalidDestination {}
        let alternate = WorkspacePage(title: "alternate destination", root: .empty(id: UUID()))
        let variantOnly = WorkspaceLayout(
            pages: [alternate], breakpointLayouts: [.init(minimumWidth: 960): [favorite, alternate]])
        let variantMove = try WorkspaceTransaction.move(instanceID: workID, to: alternate.id, in: variantOnly)
        try validator.validate(variantMove)
        check(
            ids([variantMove.breakpointLayouts[.init(minimumWidth: 960)]!.first { $0.id == alternate.id }!]).contains(
                workID), "visible variant-only instances must remain editable")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("layout.json")
        let store = WorkspaceStore(url: file, validator: validator)
        guard case .loaded(let initial) = store.load(),
            case .loaded(let untouchedReopen) = WorkspaceStore(url: file).load()
        else { fatalError("initial default could not be persisted") }
        check(initial == untouchedReopen, "untouched default identities must survive process restart")
        try store.save(movedAgain)
        guard case .loaded(let saved) = store.load() else { fatalError("valid save failed") }
        check(saved == movedAgain, "reopen must preserve the committed transaction")
        let previous = try Data(contentsOf: file)
        do {
            try store.save(WorkspaceLayout(schemaVersion: 99, pages: layout.pages))
            fatalError("invalid save replaced valid workspace")
        } catch WorkspaceValidationError.unsupportedSchema(99) {}
        let afterFailure = try Data(contentsOf: file)
        check(previous == afterFailure, "failed save must leave committed file unchanged")
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: file)
        guard case .recoveredDefault(let recovered, _) = store.load() else { fatalError("corruption was not reported") }
        try validator.validate(recovered)
        let retained = try Data(contentsOf: file)
        check(retained == corrupt, "load recovery cannot overwrite original document")
        try store.save(removedAgain)
        let backups = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains("corrupt-")
        }
        check(backups.count == 1, "explicit restore must preserve one repairable original")
        let backup = try Data(contentsOf: backups[0])
        check(backup == corrupt, "recovery backup must retain exact original bytes")
        try instanceStateRegression(directory: temp)
        try motionRegression(directory: temp, validator: validator)
        try migrationRegression(directory: temp, validator: validator)
        try editorRegression(layout: layout, workID: workID, linkID: linkID, store: store, file: file, validator: validator)
        print(
            "PASS W8.1 layout: strict versions/identities/depth, responsive navigation, valid move/copy/remove, private state isolation, atomic reopen and corrupt-file recovery"
        )
    }

    static func motionRegression(directory: URL, validator: WorkspaceValidator) throws {
        func xml(_ motion: WorkspacePageMotion) -> String {
            """
            <pageMotion version="1" duration="\(motion.duration)" opacity="\(motion.opacity)" offsetX="\(motion.offsetX)" offsetY="\(motion.offsetY)" scale="\(motion.scale)" curve="\(motion.curve.rawValue)"/>
            """
        }
        func expectRejectedXML(_ data: Data, _ reason: String) {
            do {
                _ = try WorkspacePageMotion.decodeXML(data)
                fatalError("page motion XML accepted: \(reason)")
            } catch is WorkspacePageMotionError {
            } catch {
                fatalError("page motion XML returned an unexpected error: \(error)")
            }
        }
        func expectRejectedLayout(_ value: WorkspaceLayout, _ field: String) {
            do {
                try validator.validate(value)
                fatalError("invalid page motion \(field) accepted by layout validation")
            } catch WorkspacePageMotionError.invalidValue(let rejected) {
                check(rejected == field, "motion validation identifies the invalid field")
            } catch {
                fatalError("layout motion returned an unexpected error: \(error)")
            }
        }
        let xmlFile = directory.appendingPathComponent("page-motion.xml")
        try Data(xml(.slide).utf8).write(to: xmlFile)
        let loaded = try WorkspacePageMotion.loadXML(from: xmlFile)
        check(loaded == .slide, "local XML import preserves animation parameters")
        for curve in WorkspacePageMotion.Curve.allCases {
            let motion = WorkspacePageMotion(
                duration: 0.75, opacity: 0.4, offsetX: -24, offsetY: 12, scale: 1.2, curve: curve)
            let parsed = try WorkspacePageMotion.decodeXML(Data(xml(motion).utf8))
            check(parsed == motion, "every timing curve and custom transform is supported")
        }
        let declared = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + xml(.slide)
        let declaredMotion = try WorkspacePageMotion.decodeXML(Data(declared.utf8))
        check(declaredMotion == .slide, "ordinary UTF-8 XML declarations are supported")
        let lower = WorkspacePageMotion(duration: 0, opacity: 0, offsetX: -2048, offsetY: -2048, scale: 0.1)
        let upper = WorkspacePageMotion(duration: 5, opacity: 1, offsetX: 2048, offsetY: 2048, scale: 4)
        try lower.validate()
        try upper.validate()

        let first = WorkspacePage(title: "Fade", root: .empty(id: UUID()), motion: .fade)
        let second = WorkspacePage(title: "Slide", root: .empty(id: UUID()), motion: .slide)
        let outer = WorkspacePage(
            title: "Zoom", root: .tabs(id: UUID(), selectedPageID: first.id, pages: [first, second]), motion: .zoom)
        let breakpoint = WorkspaceBreakpoint(minimumWidth: 960)
        let layout = WorkspaceLayout(pages: [outer], breakpointLayouts: [breakpoint: [outer]])
        let encoded = try WorkspaceLayoutCodec.encode(layout, validator: validator)
        let reopened = try WorkspaceLayoutCodec.decode(encoded, validator: validator)
        check(reopened == layout, "page motion roundtrips for top, nested and breakpoint pages")
        func stripMotion(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object.removeValue(forKey: "motion")
                for key in Array(object.keys) { object[key] = stripMotion(object[key]!) }
                return object
            }
            if let array = value as? [Any] { return array.map(stripMotion) }
            return value
        }
        let legacyData = try JSONSerialization.data(
            withJSONObject: stripMotion(JSONSerialization.jsonObject(with: encoded)))
        let legacy = try WorkspaceLayoutCodec.decode(legacyData, validator: validator)
        for pages in [legacy.pages] + Array(legacy.breakpointLayouts.values) {
            check(pages[0].motion == .none, "legacy top page motion defaults to none")
            guard case .tabs(_, _, let tabs) = pages[0].root else { fatalError("legacy tabs lost") }
            check(tabs.allSatisfy { $0.motion == .none }, "legacy nested pages also default to none")
        }
        let legacyAgain = try WorkspaceLayoutCodec.decode(
            WorkspaceLayoutCodec.encode(legacy, validator: validator), validator: validator)
        check(legacyAgain == legacy, "legacy layout remains stable after the first new-format save")

        var baseMotionJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkspacePageMotion.slide)) as! [String: Any]
        let basePageJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outer)) as! [String: Any]
        var invalidMotionJSONs: [[String: Any]] = []
        for (field, value) in [
            ("duration", -1.0), ("opacity", 1.1), ("offsetX", 2049.0), ("offsetY", -2049.0), ("scale", 0.0)
        ] {
            var changed = baseMotionJSON
            changed[field] = value
            invalidMotionJSONs.append(changed)
        }
        var changed = baseMotionJSON
        changed["curve"] = "spring"
        invalidMotionJSONs.append(changed)
        changed = baseMotionJSON
        changed["duration"] = "0.25"
        invalidMotionJSONs.append(changed)
        changed = baseMotionJSON
        changed["future"] = true
        invalidMotionJSONs.append(changed)
        changed = baseMotionJSON
        changed.removeValue(forKey: "opacity")
        invalidMotionJSONs.append(changed)
        for invalid in invalidMotionJSONs {
            var pageJSON = basePageJSON
            pageJSON["motion"] = invalid
            do {
                _ = try JSONDecoder().decode(WorkspacePage.self, from: JSONSerialization.data(withJSONObject: pageJSON))
                fatalError("invalid or unknown motion JSON accepted")
            } catch is DecodingError {}
        }
        var nullMotionPage = basePageJSON
        nullMotionPage["motion"] = NSNull()
        do {
            _ = try JSONDecoder().decode(WorkspacePage.self, from: JSONSerialization.data(withJSONObject: nullMotionPage))
            fatalError("explicit null motion silently became none")
        } catch is DecodingError {}
        baseMotionJSON["duration"] = "NaN"
        let nonfiniteDecoder = JSONDecoder()
        nonfiniteDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        do {
            _ = try nonfiniteDecoder.decode(
                WorkspacePageMotion.self, from: JSONSerialization.data(withJSONObject: baseMotionJSON))
            fatalError("nonfinite motion JSON accepted")
        } catch is DecodingError {}

        for (field, value) in [
            ("duration", -0.01), ("duration", 5.01), ("duration", Double.nan),
            ("opacity", -0.01), ("opacity", 1.01), ("opacity", Double.infinity),
            ("offsetX", -2048.01), ("offsetX", 2048.01), ("offsetX", -Double.infinity),
            ("offsetY", -2048.01), ("offsetY", 2048.01), ("offsetY", Double.nan),
            ("scale", 0.09), ("scale", 4.01), ("scale", Double.infinity)
        ] {
            var invalid = WorkspacePageMotion.slide
            switch field {
            case "duration": invalid.duration = value
            case "opacity": invalid.opacity = value
            case "offsetX": invalid.offsetX = value
            case "offsetY": invalid.offsetY = value
            case "scale": invalid.scale = value
            default: fatalError("unknown test field")
            }
            var badTop = outer
            badTop.motion = invalid
            expectRejectedLayout(WorkspaceLayout(pages: [badTop]), field)
            var badNested = first
            badNested.motion = invalid
            var nestedOuter = outer
            nestedOuter.root = .tabs(id: outer.root.id, selectedPageID: first.id, pages: [badNested, second])
            expectRejectedLayout(WorkspaceLayout(pages: [nestedOuter]), field)
            expectRejectedLayout(WorkspaceLayout(pages: [outer], breakpointLayouts: [breakpoint: [badTop]]), field)
            expectRejectedXML(Data(xml(invalid).utf8), field)
        }

        let validXML = xml(.slide)
        let invalidXMLs = [
            "", "<pageMotion", validXML.replacingOccurrences(of: "pageMotion", with: "motion"),
            validXML.replacingOccurrences(of: "version=\"1\"", with: "version=\"2\""),
            validXML.replacingOccurrences(of: "version=\"1\"", with: ""),
            validXML.replacingOccurrences(of: "opacity=\"0.0\"", with: ""),
            validXML.replacingOccurrences(of: "/>", with: " future=\"1\"/>"),
            validXML.replacingOccurrences(of: "/>", with: " duration=\"0.25\"/>"),
            validXML.replacingOccurrences(of: "duration=\"0.25\"", with: "duration=\"bad\""),
            validXML.replacingOccurrences(of: "curve=\"easeOut\"", with: "curve=\"spring\""),
            validXML.replacingOccurrences(of: "/>", with: "><child/></pageMotion>"),
            validXML.replacingOccurrences(of: "/>", with: ">text</pageMotion>"),
            validXML.replacingOccurrences(of: "/>", with: "><![CDATA[]]></pageMotion>"),
            validXML.replacingOccurrences(of: "/>", with: " xmlns=\"urn:motion\"/>"),
            validXML.replacingOccurrences(of: "opacity=\"0.0\"", with: "opacity=\"&#48;\""),
            validXML + validXML, validXML + "trailing",
            "<!-- comment -->" + validXML, "<?unknown data?>" + validXML,
            "<!DOCTYPE pageMotion>" + validXML,
            "<!DOCTYPE pageMotion SYSTEM \"file:///etc/passwd\">" + validXML,
            "<!DOCTYPE pageMotion [<!ENTITY x \"0\">]>" +
                validXML.replacingOccurrences(of: "opacity=\"0.0\"", with: "opacity=\"&x;\""),
            "<!DOCTYPE pageMotion [<!ENTITY % remote SYSTEM \"https://invalid.example/entity\">%remote;]>" + validXML
        ]
        for (index, invalid) in invalidXMLs.enumerated() {
            expectRejectedXML(Data(invalid.utf8), "strict syntax case \(index)")
        }
        expectRejectedXML(Data([0xFF, 0xFE, 0x00]), "invalid UTF-8")
        expectRejectedXML(validXML.data(using: .utf16)!, "unsupported UTF-16")
        let padded = validXML + String(repeating: " ", count: WorkspacePageMotion.maximumXMLBytes - validXML.utf8.count)
        let boundaryMotion = try WorkspacePageMotion.decodeXML(Data(padded.utf8))
        check(boundaryMotion == .slide, "the XML byte limit is inclusive")
        let oversized = Data(repeating: 32, count: WorkspacePageMotion.maximumXMLBytes + 1)
        do {
            _ = try WorkspacePageMotion.decodeXML(oversized)
            fatalError("motion XML byte limit ignored")
        } catch WorkspacePageMotionError.tooLarge {}
        try oversized.write(to: xmlFile)
        do {
            _ = try WorkspacePageMotion.loadXML(from: xmlFile)
            fatalError("local motion XML byte limit ignored")
        } catch WorkspacePageMotionError.tooLarge {}
        do {
            _ = try WorkspacePageMotion.loadXML(from: URL(string: "https://invalid.example/motion.xml")!)
            fatalError("remote motion XML URL accepted")
        } catch WorkspacePageMotionError.notLocalFile {}
        do {
            _ = try WorkspacePageMotion.loadXML(from: directory)
            fatalError("directory accepted as motion XML")
        } catch WorkspacePageMotionError.notLocalFile {}

        let store = WorkspaceStore(url: directory.appendingPathComponent("motion-layout.json"), validator: validator)
        try store.save(layout)
        let committed = try Data(contentsOf: store.url)
        let editor = WorkspaceLayoutEditor(layout: layout, registry: WorkspaceRegistry.builtins)
        try editor.setPageMotion(pageID: outer.id, motion: .fade)
        check(editor.pages[0].motion == .fade, "top-level motion editing targets the selected page")
        editor.undo()
        check(editor.layout == layout, "top-level motion edit is reversible")
        try editor.setPageMotion(pageID: first.id, motion: .zoom)
        check(WorkspaceEditorTree.findPage(first.id, in: editor.pages)?.motion == .zoom,
              "nested motion editing targets the selected page")
        check(editor.layout.breakpointLayouts == layout.breakpointLayouts,
              "base motion edit leaves breakpoint motion untouched")
        let edited = editor.layout
        editor.undo()
        check(editor.layout == layout, "motion gesture is one undo")
        editor.redo()
        check(editor.layout == edited, "motion redo preserves the complete draft")
        do {
            try editor.setPageMotion(pageID: UUID(), motion: .fade)
            fatalError("missing page accepted for motion editing")
        } catch WorkspaceTransactionError.invalidDestination {}
        check(editor.layout == edited, "missing motion target does not change the draft")
        var badMotion = WorkspacePageMotion.fade
        badMotion.duration = .infinity
        do {
            try editor.setPageMotion(pageID: first.id, motion: badMotion)
            fatalError("invalid motion changed the editor draft")
        } catch WorkspacePageMotionError.invalidValue("duration") {}
        check(editor.layout == edited, "invalid motion leaves draft and undo history unchanged")
        do {
            let imported = try WorkspacePageMotion.decodeXML(Data("<invalid/>".utf8))
            try editor.setPageMotion(pageID: first.id, motion: imported)
            fatalError("invalid XML changed the editor draft")
        } catch WorkspacePageMotionError.invalidXML {}
        check(editor.layout == edited, "XML rejection leaves the current draft unchanged")
        editor.breakpoint = breakpoint
        try editor.setPageMotion(pageID: outer.id, motion: .fade)
        check(editor.layout.pages == edited.pages && editor.pages[0].motion == .fade,
              "breakpoint motion editing is isolated from base pages")
        let afterRejectedImport = try Data(contentsOf: store.url)
        check(afterRejectedImport == committed, "draft edits and rejected XML do not overwrite saved layout")
        try store.save(editor.layout)
        guard case .loaded(let saved) = store.load() else { fatalError("motion layout failed to reopen") }
        check(saved == editor.layout, "motion commit persists base, nested and breakpoint values")
        let firstPanel = WorkspaceNode.component(
            id: UUID(), componentID: "favorites.works", contractVersion: 1, parameters: [:],
            size: .init(width: 480, height: 480))
        let secondPanel = WorkspaceNode.component(
            id: UUID(), componentID: "favorites.links", contractVersion: 1, parameters: [:],
            size: .init(width: 480, height: 480))
        let nestedPage = WorkspacePage(
            title: "Nested panels", root: .group(id: UUID(), children: [firstPanel, secondPanel]), motion: .fade)
        let sourcePage = WorkspacePage(
            title: "Source", root: .tabs(id: UUID(), selectedPageID: nestedPage.id, pages: [nestedPage]), motion: .zoom)
        let destinationPage = WorkspacePage(title: "Destination", root: .empty(id: UUID()), motion: .slide)
        let panelLayout = WorkspaceLayout(
            pages: [sourcePage, destinationPage], breakpointLayouts: [breakpoint: [sourcePage, destinationPage]])
        let copied = try WorkspaceTransaction.copy(instanceID: firstPanel.id, to: destinationPage.id, in: panelLayout)
        let removed = try WorkspaceTransaction.remove(instanceID: firstPanel.id, from: panelLayout)
        let moved = try WorkspaceTransaction.move(instanceID: firstPanel.id, to: destinationPage.id, in: panelLayout)
        for changedLayout in [copied, removed, moved] {
            try validator.validate(changedLayout)
            for pages in [changedLayout.pages] + Array(changedLayout.breakpointLayouts.values) {
                check(WorkspaceEditorTree.findPage(nestedPage.id, in: pages)?.motion == .fade,
                      "copy, remove and move preserve surviving nested page motion")
                check(pages[0].motion == .zoom && pages[1].motion == .slide,
                      "copy, remove and move preserve top-level page motion")
            }
        }
        let nestedEditor = WorkspaceLayoutEditor(layout: panelLayout, registry: WorkspaceRegistry.builtins)
        let insertedID = UUID()
        try nestedEditor.insert(.empty(id: insertedID), to: nestedPage.id)
        check(WorkspaceEditorTree.findPage(nestedPage.id, in: nestedEditor.pages)?.motion == .fade,
              "inserting into a nested page preserves its motion")
        try nestedEditor.remove(nodeID: insertedID)
        check(WorkspaceEditorTree.findPage(nestedPage.id, in: nestedEditor.pages)?.motion == .fade,
              "nested removal preserves its page motion")
        print("PASS page motion: strict bounded XML, entity/DTD rejection, legacy/new JSON, nested validation, presets, draft isolation and atomic reopen")
    }

    static func migrationRegression(directory: URL, validator: WorkspaceValidator) throws {
        func panel(_ type: WorkspaceComponentID, width: Double = 760, height: Double) -> WorkspaceNode {
            .component(id: UUID(), componentID: type, contractVersion: 1, parameters: [:],
                       size: .init(width: width, height: height))
        }
        var legacy = WorkspaceBuiltinLayouts.makeDefault()
        let discoveryIndex = legacy.pages.firstIndex { $0.id == WorkspacePageID.discover }!
        let favoritesIndex = legacy.pages.firstIndex { $0.id == WorkspacePageID.favorites }!
        let components = [panel("discovery.schedule", height: 280), panel("discovery.updates", height: 280),
                          panel("discovery.recommendations", height: 360), panel("discovery.followed", height: 360)]
        legacy.pages[discoveryIndex].root = .verticalStack(id: UUID(), children: components)
        legacy.pages[discoveryIndex].title = "我的發現"
        legacy.pages[favoritesIndex].root = favoriteSplit(legacy.pages[favoritesIndex])
        legacy.pages[favoritesIndex].title = "我的收藏"
        legacy.homePageID = WorkspacePageID.favorites
        legacy.hiddenPageIDs.insert(WorkspacePageID.search)
        legacy.collapsedInstanceIDs = [components[0].id, components[1].id, components[2].id,
                                       ids([legacy.pages[favoritesIndex]]).first!]
        legacy.breakpointLayouts = [.init(minimumWidth: 960): legacy.pages, .init(minimumWidth: 1280): legacy.pages]
        let unrelated = WorkspacePage(title: "自訂頁", root: .group(id: UUID(), children: [panel("search.results", height: 480)]))
        legacy.pages.append(unrelated)
        let file = directory.appendingPathComponent("legacy-layout.json")
        let store = WorkspaceStore(url: file, validator: validator)
        try store.save(legacy)
        guard case .loaded(let migrated) = store.load() else { fatalError("legacy migration failed") }
        let feedIDs = Set(WorkspaceLayoutTraversal.componentTypes(in: migrated).filter { $0.value == "discovery.feed" }.keys)
        check(feedIDs.count == 1, "migration creates one shared feed instance")
        let historyIDs = Set(WorkspaceLayoutTraversal.componentTypes(in: migrated).filter { $0.value == "playback.continue" }.keys)
        check(historyIDs.count == 1, "migration creates one shared continuing instance")
        for pages in migrated.breakpointLayouts.values {
            check(ids(pages).isSuperset(of: feedIDs), "every breakpoint retains the same new feed identity")
            check(ids(pages).isSuperset(of: historyIDs), "every breakpoint shares the new continuing identity")
        }
        check(migrated.schemaVersion == legacy.schemaVersion, "migration cannot change schema")
        check(migrated.homePageID == legacy.homePageID && migrated.hiddenPageIDs == legacy.hiddenPageIDs,
              "migration preserves navigation settings")
        check(migrated.collapsedInstanceIDs == legacy.collapsedInstanceIDs.subtracting([components[0].id]),
              "migration only prunes collapse settings for removed panels")
        check(migrated.pages.last == unrelated, "migration cannot alter unrelated custom pages")
        for (oldPages, newPages) in [(legacy.pages, migrated.pages)] + legacy.breakpointLayouts.keys.map({
            (legacy.breakpointLayouts[$0]!, migrated.breakpointLayouts[$0]!)
        }) {
            check(oldPages.map(\.id) == newPages.map(\.id) && oldPages.map(\.title) == newPages.map(\.title),
                  "page IDs, order and renamed titles survive migration")
            let oldFavorites = oldPages.first { $0.id == WorkspacePageID.favorites }!
            let newFavorites = newPages.first { $0.id == WorkspacePageID.favorites }!
            check(favoriteSplit(newFavorites) == oldFavorites.root, "works/links and split identities remain intact")
            guard case .verticalStack(_, let favorites) = newFavorites.root,
                case .verticalStack(let discoverID, let discover) = newPages.first(where: { $0.id == WorkspacePageID.discover })!.root
            else { fatalError("migrated containers missing") }
            check(favorites[0].id == components[1].id && discover[0].id == components[2].id,
                  "updates/recommendations keep private-state instance identities")
            check(discoverID == oldPages.first(where: { $0.id == WorkspacePageID.discover })!.root.id,
                  "discovery root identity remains intact")
        }
        let committed = try Data(contentsOf: file)
        let persistedMigration = try WorkspaceLayoutCodec.decode(committed, validator: validator)
        check(persistedMigration == migrated, "migration is persisted before load returns")
        guard case .loaded(let reopened) = store.load() else { fatalError("migrated reopen failed") }
        let reopenBytes = try Data(contentsOf: file)
        check(reopened == migrated && committed == reopenBytes, "migration runs once without generating fresh IDs")

        var threePanel = legacy
        func beforeFollowed(_ pages: [WorkspacePage]) -> [WorkspacePage] {
            pages.map { original in
                var page = original
                if page.id == WorkspacePageID.discover, case .verticalStack(let id, let children) = page.root {
                    page.root = .verticalStack(id: id, children: Array(children.prefix(3)))
                }
                return page
            }
        }
        threePanel.pages = beforeFollowed(legacy.pages)
        threePanel.breakpointLayouts = legacy.breakpointLayouts.mapValues(beforeFollowed)
        try store.save(threePanel)
        guard case .loaded(let upgradedThreePanel) = store.load() else { fatalError("older builtin migration failed") }
        let upgradedTypes = WorkspaceLayoutTraversal.componentTypes(in: upgradedThreePanel)
        check(upgradedTypes[components[1].id] == "discovery.updates" &&
              upgradedTypes[components[2].id] == "discovery.recommendations" &&
              upgradedTypes[components[0].id] == nil && upgradedTypes.values.contains("discovery.feed"),
              "pre-followed builtin layouts migrate without losing surviving panel state")
        check(favoriteSplit(upgradedThreePanel.pages[favoritesIndex]) == threePanel.pages[favoritesIndex].root,
              "older builtin migration preserves the original library split")

        func unchanged(_ candidate: WorkspaceLayout, _ message: String,
                       validator: WorkspaceValidator = WorkspaceValidator(registry: WorkspaceRegistry.builtins)) throws {
            let candidateStore = WorkspaceStore(url: file, validator: validator)
            try candidateStore.save(candidate)
            let before = try Data(contentsOf: file)
            guard case .loaded(let loaded) = candidateStore.load() else { fatalError("custom layout failed to load") }
            let after = try Data(contentsOf: file)
            check(loaded == candidate && before == after, message)
        }
        func changedPages(_ original: [WorkspacePage], _ change: (inout [WorkspacePage]) -> Void) -> [WorkspacePage] {
            var pages = original
            change(&pages)
            return pages
        }
        // A one-point edit to any old panel, even at just one breakpoint, is custom.
        let allNodes = components + {
            guard case .split(_, let a, let b, _) = legacy.pages[favoritesIndex].root else { fatalError("legacy split missing") }
            return [a, b]
        }()
        for node in allNodes {
            for dimension in ["width", "height"] {
                var custom = legacy
                custom.breakpointLayouts[.init(minimumWidth: 1280)] = legacy.breakpointLayouts[.init(minimumWidth: 1280)]!.map { page in
                    var page = page
                    page.root = WorkspaceEditorTree.map(page.root) { candidate in
                        guard candidate.id == node.id,
                            case .component(let id, let type, let version, let parameters, var size) = candidate
                        else { return candidate }
                        if dimension == "width" { size.width += 1 } else { size.height += 1 }
                        return .component(id: id, componentID: type, contractVersion: version, parameters: parameters, size: size)
                    }
                    return page
                }
                try unchanged(custom, "every old panel's exact dimensions gate migration across all breakpoints")
            }
        }
        let structuralChanges: [(inout [WorkspacePage]) -> Void] = [
            { pages in pages[favoritesIndex].root = .group(id: UUID(), children: [pages[favoritesIndex].root]) },
            { pages in
                guard case .split(let id, let a, let b, _) = pages[favoritesIndex].root else { return }
                pages[favoritesIndex].root = .split(id: id, first: a, second: b, ratio: 0.6)
            },
            { pages in
                guard case .split(let id, let a, let b, let ratio) = pages[favoritesIndex].root else { return }
                pages[favoritesIndex].root = .split(id: id, first: b, second: a, ratio: ratio)
            },
            { pages in
                guard case .verticalStack(let id, let children) = pages[discoveryIndex].root else { return }
                pages[discoveryIndex].root = .verticalStack(id: id, children: children.reversed())
            },
            { pages in
                guard case .verticalStack(let id, let children) = pages[discoveryIndex].root else { return }
                pages[discoveryIndex].root = .verticalStack(id: id, children: children + [.empty(id: UUID())])
            },
            { pages in pages.remove(at: favoritesIndex) },
            { pages in pages[discoveryIndex].id = UUID() },
        ]
        for change in structuralChanges {
            var custom = legacy
            custom.breakpointLayouts[.init(minimumWidth: 1280)] = changedPages(legacy.pages, change)
            try unchanged(custom, "custom structure/order/ratio/missing pages at any breakpoint blocks the pair migration")
        }
        for version in [1, 2] {
            var custom = legacy
            let descriptors = WorkspaceRegistry.builtins.descriptors.map { descriptor in
                descriptor.id == "discovery.recommendations"
                    ? WorkspaceComponentDescriptor(id: descriptor.id, contractVersion: version,
                        defaultSize: descriptor.defaultSize, minimumSize: descriptor.minimumSize, parameterKeys: ["custom"])
                    : descriptor
            }
            func change(_ pages: [WorkspacePage]) -> [WorkspacePage] {
                pages.map { page in
                    var page = page
                    page.root = WorkspaceEditorTree.map(page.root) { node in
                        guard case .component(let id, let type, _, _, let size) = node,
                            type == "discovery.recommendations" else { return node }
                        return .component(id: id, componentID: type, contractVersion: version,
                                          parameters: version == 1 ? ["custom": .bool(true)] : [:], size: size)
                    }
                    return page
                }
            }
            custom.pages = change(custom.pages)
            for key in custom.breakpointLayouts.keys { custom.breakpointLayouts[key] = change(custom.breakpointLayouts[key]!) }
            try unchanged(custom, "modified parameters and contracts are not builtin",
                          validator: WorkspaceValidator(registry: WorkspaceRegistry(descriptors)))
        }
        var baseOnly = legacy
        baseOnly.breakpointLayouts = [:]
        try store.save(baseOnly)
        guard case .loaded(let baseMigrated) = store.load() else { fatalError("base-only migration failed") }
        check(WorkspaceLayoutTraversal.componentTypes(in: baseMigrated).values.contains("discovery.feed"),
              "a legacy layout without breakpoints also migrates")
        var previous = WorkspaceBuiltinLayouts.makeDefault()
        func previousPages(_ pages: [WorkspacePage]) -> [WorkspacePage] {
            pages.map { original in
                guard original.id == WorkspacePageID.discover, case .verticalStack(let id, let children) = original.root,
                    case .component(let trendID, let type, let version, let parameters, let size) = children[0] else { return original }
                var page = original
                page.root = .verticalStack(id: id, children: [
                    .component(id: trendID, componentID: type, contractVersion: version, parameters: parameters,
                               size: .init(width: size.width, height: 280)), children[2]])
                return page
            }
        }
        previous.pages = previousPages(previous.pages)
        previous.breakpointLayouts = [.init(minimumWidth: 960): previous.pages, .init(minimumWidth: 1280): previous.pages]
        previous.homePageID = WorkspacePageID.favorites
        previous.hiddenPageIDs.insert(WorkspacePageID.search)
        previous.collapsedInstanceIDs = ids(previous.pages)
        try store.save(previous)
        guard case .loaded(let newHome) = store.load() else { fatalError("two-panel builtin migration failed") }
        check(ids(newHome.pages).isSuperset(of: ids(previous.pages)), "two-panel migration preserves every existing component identity")
        check(newHome.collapsedInstanceIDs == previous.collapsedInstanceIDs && newHome.homePageID == previous.homePageID
            && newHome.hiddenPageIDs == previous.hiddenPageIDs, "two-panel navigation/collapse settings survive")
        let newHistory = Set(WorkspaceLayoutTraversal.componentTypes(in: newHome).filter { $0.value == "playback.continue" }.keys)
        check(newHistory.count == 1, "two-panel migration shares one history identity")
        for pages in newHome.breakpointLayouts.values {
            check(ids(pages).isSuperset(of: ids(previous.pages).union(newHistory)), "two-panel identities survive every breakpoint")
        }
        guard case .loaded(let reopenedHome) = store.load() else { fatalError("new home reopen failed") }
        check(reopenedHome == newHome, "two-panel migration is idempotent")
        var customHome = previous
        customHome.breakpointLayouts[.init(minimumWidth: 1280)] = previous.pages.map { original in
            guard original.id == WorkspacePageID.discover, case .verticalStack(let id, let children) = original.root,
                case .component(let trendID, let type, let version, let parameters, var size) = children[0] else { return original }
            var page = original; size.height += 1
            page.root = .verticalStack(id: id, children: [
                .component(id: trendID, componentID: type, contractVersion: version, parameters: parameters, size: size), children[1]])
            return page
        }
        try unchanged(customHome, "custom two-panel breakpoint is never overwritten")
        try unchanged(WorkspaceBuiltinLayouts.makeDefault(), "latest builtin layout needs no migration")
        print("PASS discovery layout migration smoke: exact legacy shapes, all breakpoints, stable IDs/settings, atomic reopen/idempotence, custom dimensions/structure/contracts/parameters untouched")
    }

    static func instanceStateRegression(directory: URL) throws {
        let file = directory.appendingPathComponent("private/instance-state-v1.json")
        let firstID = UUID(), secondID = UUID()
        let first = WorkspaceInstanceState(
            query: "first private query", filter: "all|girigiri", page: 3,
            selection: "first private selection", scrollPosition: 42.5, density: 1)
        let second = WorkspaceInstanceState(
            query: "second private query", filter: "video|bilibili", page: 8,
            selection: "second private selection", scrollPosition: 216.25, density: 2)
        let owner = try WorkspaceSessionState(storeURL: file)

        try owner.update(first, for: firstID)
        try owner.update(second, for: secondID)
        var revisedFirst = first
        revisedFirst.page = 4
        try owner.update(revisedFirst, for: firstID)
        let reopened = try WorkspaceSessionState(storeURL: file)
        check(reopened.allInstanceIDs() == Set([firstID, secondID]), "reopen preserves both UUID namespaces")
        check(reopened.state(for: firstID) == revisedFirst && reopened.state(for: secondID) == second,
              "fresh owner restores every instance field without swapping duplicate-component state")


        let secondNode = WorkspaceNode.component(
            id: secondID, componentID: "search.results", contractVersion: 1, parameters: [:],
            size: .init(width: 480, height: 480))
        let retainedLayout = WorkspaceLayout(
            pages: [WorkspacePage(title: "Discovery", root: .component(
                id: firstID, componentID: "search.results", contractVersion: 1, parameters: [:],
                size: .init(width: 480, height: 480)))],
            breakpointLayouts: [.init(minimumWidth: 960): [WorkspacePage(title: "Search", root: secondNode)]])


        try reopened.remove(firstID)
        let afterRemoval = try WorkspaceSessionState(storeURL: file)
        check(afterRemoval.allInstanceIDs() == Set([secondID]) && afterRemoval.state(for: secondID) == second,
              "explicit removal persists without changing its neighbor")
        try afterRemoval.retainInstances(in: retainedLayout)
        let breakpointReopen = try WorkspaceSessionState(storeURL: file)
        check(breakpointReopen.state(for: secondID) == second,
              "pruning retains identities present only at a breakpoint")
        try breakpointReopen.retainInstances(in: WorkspaceLayout(pages: []))
        let afterPrune = try WorkspaceSessionState(storeURL: file)
        check(afterPrune.allInstanceIDs().isEmpty, "pruned state stays removed after reopen")

        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: file, options: .atomic)
        do {
            _ = try WorkspaceSessionState(storeURL: file)
            fatalError("corrupt private state silently became an empty store")
        } catch is DecodingError {}
        let corruptRetained = try Data(contentsOf: file)
        check(corruptRetained == corrupt, "corrupt private state is not overwritten on load")
        let unsupported = Data("{\"schemaVersion\":99,\"instances\":[]}".utf8)
        try unsupported.write(to: file, options: .atomic)
        do {
            _ = try WorkspaceSessionState(storeURL: file)
            fatalError("unsupported private state silently became an empty store")
        } catch WorkspaceSessionStateError.unsupportedSchema(99) {}
        let unsupportedRetained = try Data(contentsOf: file)
        check(unsupportedRetained == unsupported, "unsupported private state remains repairable")

        let failedURL = directory.appendingPathComponent("blocked-state.json")
        let failedOwner = try WorkspaceSessionState(storeURL: failedURL)
        try FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: true)
        do {
            try failedOwner.update(first, for: firstID)
            fatalError("private state write failure was not reported")
        } catch {
            check(failedOwner.state(for: firstID) == first, "disk failure preserves current UI intent in memory")
        }
        print("PASS W8.1 durable instance state: independent UUID reopen, all private fields, removal/pruning, breakpoint identity retention and explicit corrupt/version/write failures")
    }
    static func paneCountRegression(layout: WorkspaceLayout, validator: WorkspaceValidator) throws {
        let registry = WorkspaceRegistry.builtins
        let favorite = layout.pages.first { $0.id == WorkspacePageID.favorites }!
        let original = favoriteSplit(favorite)
        let originalPanes = WorkspaceEditorTree.panes(original)
        func container(_ editor: WorkspaceLayoutEditor) -> WorkspaceNode {
            WorkspaceEditorTree.find(original.id, in: editor.pages)!
        }
        for count in [1, 2, 3, 5, 8] {
            let editor = WorkspaceLayoutEditor(layout: layout, registry: registry)
            try editor.setPaneCount(nodeID: original.id, count: count)
            let changed = editor.layout
            let node = container(editor)
            let panes = WorkspaceEditorTree.panes(node)
            check(node.id == original.id && panes.count == count,
                  "requested pane count preserves the selected container identity")
            for child in originalPanes {
                check(WorkspaceEditorTree.find(child.id, in: editor.pages) == child,
                      "changing pane count retains complete original child values and identities")
            }
            check(editor.pages.filter { $0.id != favorite.id } == layout.pages.filter { $0.id != favorite.id },
                  "changing favorites columns leaves every other page unchanged")
            if count == 1 {
                guard case .horizontalStack(_, let children) = node, children.count == 1,
                      case .verticalStack(_, let overflow) = children[0] else {
                    fatalError("one pane must retain a container around vertically grouped overflow")
                }
                check(overflow == originalPanes, "one pane retains both original panels in order")
            } else if count > 2 {
                check(Array(panes.prefix(2)) == originalPanes, "expansion keeps existing panes first")
                check(panes.dropFirst(2).allSatisfy { if case .empty = $0 { return true }; return false },
                      "expansion appends genuine empty drop targets")
                var remainder = node
                for remaining in stride(from: count, through: 2, by: -1) {
                    guard case .split(_, _, let second, let ratio) = remainder else {
                        fatalError("multiple columns must use nested draggable splits")
                    }
                    check(abs(ratio - 1 / Double(remaining)) < 0.000_001,
                          "right-associated split ratios give every new column equal width")
                    remainder = second
                }
                let identities = panes.map(\.id)
                check(Set(identities).count == count, "new slots have distinct stable identities")
            }
            let reopened = try WorkspaceLayoutCodec.decode(
                WorkspaceLayoutCodec.encode(changed, validator: validator), validator: validator)
            check(reopened == changed && reopened.schemaVersion == layout.schemaVersion,
                  "all pane counts roundtrip in the existing schema without migration")
            if count == 2 {
                check(changed == layout && !editor.canUndo, "unchanged count does not create undo history")
            } else {
                editor.undo()
                check(editor.layout == layout && !editor.canUndo, "pane count change is exactly one undo")
                try editor.setPaneCount(nodeID: original.id, count: 2)
                check(editor.canRedo, "unchanged pane count does not discard redo history")
                editor.redo()
                check(editor.layout == changed, "redo restores exact generated container and slot identities")
            }
        }

        let editor = WorkspaceLayoutEditor(layout: layout, registry: registry)
        try editor.replace(nodeID: original.id) { node in
            guard case .split(let id, let first, let second, _) = node else { fatalError("split missing") }
            return .split(id: id, first: first, second: second, ratio: 0.65)
        }
        let customRatio = editor.layout
        try editor.setPaneCount(nodeID: original.id, count: 2)
        check(editor.layout == customRatio, "unchanged count preserves user-adjusted split ratios")
        editor.undo()
        check(editor.layout == layout && !editor.canUndo, "unchanged ratios do not add a second undo")
        try editor.setPaneCount(nodeID: original.id, count: 5)
        let expanded = editor.layout
        let expandedPanes = WorkspaceEditorTree.panes(container(editor))
        try editor.setPaneCount(nodeID: original.id, count: 3)
        let reducedPanes = WorkspaceEditorTree.panes(container(editor))
        guard case .verticalStack(_, let overflow) = reducedPanes[2] else { fatalError("overflow missing") }
        check(Array(reducedPanes.prefix(2)) == Array(expandedPanes.prefix(2)) &&
              overflow == Array(expandedPanes.dropFirst(2)),
              "shrinking retains every overflow slot in the final column without changing child IDs")
        let reduced = editor.layout
        editor.undo(); check(editor.layout == expanded, "shrink undo restores all five independent columns")
        editor.redo(); check(editor.layout == reduced, "shrink redo retains overflow grouping identity")
        for count in [0, -1, validator.maximumNodes + 1, validator.maximumDepth + 1, Int.max] {
            do {
                try editor.setPaneCount(nodeID: original.id, count: count)
                fatalError("invalid pane count accepted")
            } catch WorkspaceTransactionError.invalidDestination {
                check(count < 1, "only nonpositive counts use the destination error")
            } catch WorkspaceValidationError.tooManyNodes {
                check(count > validator.maximumNodes, "existing node cap rejects excessive counts")
            } catch WorkspaceValidationError.excessiveDepth {
                check(count > validator.maximumDepth, "existing nesting cap rejects overdeep split trees")
            }
            check(editor.layout == reduced, "invalid pane count leaves the entire draft unchanged")
        }
        editor.undo()
        check(editor.layout == expanded, "invalid pane counts do not consume or add undo entries")
        let boundaryNode = WorkspaceNode.horizontalStack(id: UUID(), children: [.empty(id: UUID())])
        let boundaryEditor = WorkspaceLayoutEditor(
            layout: WorkspaceLayout(pages: [WorkspacePage(title: "Boundary", root: boundaryNode)]), registry: registry)
        try boundaryEditor.setPaneCount(nodeID: boundaryNode.id, count: validator.maximumDepth)
        let atBoundary = boundaryEditor.layout
        check(WorkspaceEditorTree.panes(boundaryEditor.pages[0].root).count == validator.maximumDepth,
              "the existing depth limit permits the largest root-level pane tree")
        do {
            try boundaryEditor.setPaneCount(nodeID: boundaryNode.id, count: validator.maximumDepth + 1)
            fatalError("pane count exceeding existing depth cap accepted")
        } catch WorkspaceValidationError.excessiveDepth {}
        check(boundaryEditor.layout == atBoundary, "one count beyond the depth boundary rejects atomically")
        boundaryEditor.undo()
        check(!boundaryEditor.canUndo, "rejected boundary count does not create undo history")

        let leaves: [WorkspaceNode] = (0..<4).map { _ in .empty(id: UUID()) }
        for kind in [WorkspaceContainerKind.horizontalStack, .verticalStack, .group, .grid] {
            let node = WorkspaceEditorTree.container(kind, children: leaves)
            let page = WorkspacePage(title: "Columns", root: node)
            let initial = WorkspaceLayout(pages: [page])
            let converted = WorkspaceLayoutEditor(layout: initial, registry: registry)
            try converted.setPaneCount(nodeID: node.id, count: 3)
            let panes = WorkspaceEditorTree.panes(converted.pages[0].root)
            guard case .verticalStack(_, let overflow) = panes[2] else { fatalError("conversion overflow missing") }
            check(panes.count == 3 && Array(panes.prefix(2)) == Array(leaves.prefix(2)) &&
                  overflow == Array(leaves.suffix(2)), "each arrangement converts to columns while preserving overflow")
            converted.undo(); check(converted.layout == initial, "arrangement conversion is one undo")
            try converted.setPaneCount(nodeID: node.id, count: 4)
            check(WorkspaceEditorTree.panes(converted.pages[0].root) == leaves,
                  "matching child count preserves contents when converting an arrangement to columns")
            if kind != .horizontalStack {
                guard case .split = converted.pages[0].root else { fatalError("arrangement must become visible columns") }
            }
        }
        let vertical = WorkspaceNode.verticalStack(id: UUID(), children: Array(leaves.prefix(2)))
        let nested = WorkspaceNode.split(id: UUID(), first: vertical,
            second: .horizontalStack(id: UUID(), children: Array(leaves.suffix(2))), ratio: 0.4)
        check(WorkspaceEditorTree.panes(nested) == [vertical] + Array(leaves.suffix(2)),
              "pane traversal keeps vertical content together and expands horizontal children")
        let leftAssociated = WorkspaceNode.split(id: UUID(),
            first: .split(id: UUID(), first: leaves[0], second: leaves[1], ratio: 0.6),
            second: leaves[2], ratio: 0.7)
        check(WorkspaceEditorTree.panes(leftAssociated) == Array(leaves.prefix(3)),
              "pane traversal accepts existing left-associated split trees")
        let breakpointEditor = WorkspaceLayoutEditor(layout: layout, registry: registry)
        try breakpointEditor.addBreakpoint(width: 1440)
        let beforeBreakpointEdit = breakpointEditor.layout
        try breakpointEditor.setPaneCount(nodeID: original.id, count: 4)
        check(breakpointEditor.layout.pages == beforeBreakpointEdit.pages,
              "pane count editing leaves the base layout unchanged at a selected breakpoint")
        for (key, pages) in beforeBreakpointEdit.breakpointLayouts where key != breakpointEditor.breakpoint {
            check(breakpointEditor.layout.breakpointLayouts[key] == pages,
                  "pane count editing leaves other breakpoint versions unchanged")
        }
        check(WorkspaceEditorTree.panes(container(breakpointEditor)).count == 4,
              "selected breakpoint receives the requested visible column count")
        breakpointEditor.undo()
        check(breakpointEditor.layout == beforeBreakpointEdit, "breakpoint pane count is exactly one undo")
        print("PASS multi-column layout: counts 1–8, draggable equal splits, child identity, retained overflow, arrangement conversion, schema roundtrip, ratio no-op, undo/redo and breakpoint isolation")
    }

    static func editorRegression(layout: WorkspaceLayout, workID: UUID, linkID: UUID,
                                 store: WorkspaceStore, file: URL, validator: WorkspaceValidator) throws {
        try paneCountRegression(layout: layout, validator: validator)
        try store.save(layout)
        let committedBytes = try Data(contentsOf: file)
        let editor = WorkspaceLayoutEditor(layout: layout, registry: WorkspaceRegistry.builtins)
        try editor.addPage(title: "編排測試")
        let destination = editor.pages.last!.id
        let beforeMove = editor.layout
        try editor.move(nodeID: workID, to: destination, index: Int.max)
        check(WorkspaceEditorTree.find(workID, in: [editor.pages.last!])?.id == workID, "cross-page drop preserves instance")
        let afterMove = editor.layout
        editor.undo()
        check(editor.layout == beforeMove, "one completed gesture has exactly one undo across pages")
        editor.redo()
        check(editor.layout == afterMove, "cross-page redo restores the complete transaction")
        let beforeFailure = editor.layout
        do {
            try editor.move(nodeID: workID, to: workID, index: 0)
            fatalError("cyclic drop accepted")
        } catch WorkspaceTransactionError.invalidDestination {}
        check(editor.layout == beforeFailure, "invalid drop leaves draft and history unchanged")
        try editor.setHome(destination)
        try editor.toggleHidden(WorkspacePageID.search)
        try editor.toggleCollapsed(workID)
        check(editor.layout.homePageID == destination && editor.layout.hiddenPageIDs.contains(WorkspacePageID.search), "home and navigation hiding are presentation state")
        try editor.replace(nodeID: workID) { node in
            guard case .component(let id, let type, let version, let parameters, _) = node else { fatalError("component missing") }
            return .component(id: id, componentID: type, contractVersion: version, parameters: parameters, size: .init(width: 512, height: 576))
        }
        let sized = editor.layout
        do {
            try editor.replace(nodeID: workID) { node in
                guard case .component(let id, let type, let version, let parameters, _) = node else { fatalError("component missing") }
                return .component(id: id, componentID: type, contractVersion: version, parameters: parameters, size: .init(width: 1, height: 1))
            }
            fatalError("invalid editor size accepted")
        } catch WorkspaceValidationError.invalidSize("favorites.works") {}
        check(editor.layout == sized, "registry size validation rejects atomically")
        for kind in WorkspaceContainerKind.allCases where kind != .page {
            let container = WorkspaceEditorTree.container(kind, children: [])
            try editor.insert(container, to: destination)
            try editor.move(nodeID: workID, to: container.id, index: 0)
            check(WorkspaceEditorTree.find(workID, in: editor.pages) != nil, "container (kind) must retain component identity")
            try validator.validate(editor.layout)
            editor.undo(); editor.undo()
        }
        let splitEditor = WorkspaceLayoutEditor(layout: layout, registry: WorkspaceRegistry.builtins)
        let favorite = splitEditor.pages.first { $0.id == WorkspacePageID.favorites }!
        let split = favoriteSplit(favorite)
        try splitEditor.move(nodeID: linkID, to: split.id, index: 0)
        guard case .split(_, let first, let second, _) = favoriteSplit(splitEditor.pages.first(where: { $0.id == favorite.id })!) else { fatalError("split lost") }
        check(first.id == linkID && second.id == workID, "keyboard reorder swaps split slots without copying")
        splitEditor.undo(); check(splitEditor.layout == layout, "split reorder is one undo")
        try splitEditor.move(nodeID: workID, relativeTo: linkID, after: false)
        check(splitEditor.layout == layout && !splitEditor.canUndo,
              "dropping the first split child before the second is a no-op without undo history")
        try splitEditor.move(nodeID: linkID, relativeTo: workID, after: true)
        check(splitEditor.layout == layout && !splitEditor.canUndo,
              "dropping the second split child after the first is a no-op")
        try splitEditor.move(nodeID: workID, relativeTo: linkID, after: true)
        guard case .split(_, let movedFirst, let movedSecond, _) =
                favoriteSplit(splitEditor.pages.first(where: { $0.id == favorite.id })!) else { fatalError("split lost") }
        check(movedFirst.id == linkID && movedSecond.id == workID,
              "canvas after-boundary swaps split children without losing identities")
        splitEditor.undo()
        check(splitEditor.layout == layout && !splitEditor.canUndo, "canvas split move is exactly one undo")
        let beforeInvalidDrop = splitEditor.layout
        do {
            try splitEditor.move(nodeID: split.id, relativeTo: workID, after: true)
            fatalError("ancestor dropped beside its descendant")
        } catch WorkspaceTransactionError.invalidDestination {}
        check(splitEditor.layout == beforeInvalidDrop && !splitEditor.canUndo,
              "cyclic relative drops preserve the draft and undo history")
        try splitEditor.replace(nodeID: split.id) { node in
            guard case .split(let id, let first, let second, _) = node else { fatalError("split missing") }
            return .split(id: id, first: first, second: second, ratio: 0.65)
        }
        splitEditor.undo(); check(splitEditor.layout == layout, "completed divider drag is one ratio transaction")
        try editor.addBreakpoint(width: 1280)
        let variantBefore = editor.layout.pages
        try editor.renamePage(destination, title: "寬視窗")
        check(editor.layout.pages == variantBefore && editor.pages.last?.title == "寬視窗", "breakpoint editing is isolated from base")
        try editor.removeBreakpoint()
        editor.undo(); check(editor.layout.breakpointLayouts[.init(minimumWidth: 1280)] != nil, "breakpoint removal is reversible")
        let afterPreview = try Data(contentsOf: file)
        check(afterPreview == committedBytes, "editing, preview and cancellation do not write saved bytes")
        try store.save(editor.layout)
        guard case .loaded(let reopened) = store.load() else { fatalError("editor commit did not reopen") }
        check(reopened == editor.layout, "atomic commit preserves navigation, collapse, sizes and breakpoints on reopen")
        let removal = try WorkspaceTransaction.remove(instanceID: workID, from: editor.layout)
        check(!removal.collapsedInstanceIDs.contains(workID), "removing a component prunes its presentation metadata")
        try validator.validate(removal)
        try editor.restore()
        check(editor.layout.pages.map(\.id) == WorkspaceBuiltinLayouts.makeDefault().pages.map(\.id), "restoration returns fixed builtin pages")
        editor.undo(); check(editor.layout == reopened, "restore is reversible across all pages")
        print("PASS W8.4 layout editor: validated tree/container drops, gesture undo/redo, keyboard split order, dimensions, navigation/collapse, breakpoint isolation, draft byte isolation, atomic reopen and restore")
    }
}
