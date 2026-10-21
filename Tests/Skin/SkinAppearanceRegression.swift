import AppKit
import Foundation

@main
@MainActor
struct SkinAppearanceRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure(message)
        } catch {
            // The fixture is expected to fail validation.
        }
    }

    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("skin-test-\(UUID().uuidString)", isDirectory: true)
        let root = temporary.appendingPathComponent("primary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p6sAAAAASUVORK5CYII="
        )!
        for name in ["pixel.png", "author-hover.png", "personal.png", "personal-hover.png"] {
            try png.write(to: root.appendingPathComponent(name))
        }
        let manifest = SkinManifest(
            id: "sample", version: "1.0", name: "Sample", license: "CC0-1.0",
            assets: [
                "hero": "pixel.png", "authorHover": "author-hover.png",
                "personal": "personal.png", "personalHover": "personal-hover.png",
            ])
        let theme = SkinTheme(
            light: [
                "spacing": .number(12), "foreground": .string("#111111"),
                "background": .string("#FFFFFF"),
            ],
            dark: [
                "spacing": .number(16), "foreground": .string("#FFFFFF"),
                "background": .string("#111111"),
            ])
        let allStates: [String: [String: SkinJSONValue]] = [
            "normal": ["radius": .number(5), "iconAsset": .string("hero")],
            "hover": ["radius": .number(8)],
            "pressed": ["radius": .number(9)],
            "selected": ["radius": .number(10)],
            "focus": ["radius": .number(11)],
            "disabled": ["opacity": .number(0.5)],
            "loading": ["radius": .number(13)],
            "error": ["radius": .number(14)],
        ]
        let components = SkinComponents(
            slots: [
                "list": SkinSlotStyle(values: ["radius": .number(4)], states: allStates),
                "primaryAction": SkinSlotStyle(states: [
                    "normal": ["iconAsset": .string("hero")],
                    "hover": ["iconAsset": .string("authorHover")],
                ]),
            ],
            overrides: ["search.results": ["list": SkinSlotStyle(values: ["spacing": .number(20)])]]
        )
        let package = SkinPackage(
            manifest: manifest, theme: theme, components: components, directoryURL: root)
        try writePackage(package, to: root)

        let appearance = try SkinAppearance(package: package, scheme: .light)
        check(appearance.resolve(slot: .list).radius == 5, "normal state overrides slot base")
        check(
            appearance.resolve(slot: .list, state: .hover).radius == 8,
            "hover state overrides normal")
        check(
            appearance.resolve(slot: .list, state: .pressed).radius == 9, "pressed state resolves")
        check(
            appearance.resolve(slot: .list, state: .selected).radius == 10,
            "selected state resolves")
        check(appearance.resolve(slot: .list, state: .focus).radius == 11, "focus state resolves")
        check(
            appearance.resolve(slot: .list, state: .disabled).values["opacity"] == .number(0.5),
            "disabled state resolves")
        check(
            appearance.resolve(slot: .list, state: .loading).radius == 13, "loading state resolves")
        check(appearance.resolve(slot: .list, state: .error).radius == 14, "error state resolves")
        check(
            appearance.resolve(slot: .list).spacing == 12,
            "theme values are inherited beneath slot styles")
        check(
            appearance.resolve(slot: .list, componentID: "search.results").spacing == 20,
            "component override wins over general slot")
        check(
            appearance.resolve(slot: .list, state: .hover).assetIDs[.icon] == "hero",
            "grouped assets fall back to normal state")

        let personal = SkinPersonalOverrides(
            theme: ["spacing": .number(22)],
            slots: [
                "list": SkinSlotStyle(
                    values: ["spacing": .number(24)],
                    states: ["pressed": ["radius": .number(25)]])
            ])
        let personalAppearance = try SkinAppearance(
            package: package, overrides: personal, scheme: .light)
        check(
            personalAppearance.resolve(slot: .list).spacing == 24,
            "personal slot overrides outrank personal theme and Skin styles")
        check(
            personalAppearance.resolve(slot: .list, state: .pressed).radius == 25,
            "personal state override wins the state cascade")

        let personalGroup = SkinPersonalOverrides(slots: [
            "primaryAction": SkinSlotStyle(states: [
                "normal": ["iconAsset": .string("personal")]
            ])
        ])
        let personalGroupAppearance = try SkinAppearance(
            package: package, overrides: personalGroup, scheme: .light)
        check(
            personalGroupAppearance.resolve(slot: .primaryAction, state: .hover).assetIDs[.icon]
                == "personal", "personal normal asset replaces author state group")
        let explicitGroup = SkinPersonalOverrides(slots: [
            "primaryAction": SkinSlotStyle(states: [
                "normal": ["iconAsset": .string("personal")],
                "hover": ["iconAsset": .string("personalHover")],
            ])
        ])
        let explicitGroupAppearance = try SkinAppearance(
            package: package, overrides: explicitGroup, scheme: .light)
        check(
            explicitGroupAppearance.resolve(slot: .primaryAction, state: .hover).assetIDs[.icon]
                == "personalHover", "explicit personal state asset wins within replacement group")
        let componentGroup = SkinComponents(
            slots: components.slots,
            overrides: [
                "search.results": [
                    "primaryAction": SkinSlotStyle(states: [
                        "normal": ["iconAsset": .string("personal")]
                    ])
                ]
            ])
        let componentGroupPackage = SkinPackage(
            manifest: manifest, theme: theme, components: componentGroup, directoryURL: root)
        try writePackage(componentGroupPackage, to: root)
        let componentGroupAppearance = try SkinAppearance(
            package: componentGroupPackage, scheme: .light)
        check(
            componentGroupAppearance.resolve(
                slot: .primaryAction, componentID: "search.results", state: .hover
            ).assetIDs[.icon] == "personal", "component normal asset replaces shared slot states")
        try writePackage(package, to: root)

        let image1 = appearance.image(
            assetID: "hero", scale: 1, targetSize: NSSize(width: 20, height: 20))
        let image2 = appearance.image(
            assetID: "hero", scale: 1, targetSize: NSSize(width: 20, height: 20))
        check(image1 != nil && image1 === image2, "decoded image is shared from the owner cache")
        let previousRevision = appearance.revision
        try appearance.apply(package: package, scheme: .light)
        let image3 = appearance.image(
            assetID: "hero", scale: 1, targetSize: NSSize(width: 20, height: 20))
        check(
            appearance.revision > previousRevision && image3 != nil && image3 !== image1,
            "replacement revision invalidates image and style caches")
        let beforeFailure = appearance.revision
        let invalidPackage = SkinPackage(
            manifest: SkinManifest(
                id: "bad", version: "1", name: "Bad", license: "MIT",
                assets: ["icon": "../escape.png"]),
            theme: theme, components: components, directoryURL: root)
        expectFailure("unsafe asset path accepted") {
            try appearance.apply(package: invalidPackage)
        }
        check(
            appearance.revision == beforeFailure, "failed apply leaves active appearance unchanged")

        appearance.setColorScheme(.dark)
        check(
            appearance.effectiveColorScheme == .dark
                && appearance.resolve(slot: .list).spacing == 16, "dark variant selection")

        let singleRoot = temporary.appendingPathComponent("single", isDirectory: true)
        try FileManager.default.createDirectory(at: singleRoot, withIntermediateDirectories: true)
        let single = SkinPackage(
            manifest: SkinManifest(
                id: "single", version: "1", name: "Single", license: "MIT",
                supportedVariants: [.light]),
            theme: SkinTheme(light: [:]), directoryURL: singleRoot)
        try writePackage(single, to: singleRoot)
        expectFailure("undeclared variant accepted") {
            _ = try SkinAppearance(package: single, scheme: .dark)
        }
        let singleAppearance = try SkinAppearance(package: single, scheme: .light)
        singleAppearance.setColorScheme(.dark)
        check(
            singleAppearance.effectiveColorScheme == .light,
            "missing variant preserves prior appearance")
        check(
            singleAppearance.selectionError == .missingVariant(.dark), "missing variant is surfaced"
        )

        let minimalRoot = temporary.appendingPathComponent("minimal", isDirectory: true)
        try FileManager.default.createDirectory(at: minimalRoot, withIntermediateDirectories: true)
        let minimal = SkinPackage(
            manifest: SkinManifest(id: "minimal", version: "1", name: "Minimal", license: "MIT"),
            theme: SkinTheme(light: [:], dark: [:], system: ["spacing": .number(12)]),
            components: SkinComponents(slots: ["list": SkinSlotStyle()]), directoryURL: minimalRoot)
        try writePackage(minimal, to: minimalRoot)
        _ = try SkinPackageValidator.validate(directoryURL: minimalRoot)
        _ = try SkinAppearance(package: minimal, scheme: .light)

        let warningRoot = temporary.appendingPathComponent("warning", isDirectory: true)
        try FileManager.default.createDirectory(at: warningRoot, withIntermediateDirectories: true)
        let warningPackage = SkinPackage(
            manifest: SkinManifest(id: "warning", version: "1", name: "Warning", license: "MIT"),
            theme: SkinTheme(light: [
                "foreground": .string("#FFFFFF"), "background": .string("#FFFFFF"),
            ]),
            directoryURL: warningRoot)
        try writePackage(warningPackage, to: warningRoot)
        let warningAppearance = try SkinAppearance(package: warningPackage, scheme: .light)
        _ = warningAppearance.resolve(slot: .list)
        _ = warningAppearance.resolve(slot: .list)
        check(warningAppearance.contrastWarnings.count == 1, "contrast warning is deduplicated")
        check(
            abs(warningAppearance.contrastWarnings[0].ratio - 1) < 0.001,
            "contrast warning reports actual ratio")

        let builtin = SkinAppearance()
        builtin.setColorScheme(.light)
        let lightBuiltin = builtin.resolve(slot: .list)
        check(
            contrast(lightBuiltin.foreground, lightBuiltin.background) >= 4.5,
            "built-in light palette meets text AA")
        check(
            contrast(lightBuiltin.borderColor, lightBuiltin.background) >= 3.0,
            "built-in light border meets non-text contrast")
        builtin.setColorScheme(.dark)
        let darkBuiltin = builtin.resolve(slot: .list)
        check(
            contrast(darkBuiltin.foreground, darkBuiltin.background) >= 4.5,
            "built-in dark palette meets text AA")
        check(
            contrast(darkBuiltin.borderColor, darkBuiltin.background) >= 3.0,
            "built-in dark border meets non-text contrast")

        try writePackage(package, to: root)
        let staged = try SkinPackageValidator.validate(directoryURL: root)
        let digestBefore = try SkinPackageCodec.contentDigest(for: staged)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("pixel.png"))
        let digestAfter = try SkinPackageCodec.contentDigest(for: package)
        check(digestBefore != digestAfter, "asset bytes participate in streamed content digest")
        try png.write(to: root.appendingPathComponent("pixel.png"))

        try Data("{\"light\":{},\"dark\":{},\"privatePayload\":true}".utf8)
            .write(to: root.appendingPathComponent("theme.json"))
        expectFailure("unknown theme document field accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }
        try writePackage(package, to: root)
        try Data(
            "{\"slots\":{\"list\":{\"values\":{},\"states\":{},\"secret\":true}},\"overrides\":{}}"
                .utf8
        )
        .write(to: root.appendingPathComponent("components.json"))
        expectFailure("unknown nested component field accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }
        let unknownState = SkinComponents(slots: ["list": SkinSlotStyle(states: ["hovered": [:]])])
        let unknownStatePackage = SkinPackage(
            manifest: manifest, theme: theme, components: unknownState, directoryURL: root)
        try writePackage(unknownStatePackage, to: root)
        expectFailure("unknown state accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }
        let unknownSlot = SkinPackage(
            manifest: manifest, theme: theme,
            components: SkinComponents(slots: ["unknownSlot": SkinSlotStyle()]), directoryURL: root)
        try writePackage(unknownSlot, to: root)
        expectFailure("unknown component slot accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }
        let unknownComponent = SkinPackage(
            manifest: manifest, theme: theme,
            components: SkinComponents(overrides: ["private.component": ["list": SkinSlotStyle()]]),
            directoryURL: root)
        try writePackage(unknownComponent, to: root)
        expectFailure("unknown component id accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }
        let missingNormal = SkinPackage(
            manifest: manifest, theme: theme,
            components: SkinComponents(slots: [
                "list": SkinSlotStyle(states: ["hover": ["iconAsset": .string("hero")]])
            ]),
            directoryURL: root)
        try writePackage(missingNormal, to: root)
        expectFailure("state image asset without normal fallback accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: root)
        }

        let invalidImageRoot = temporary.appendingPathComponent("invalid-image", isDirectory: true)
        try FileManager.default.createDirectory(
            at: invalidImageRoot, withIntermediateDirectories: true)
        let invalidImage = SkinPackage(
            manifest: SkinManifest(
                id: "invalid-image", version: "1", name: "Invalid", license: "MIT",
                assets: ["image": "pixel.png"]), theme: theme, directoryURL: invalidImageRoot)
        try writePackage(invalidImage, to: invalidImageRoot)
        try Data("not an image".utf8).write(
            to: invalidImageRoot.appendingPathComponent("pixel.png"))
        expectFailure("corrupt image accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: invalidImageRoot)
        }

        let invalidFontRoot = temporary.appendingPathComponent("invalid-font", isDirectory: true)
        try FileManager.default.createDirectory(
            at: invalidFontRoot, withIntermediateDirectories: true)
        let invalidFont = SkinPackage(
            manifest: SkinManifest(
                id: "font", version: "1", name: "Font", license: "MIT",
                assets: ["font.body": "font.otf"], assetAttributions: ["font.body": "OFL-1.1"]),
            theme: SkinTheme(), directoryURL: invalidFontRoot)
        try writePackage(invalidFont, to: invalidFontRoot)
        try Data([0x4F, 0x54, 0x54, 0x4F, 0, 0, 0, 0]).write(
            to: invalidFontRoot.appendingPathComponent("font.otf"))
        expectFailure("corrupt font accepted") {
            _ = try SkinPackageValidator.validate(directoryURL: invalidFontRoot)
        }

        try imageBounds(temporary)
        try pageMotionPrecedence(temporary)
        print("Skin appearance regressions passed")
    }

    private static func pageMotionPrecedence(_ temporary: URL) throws {
        let root = temporary.appendingPathComponent("page-motion", isDirectory: true)
        let path = "motions/page.xml"
        let motionURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: motionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = SkinManifest(
            id: "page-motion", version: "1", name: "Motion", license: "MIT",
            entryPaths: ["pageMotion": path])
        let package = SkinPackage(
            manifest: manifest, theme: SkinTheme(), pageMotion: .fade, directoryURL: root)
        try writePackage(package, to: root)
        let fadeXML = Data(
            """
            <pageMotion version="1" duration="0.2" opacity="0" offsetX="0" offsetY="0" scale="1" curve="easeOut"/>
            """.utf8)
        try fadeXML.write(to: motionURL)
        let appearance = try SkinAppearance(package: package, scheme: .light)
        let inherited = WorkspacePage(title: "Inherited", root: .empty(id: UUID()))
        let explicit = WorkspacePage(title: "Explicit", root: .empty(id: UUID()), motion: .zoom)
        check(
            appearance.pageMotion(for: inherited) == .fade,
            "neutral page inherits the selected Skin XML default")
        check(
            appearance.pageMotion(for: explicit) == .zoom,
            "explicit page motion outranks the Skin XML default")
        appearance.setColorScheme(.dark)
        check(
            appearance.pageMotion(for: inherited) == .fade,
            "Skin motion default is independent of the selected color variant")

        let disabled = SkinPackage(
            manifest: manifest, theme: SkinTheme(), pageMotion: WorkspacePageMotion.none,
            directoryURL: root)
        try Data(
            """
            <pageMotion version="1" duration="0" opacity="1" offsetX="0" offsetY="0" scale="1" curve="easeOut"/>
            """.utf8).write(to: motionURL)
        try appearance.apply(package: disabled)
        check(
            appearance.pageMotion(for: inherited) == .none,
            "none XML disables the Skin default after replacing an animated Skin")
        check(
            appearance.pageMotion(for: explicit) == .zoom,
            "none XML does not override explicit page motion")

        try fadeXML.write(to: motionURL)
        try appearance.apply(package: package)
        try appearance.apply(package: nil)
        check(
            appearance.pageMotion(for: inherited) == .none,
            "builtin reset removes the prior Skin default")
        check(
            appearance.pageMotion(for: explicit) == .zoom,
            "builtin reset leaves explicit Layout motion in force")

        try appearance.apply(package: package)
        try FileManager.default.removeItem(at: motionURL)
        let legacy = SkinPackage(
            manifest: SkinManifest(id: "legacy-motion", version: "1", name: "Legacy", license: "MIT"),
            theme: SkinTheme(), directoryURL: root)
        try writePackage(legacy, to: root)
        try appearance.apply(package: legacy)
        check(
            appearance.pageMotion(for: inherited) == .none
                && appearance.pageMotion(for: explicit) == .zoom,
            "legacy Skin without XML preserves prior Layout-only behavior")
    }

    private static func imageBounds(_ root: URL) throws {
        let dir = root.appendingPathComponent("image-bounds")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let package = SkinPackage(
            manifest: SkinManifest(
                id: "image-bounds", version: "1", name: "Bounds", license: "CC0",
                assets: ["image": "image.png"]), theme: SkinTheme(), directoryURL: dir)
        try writePackage(package, to: dir)
        for (width, height, accepted) in [
            (8192, 1, true), (8193, 1, false), (8000, 8000, true), (8192, 8192, false),
        ] {
            try autoreleasepool {
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                    samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                    colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.bitmapData!.initialize(repeating: 127, count: bitmap.bytesPerRow * height)
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: dir.appendingPathComponent("image.png"))
                if accepted {
                    let valid = try SkinPackageValidator.validate(directoryURL: dir)
                    let appearance = try SkinAppearance(package: valid, scheme: .light)
                    let image = appearance.image(
                        assetID: "image", scale: 1, targetSize: NSSize(width: 32, height: 32))
                    check(
                        image?.size.width == 32, "image at dimension/pixel limit remains renderable"
                    )
                } else {
                    do {
                        _ = try SkinPackageValidator.validate(directoryURL: dir)
                        fatalError("oversized image accepted")
                    } catch SkinPackageValidationError.invalidAsset(let path) {
                        check(path == "image.png", "oversized image rejected at resource boundary")
                    }
                }
            }
        }
    }

    private static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let components = color.usingColorSpace(.deviceRGB)!
            func channel(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(components.redComponent)
                + 0.7152 * channel(components.greenComponent)
                + 0.0722 * channel(components.blueComponent)
        }
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func writePackage(_ package: SkinPackage, to root: URL) throws {
        try SkinPackageCodec.canonicalData(for: package.manifest)
            .write(to: root.appendingPathComponent("manifest.json"))
        try SkinPackageCodec.canonicalData(for: package.theme)
            .write(to: root.appendingPathComponent("theme.json"))
        try SkinPackageCodec.canonicalData(for: package.components)
            .write(to: root.appendingPathComponent("components.json"))
    }
}
