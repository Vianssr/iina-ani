import Foundation

public struct WorkspaceComponentDescriptor: Sendable, Equatable {
    public let id: WorkspaceComponentID
    public let contractVersion: Int
    public let defaultSize: WorkspaceSize
    public let minimumSize: WorkspaceSize
    public let allowedContainers: Set<WorkspaceContainerKind>
    public let allowsMultipleInstances: Bool
    let dependencies: Set<WorkspaceCapability>
    public let parameterKeys: Set<String>
    public let styleSlots: Set<String>
    public let settingsSchema: [String: String]
    init(
        id: WorkspaceComponentID, contractVersion: Int = 1, defaultSize: WorkspaceSize, minimumSize: WorkspaceSize,
        allowedContainers: Set<WorkspaceContainerKind> = Set(WorkspaceContainerKind.allCases),
        allowsMultipleInstances: Bool = true, dependencies: Set<WorkspaceCapability> = [],
        parameterKeys: Set<String> = [], styleSlots: Set<String> = [], settingsSchema: [String: String] = [:]
    ) {
        self.id = id
        self.contractVersion = contractVersion
        self.defaultSize = defaultSize
        self.minimumSize = minimumSize
        self.allowedContainers = allowedContainers
        self.allowsMultipleInstances = allowsMultipleInstances
        self.dependencies = dependencies
        self.parameterKeys = parameterKeys
        self.styleSlots = styleSlots
        self.settingsSchema = settingsSchema
    }
}
public enum WorkspaceContainerKind: String, Codable, CaseIterable, Hashable, Sendable {
    case page, grid, horizontalStack, verticalStack, split, group, tabs
}
public protocol WorkspaceComponentRegistry: Sendable {
    func descriptor(for id: WorkspaceComponentID) -> WorkspaceComponentDescriptor?
    var descriptors: [WorkspaceComponentDescriptor] { get }
}
public struct WorkspaceRegistry: WorkspaceComponentRegistry, Sendable {
    private let byID: [WorkspaceComponentID: WorkspaceComponentDescriptor]
    public var descriptors: [WorkspaceComponentDescriptor] { byID.values.sorted { $0.id.rawValue < $1.id.rawValue } }
    public init(_ descriptors: [WorkspaceComponentDescriptor]) {
        self.byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public func descriptor(for id: WorkspaceComponentID) -> WorkspaceComponentDescriptor? { byID[id] }
    public static let builtins = WorkspaceRegistry([
        WorkspaceComponentDescriptor(
            id: "detail.media", defaultSize: .init(width: 760, height: 680),
            minimumSize: .init(width: 560, height: 420), dependencies: [.metadata, .playback],
            styleSlots: ["panel", "header", "list", "row", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "settings.preferences", defaultSize: .init(width: 800, height: 680),
            minimumSize: .init(width: 600, height: 420),
            styleSlots: ["panel", "header", "list", "search", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "torrent.import", defaultSize: .init(width: 760, height: 640),
            minimumSize: .init(width: 560, height: 420), dependencies: [.taskManagement],
            styleSlots: ["panel", "header", "list", "row", "progress", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.schedule", defaultSize: .init(width: 760, height: 280),
            minimumSize: .init(width: 480, height: 180), dependencies: [.schedule],
            styleSlots: ["panel", "header", "row", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.followed", defaultSize: .init(width: 760, height: 360),
            minimumSize: .init(width: 480, height: 240),
            styleSlots: ["panel", "header", "row", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.bilibiliRecommendations", defaultSize: .init(width: 760, height: 360),
            minimumSize: .init(width: 480, height: 240),
            styleSlots: ["panel", "header", "row", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.youtube", defaultSize: .init(width: 760, height: 640),
            minimumSize: .init(width: 480, height: 320),
            styleSlots: ["panel", "header", "row", "search", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.updates", defaultSize: .init(width: 760, height: 240),
            minimumSize: .init(width: 480, height: 180), dependencies: [.favoriteUpdates],
            styleSlots: ["panel", "header", "row", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.recommendations", defaultSize: .init(width: 760, height: 210),
            minimumSize: .init(width: 480, height: 180), dependencies: [.recommendations],
            styleSlots: ["panel", "header", "row", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "playback.continue", defaultSize: .init(width: 760, height: 164),
            minimumSize: .init(width: 480, height: 72), dependencies: [.playback],
            styleSlots: ["panel", "header", "row", "progress", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "discovery.feed", defaultSize: .init(width: 760, height: 640),
            minimumSize: .init(width: 480, height: 240), dependencies: [.recommendations],
            styleSlots: ["panel", "header", "row", "primaryAction", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "search.results", defaultSize: .init(width: 760, height: 640),
            minimumSize: .init(width: 480, height: 320), dependencies: [.search],
            styleSlots: ["panel", "header", "result", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "downloads.tasks", defaultSize: .init(width: 760, height: 640),
            minimumSize: .init(width: 480, height: 320), dependencies: [.taskManagement],
            styleSlots: ["panel", "header", "task", "emptyState"]),
        WorkspaceComponentDescriptor(
            id: "favorites.works", defaultSize: .init(width: 420, height: 480),
            minimumSize: .init(width: 280, height: 200), dependencies: [.favorites],
            styleSlots: ["panel", "header", "workRow", "emptyState"],
            settingsSchema: ["sort": "manual|title|createdNewest"]),
        WorkspaceComponentDescriptor(
            id: "favorites.links", defaultSize: .init(width: 420, height: 480),
            minimumSize: .init(width: 280, height: 200), dependencies: [.favorites],
            styleSlots: ["panel", "header", "linkRow", "emptyState"],
            settingsSchema: ["sort": "manual|title|createdNewest"]),
    ])
}
