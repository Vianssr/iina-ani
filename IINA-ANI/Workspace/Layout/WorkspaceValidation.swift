import Foundation

public enum WorkspaceValidationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedSchema(Int)
    case tooManyPages, tooManyNodes, excessiveDepth
    case duplicateIdentity(UUID)
    case duplicatePage(UUID)
    case duplicateComponent(WorkspaceComponentID)
    case unknownComponent(WorkspaceComponentID)
    case unsupportedComponentVersion(WorkspaceComponentID, Int)
    case invalidSize(WorkspaceComponentID)
    case invalidRatio, invalidBreakpoint
    case invalidContainers(WorkspaceComponentID)
    case invalidParameters(WorkspaceComponentID)
    case invalidTabsSelection(UUID)
    case invalidContainer(WorkspaceContainerKind)
    case inconsistentInstance(UUID)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): String(localized: "Unsupported workspace schema version \(v)")
        case .tooManyPages: String(localized: "Workspace page limit exceeded")
        case .tooManyNodes: String(localized: "Workspace node limit exceeded")
        case .excessiveDepth: String(localized: "Workspace nesting limit exceeded")
        case .duplicateIdentity(let id): String(localized: "Duplicate workspace identity \(id.uuidString)")
        case .duplicatePage(let id): String(localized: "Duplicate page identity \(id.uuidString)")
        case .duplicateComponent(let id): String(localized: "Component \(id.rawValue) cannot be repeated")
        case .unknownComponent(let id): String(localized: "Unknown component \(id.rawValue)")
        case .unsupportedComponentVersion(let id, let v): String(localized: "Unsupported \(id.rawValue) contract version \(v)")
        case .invalidSize(let id): String(localized: "Invalid size for \(id.rawValue)")
        case .invalidRatio: String(localized: "Invalid split ratio")
        case .invalidBreakpoint: String(localized: "Invalid or duplicate breakpoint")
        case .invalidContainers(let id): String(localized: "Component \(id.rawValue) is not allowed in this container")
        case .invalidParameters(let id): String(localized: "Invalid parameters for \(id.rawValue)")
        case .invalidTabsSelection(let id): String(localized: "Tabs selection \(id.uuidString) is not present")
        case .invalidContainer(let kind): String(localized: "Container \(kind.rawValue) is empty")
        case .inconsistentInstance(let id): String(localized: "Instance \(id.uuidString) differs between layout variants")
        }
    }
    public var description: String {
        switch self {
        case .unsupportedSchema(let v): "Unsupported workspace schema version \(v)"
        case .tooManyPages: "Workspace page limit exceeded"
        case .tooManyNodes: "Workspace node limit exceeded"
        case .excessiveDepth: "Workspace nesting limit exceeded"
        case .duplicateIdentity(let id): "Duplicate workspace identity \(id)"
        case .duplicatePage(let id): "Duplicate page identity \(id)"
        case .duplicateComponent(let id): "Component \(id.rawValue) cannot be repeated"
        case .unknownComponent(let id): "Unknown component \(id.rawValue)"
        case .unsupportedComponentVersion(let id, let v): "Unsupported \(id.rawValue) contract version \(v)"
        case .invalidSize(let id): "Invalid size for \(id.rawValue)"
        case .invalidRatio: "Invalid split ratio"
        case .invalidBreakpoint: "Invalid or duplicate breakpoint"
        case .invalidContainers(let id): "Component \(id.rawValue) is not allowed in this container"
        case .invalidParameters(let id): "Invalid parameters for \(id.rawValue)"
        case .invalidTabsSelection(let id): "Tabs selection \(id) is not present"
        case .invalidContainer(let kind): "Container \(kind.rawValue) is empty"
        case .inconsistentInstance(let id): "Instance \(id) differs between layout variants"
        }
    }
}
public struct WorkspaceValidator: Sendable {
    public let registry: any WorkspaceComponentRegistry
    public var maximumPages = 32, maximumNodes = 512, maximumDepth = 32
    public var maximumDimension = 8192.0, maximumParameterBytes = 16_384, maximumDocumentBytes = 1_048_576
    public init(registry: any WorkspaceComponentRegistry) { self.registry = registry }
    public func validate(_ layout: WorkspaceLayout) throws {
        guard layout.schemaVersion == WorkspaceLayout.currentSchemaVersion else {
            throw WorkspaceValidationError.unsupportedSchema(layout.schemaVersion)
        }
        guard !layout.pages.isEmpty, layout.pages.count <= maximumPages else {
            throw WorkspaceValidationError.tooManyPages
        }
        let widths = layout.breakpointLayouts.keys.map(\.minimumWidth)
        guard widths.allSatisfy({ $0.isFinite && $0 >= 320 && $0 <= 10_000 }), Set(widths).count == widths.count else {
            throw WorkspaceValidationError.invalidBreakpoint
        }
        let pageIDs = Set(([layout.pages] + Array(layout.breakpointLayouts.values)).flatMap { $0.map(\.id) })
        if let home = layout.homePageID, !pageIDs.contains(home) {
            throw WorkspaceValidationError.invalidTabsSelection(home)
        }
        if let missing = layout.hiddenPageIDs.subtracting(pageIDs).first {
            throw WorkspaceValidationError.invalidTabsSelection(missing)
        }
        let instancesInLayout = Set(WorkspaceLayoutTraversal.componentInstanceIDs(in: layout))
        if let missing = layout.collapsedInstanceIDs.subtracting(instancesInLayout).first {
            throw WorkspaceValidationError.inconsistentInstance(missing)
        }
        var count = 0
        var instances: [UUID: Fingerprint] = [:]
        for pages in [layout.pages] + Array(layout.breakpointLayouts.values) {
            guard pages.count <= maximumPages else { throw WorkspaceValidationError.tooManyPages }
            let current = try validateVariant(pages, nodeCount: &count)
            for (id, fingerprint) in current {
                if let old = instances[id], old != fingerprint {
                    throw WorkspaceValidationError.inconsistentInstance(id)
                }
                instances[id] = fingerprint
            }
        }
    }
    private struct Fingerprint: Equatable {
        let type: WorkspaceComponentID
        let version: Int
        let parameters: [String: WorkspaceJSONValue]
    }
    private func validateVariant(_ pages: [WorkspacePage], nodeCount: inout Int) throws -> [UUID: Fingerprint] {
        var pageIDs = Set<UUID>()
        var identities = Set<UUID>()
        var types: [WorkspaceComponentID: Int] = [:]
        var components: [UUID: Fingerprint] = [:]
        for page in pages {
            try page.motion.validate()
            guard pageIDs.insert(page.id).inserted else { throw WorkspaceValidationError.duplicatePage(page.id) }
            guard identities.insert(page.id).inserted else { throw WorkspaceValidationError.duplicateIdentity(page.id) }
            try walk(
                page.root, depth: 1, parent: .page, ids: &identities, types: &types, components: &components,
                nodeCount: &nodeCount)
        }
        return components
    }
    private func walk(
        _ node: WorkspaceNode, depth: Int, parent: WorkspaceContainerKind, ids: inout Set<UUID>,
        types: inout [WorkspaceComponentID: Int], components: inout [UUID: Fingerprint], nodeCount: inout Int
    ) throws {
        guard depth <= maximumDepth else { throw WorkspaceValidationError.excessiveDepth }
        nodeCount += 1
        guard nodeCount <= maximumNodes else { throw WorkspaceValidationError.tooManyNodes }
        guard ids.insert(node.id).inserted else { throw WorkspaceValidationError.duplicateIdentity(node.id) }
        switch node {
        case .empty: break
        case .component(let instance, let type, let version, let params, let size):
            guard let d = registry.descriptor(for: type) else { throw WorkspaceValidationError.unknownComponent(type) }
            guard version == d.contractVersion else {
                throw WorkspaceValidationError.unsupportedComponentVersion(type, version)
            }
            guard d.allowedContainers.contains(parent) else { throw WorkspaceValidationError.invalidContainers(type) }
            guard size.width.isFinite, size.height.isFinite, size.width >= d.minimumSize.width,
                size.height >= d.minimumSize.height, size.width <= maximumDimension, size.height <= maximumDimension
            else { throw WorkspaceValidationError.invalidSize(type) }
            guard Set(params.keys).isSubset(of: d.parameterKeys), let data = try? JSONEncoder().encode(params),
                data.count <= maximumParameterBytes
            else { throw WorkspaceValidationError.invalidParameters(type) }
            types[type, default: 0] += 1
            if !d.allowsMultipleInstances && types[type, default: 0] > 1 {
                throw WorkspaceValidationError.duplicateComponent(type)
            }
            components[instance] = Fingerprint(type: type, version: version, parameters: params)
        case .split(_, let a, let b, let ratio):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw WorkspaceValidationError.invalidRatio }
            try walk(
                a, depth: depth + 1, parent: .split, ids: &ids, types: &types, components: &components,
                nodeCount: &nodeCount)
            try walk(
                b, depth: depth + 1, parent: .split, ids: &ids, types: &types, components: &components,
                nodeCount: &nodeCount)
        case .grid(_, let xs): try walkChildren(xs, .grid, depth, &ids, &types, &components, &nodeCount)
        case .horizontalStack(_, let xs):
            try walkChildren(xs, .horizontalStack, depth, &ids, &types, &components, &nodeCount)
        case .verticalStack(_, let xs):
            try walkChildren(xs, .verticalStack, depth, &ids, &types, &components, &nodeCount)
        case .group(_, let xs): try walkChildren(xs, .group, depth, &ids, &types, &components, &nodeCount)
        case .tabs(_, let selected, let pages):
            guard !pages.isEmpty, pages.contains(where: { $0.id == selected }) else {
                throw WorkspaceValidationError.invalidTabsSelection(selected)
            }
            for page in pages {
                try page.motion.validate()
                guard ids.insert(page.id).inserted else { throw WorkspaceValidationError.duplicatePage(page.id) }
                try walk(
                    page.root, depth: depth + 1, parent: .tabs, ids: &ids, types: &types, components: &components,
                    nodeCount: &nodeCount)
            }
        }
    }
    private func walkChildren(
        _ xs: [WorkspaceNode], _ kind: WorkspaceContainerKind, _ depth: Int, _ ids: inout Set<UUID>,
        _ types: inout [WorkspaceComponentID: Int], _ components: inout [UUID: Fingerprint], _ count: inout Int
    ) throws {
        guard !xs.isEmpty else { throw WorkspaceValidationError.invalidContainer(kind) }
        for x in xs {
            try walk(
                x, depth: depth + 1, parent: kind, ids: &ids, types: &types, components: &components, nodeCount: &count)
        }
    }
}
public enum WorkspaceLayoutCodec {
    public static func decode(_ data: Data, validator: WorkspaceValidator) throws -> WorkspaceLayout {
        guard data.count <= validator.maximumDocumentBytes else { throw WorkspaceDocumentError.tooLarge }
        try checkDepth(data, limit: validator.maximumDepth * 2 + 8)
        let value = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        try validator.validate(value)
        return value
    }
    public static func encode(_ value: WorkspaceLayout, validator: WorkspaceValidator) throws -> Data {
        try validator.validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= validator.maximumDocumentBytes else { throw WorkspaceDocumentError.tooLarge }
        return data
    }
    /// Shares presentation structure only; component input/session data is never exported.
    public static func sanitizedForSharing(_ layout: WorkspaceLayout) throws -> WorkspaceLayout {
        let data = try JSONEncoder().encode(layout)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkspaceDocumentError.invalidJSON
        }
        func clean(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["kind"] as? String == "component" { object["parameters"] = [String: Any]() }
                for key in Array(object.keys) { object[key] = clean(object[key]!) }
                return object
            }
            if let array = value as? [Any] { return array.map(clean) }
            return value
        }
        root = clean(root) as! [String: Any]
        let sanitized = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try decode(sanitized, validator: WorkspaceValidator(registry: WorkspaceRegistry.builtins))
    }
    private static func checkDepth(_ data: Data, limit: Int) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
                continue
            }
            if byte == 34 {
                inString = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                if depth > limit { throw WorkspaceValidationError.excessiveDepth }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                if depth < 0 { throw WorkspaceDocumentError.invalidJSON }
            }
        }
        guard depth == 0 && !inString else { throw WorkspaceDocumentError.invalidJSON }
    }
}
enum WorkspaceDocumentError: Error, LocalizedError {
    case tooLarge, invalidJSON
    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "The workspace document exceeds the size limit.")
        case .invalidJSON: String(localized: "The workspace document is not valid JSON.")
        }
    }
}
