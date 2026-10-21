import Foundation

struct DownloadRequestContext: Sendable {
    var headers: [String: String] = [:]
    var cookies: [HTTPCookie] = []
    var credentialHosts: Set<String> = []
    /// nil permits anonymous HTTPS CDN requests; credentials remain host scoped.
    var allowedHosts: Set<String>?
    var allowLoopbackHTTP = false
}

struct DownloadResource: Sendable {
    enum Format: String, Sendable { case direct, hls }
    let url: URL
    let format: Format
    var context = DownloadRequestContext()
    var fileExtension = "mp4"
}

struct DownloadByteRange: Sendable, Equatable {
    let offset: Int64
    let length: Int64
}

struct DownloadTransferResult: Sendable {
    let file: URL
    let responseURL: URL
}

struct DownloadTransferProgress: Sendable {
    var bytes: Int64
    var totalBytes: Int64?
    var completedSegments: Int? = nil
    var totalSegments: Int? = nil
    var restartReason: String? = nil
}

typealias DownloadProgressHandler = @Sendable (DownloadTransferProgress) -> Void

enum DownloadFailure: String, Error, Codable, Sendable, LocalizedError {
    case unsupportedSource, invalidSelection, unsupportedMedia, liveHLS, protectedMedia
    case authorization, mediaUnavailable, network, directoryNotWritable, diskFull
    case mediaToolMissing, finalization, persistence, invalidOperation, missingFile
    case resourceChanged, invalidResponse, torrentMetadataUnavailable, torrentNoPeers, torrentDataMissing, torrentResumeCorrupt, torrentStorageTimeout

    var errorDescription: String? {
        switch self {
        case .unsupportedSource: return String(localized: "此來源沒有下載能力；請改用播放。")
        case .invalidSelection: return String(localized: "請選定原始集數、線路及品質；下載不會自動換選擇。")
        case .unsupportedMedia: return String(localized: "此媒體格式不支援下載；支援普通直連、非 DRM HLS 點播及已選定的 Torrent 檔案。")
        case .liveHLS: return String(localized: "播放清單不是已結束的 HLS 點播；不支援直播錄製。")
        case .protectedMedia: return String(localized: "不支援 DRM 或此 HLS 加密方式。")
        case .authorization: return String(localized: "媒體授權失效；請停止任務並重新登入後恢復。")
        case .mediaUnavailable: return String(localized: "媒體已失效或無法取得；可恢復以重新解析原始選擇。")
        case .network: return String(localized: "網路傳輸中斷；檢查連線後恢復任務。")
        case .directoryNotWritable: return String(localized: "下載目錄不可寫；檢查權限或取消後在新目錄建立任務。")
        case .diskFull: return String(localized: "磁碟空間不足；釋放空間後恢復任務。")
        case .mediaToolMissing: return String(localized: "HLS 封裝需要 FFmpeg；請安裝 FFmpeg 後恢復任務。")
        case .finalization: return String(localized: "媒體封裝失敗；未宣告完成，請檢查媒體或 FFmpeg。")
        case .persistence: return String(localized: "下載任務無法保存；請檢查 Application Support 的空間及權限。")
        case .invalidOperation: return String(localized: "目前狀態不允許此操作。")
        case .missingFile: return String(localized: "完成檔不存在；記錄保留，可刪除記錄。")
        case .resourceChanged: return String(localized: "資源身份改變；必須重新下載，不能拼接舊資料。")
        case .invalidResponse: return String(localized: "媒體伺服器回應不完整或不符合下載協議。")
        case .torrentMetadataUnavailable: return String(localized: "Torrent metadata 未能在等待期限內取得。")
        case .torrentNoPeers: return String(localized: "沒有可用的 Torrent peer；檢查網路後恢復任務。")
        case .torrentDataMissing: return String(localized: "已選 Torrent 檔案資料缺失或不完整；恢復任務以重新校驗。")
        case .torrentResumeCorrupt: return String(localized: "Torrent 恢復資料損壞；資料重新校驗後才可繼續。")
        case .torrentStorageTimeout: return String(localized: "Torrent 檔案寫入或保存逾時；請檢查磁碟後恢復任務。")
        }
    }

    static func classify(_ error: any Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure { return failure }
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) ||
            e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return .diskFull }
        if e.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code) ||
            e.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EROFS), Int(EPERM)].contains(e.code) { return .directoryNotWritable }
        return .network
    }
}

enum DownloadState: String, Codable, Sendable {
    case queued, resolving, downloading, finalizing, completed, paused, failed, canceled

    var displayTitle: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .resolving: return String(localized: "Resolving")
        case .downloading: return String(localized: "Downloading")
        case .finalizing: return String(localized: "Finalizing")
        case .completed: return String(localized: "Completed")
        case .paused: return String(localized: "Paused")
        case .failed: return String(localized: "Failed")
        case .canceled: return String(localized: "Canceled")
        }
    }
}

enum DownloadOperation: String, Sendable {
    case pause, resume, cancel, deleteRecord, deleteFile, openFile
}

struct DownloadRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let selection: PlayableSelection
    let workID: UUID?
    let title: String
    let episodeTitle: String?
    let outputDirectory: URL
    let temporaryDirectory: URL
    var outputDirectoryBookmark: Data?
    let concurrencyLimit: Int
    let createdAt: Date
    var updatedAt: Date
    var state: DownloadState = .queued
    var bytes: Int64 = 0
    var totalBytes: Int64?
    var completedSegments: Int?
    var totalSegments: Int?
    var bytesPerSecond: Double = 0
    var remainingSeconds: Double?
    var restartReason: String?
    var needsRecovery = false
    var failure: DownloadFailure?
    var completedFile: URL?
    var torrentUploadBytesPerSecond: UInt32?
    var torrentUploadPolicyAcknowledged: Bool? = nil
    var torrentStorageDirectory: URL?
    var coverURL: String? = nil
    var bangumiID: Int? = nil
    var episodeKey: String? = nil
    /// One safe child component under the security-scoped root. Legacy tasks stay at the root.
    var outputSubdirectory: String? = nil
    var fractionCompleted: Double? {
        if state == .completed { return 1 }
        if let totalBytes, totalBytes > 0 { return min(1, Double(bytes) / Double(totalBytes)) }
        if let totalSegments, totalSegments > 0, let completedSegments {
            return min(1, Double(completedSegments) / Double(totalSegments))
        }
        return nil
    }
    var allowedOperations: Set<DownloadOperation> {
        switch state {
        case .queued, .resolving, .downloading: return [.pause, .cancel]
        case .paused, .failed: return [.resume, .cancel, .deleteRecord]
        case .finalizing: return []
        case .completed: return completedFile == nil ? [.deleteRecord] : [.deleteRecord, .deleteFile, .openFile]
        case .canceled: return [.deleteRecord]
        }
    }
}

struct TorrentUploadPolicy: Codable, Hashable, Sendable {
    static let maximumBytesPerSecond: UInt32 = 10 * 1024 * 1024
    let bytesPerSecond: UInt32
    let acknowledged: Bool
    var acknowledgementText: String { "P2P 下載期間可能向其他 peer 上傳已收到的資料。上傳遵守確認的每秒位元組上限；最後一個使用者停止後，傳輸也會停止。" }

    init(bytesPerSecond: UInt32, acknowledged: Bool) throws {
        guard acknowledged, (1...Self.maximumBytesPerSecond).contains(bytesPerSecond) else {
            throw DownloadFailure.invalidSelection
        }
        self.bytesPerSecond = bytesPerSecond
        self.acknowledged = acknowledged
    }
}

struct TorrentFileCandidate: Codable, Hashable, Sendable, Identifiable {
    let index: Int
    let path: String
    let size: UInt64
    var id: Int { index }
    var isPlayableMedia: Bool { TorrentSelection.isPlayablePath(path) }
}

struct TorrentImport: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let infoHashes: Set<String>
    let isPrivate: Bool
    let files: [TorrentFileCandidate]
    let totalBytes: UInt64
}
struct TorrentSelectedFile: Sendable {
    let selection: TorrentSelection
    let storageRoot: URL
}
