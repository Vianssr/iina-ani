import Foundation
import CoreFoundation
import Observation
#if os(iOS)
import SwiftUI
import UIKit
#endif

// The desktop DanmakuEvent is an untimed WebKit/WebSocket transport. This VOD
// projection preserves its text payload and the existing Bilibili / CDF modes,
// adding the media timestamp that local XML and JSON files already provide.
enum MobileDanmakuMode: Int, Sendable {
    case scrolling = 1, bottom = 4, top = 5

    init?(sourceValue: Int) {
        switch sourceValue {
        case 1...3: self = .scrolling
        case 4: self = .bottom
        case 5: self = .top
        default: return nil // Advanced / scripted comments are not executed.
        }
    }

    var duration: Double { self == .scrolling ? 8 : 4 }
    var laneCount: Int { self == .scrolling ? 6 : 2 }
}

struct MobileDanmakuEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
    let mode: MobileDanmakuMode
    let color: UInt32
}

enum MobileDanmakuError: Error {
    case tooLarge, invalidFormat, forbiddenDeclaration, tooManyComments, noComments
}

enum MobileDanmakuParser {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumComments = 50_000

    static func parse(data: Data) throws -> [MobileDanmakuEntry] {
        guard data.count <= maximumBytes else { throw MobileDanmakuError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw MobileDanmakuError.invalidFormat }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let entries: [MobileDanmakuEntry]
        if trimmed.hasPrefix("<") {
            // Check before XMLParser: with external resolution disabled, some
            // Foundation versions do not report every declaration to delegates.
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
                throw MobileDanmakuError.forbiddenDeclaration
            }
            let delegate = BilibiliXMLDelegate()
            let parser = XMLParser(data: Data(trimmed.utf8))
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { throw delegate.failure ?? MobileDanmakuError.invalidFormat }
            entries = delegate.entries
        } else {
            entries = try parseJSON(data)
        }
        guard !entries.isEmpty else { throw MobileDanmakuError.noComments }
        return entries.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    /// Automatic attachments additionally require the provider's XML identity,
    /// including for empty comment pools. Local imports retain their old contract.
    static func parseBilibili(data: Data, expectedCID: Int64) throws -> [MobileDanmakuEntry] {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw MobileAutomaticDanmakuFailure.invalidResponse
        }
        let delegate = BilibiliXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else { throw MobileAutomaticDanmakuFailure.invalidResponse }
        guard delegate.bilibiliRoot, !delegate.invalidIdentity, delegate.chatIDCount == 1,
              Int64(delegate.chatID.trimmingCharacters(in: .whitespacesAndNewlines)) == expectedCID else {
            throw MobileAutomaticDanmakuFailure.identityMismatch
        }
        return delegate.entries.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    // Supports CDF's stime in milliseconds, an explicit time in seconds, and
    // legacy AcFun's {"c":"seconds,color,mode,...", "m":"text"} records.
    private static func parseJSON(_ data: Data) throws -> [MobileDanmakuEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw MobileDanmakuError.invalidFormat }
        let rows: [Any]
        if let array = object as? [Any] { rows = array }
        else if let object = object as? [String: Any], let array = object["comments"] as? [Any] { rows = array }
        else { throw MobileDanmakuError.invalidFormat }
        guard rows.count <= maximumComments else { throw MobileDanmakuError.tooManyComments }
        return rows.enumerated().compactMap { index, item in
            guard let row = item as? [String: Any] else { return nil }
            if let parameters = row["c"] as? String, let text = row["m"] as? String {
                let fields = parameters.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3, let time = Double(fields[0]), let mode = Int(fields[2]) else { return nil }
                return entry(id: index, time: time, text: text, mode: mode, color: UInt32(fields[1]) ?? 0xFFFFFF)
            }
            guard let text = row["text"] as? String else { return nil }
            let time = number(row["time"]) ?? number(row["stime"]).map { $0 / 1_000 }
            guard let time else { return nil }
            let modeValue = number(row["mode"]) ?? 1
            guard modeValue.isFinite, modeValue >= 1, modeValue <= 9, modeValue.rounded() == modeValue else { return nil }
            let rawColor = number(row["color"]) ?? Double(0xFFFFFF)
            let color = rawColor.isFinite && rawColor >= 0 && rawColor <= 0xFFFFFF ? UInt32(rawColor) : 0xFFFFFF
            return entry(id: index, time: time, text: text, mode: Int(modeValue), color: color)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        if let value = value as? String { return Double(value) }
        return nil
    }

    fileprivate static func entry(id: Int, time: Double, text: String, mode: Int, color: UInt32) -> MobileDanmakuEntry? {
        guard time.isFinite, time >= 0, time <= 604_800, text.utf8.count <= 2_048,
              let mode = MobileDanmakuMode(sourceValue: mode) else { return nil }
        let text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return MobileDanmakuEntry(id: id, time: time, text: String(text.prefix(160)), mode: mode, color: min(color, 0xFFFFFF))
    }
}

private final class BilibiliXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [MobileDanmakuEntry] = []
    var failure: MobileDanmakuError?
    private var recordCount = 0
    private var parameters: String?
    private var content = ""
    private var oversized = false
    private var depth = 0
    private var capturingChatID = false
    private(set) var bilibiliRoot = false
    private(set) var chatIDCount = 0
    private(set) var chatID = ""
    private(set) var invalidIdentity = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        if depth == 1 { bilibiliRoot = elementName == "i" }
        if capturingChatID { invalidIdentity = true }
        if elementName == "chatid" {
            chatIDCount += 1
            guard depth == 2 else { invalidIdentity = true; return }
            capturingChatID = true
        }
        guard elementName == "d" else { return }
        recordCount += 1
        guard recordCount <= MobileDanmakuParser.maximumComments else {
            failure = .tooManyComments
            parser.abortParsing()
            return
        }
        parameters = attributeDict["p"]
        content = ""
        oversized = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingChatID {
            if chatID.utf8.count + string.utf8.count <= 64 { chatID += string }
            else { invalidIdentity = true }
        }
        guard parameters != nil, !oversized else { return }
        guard content.utf8.count + string.utf8.count <= 2_048 else { oversized = true; return }
        content += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { depth -= 1 }
        if elementName == "chatid" { capturingChatID = false }
        guard elementName == "d", let parameters else { return }
        defer { self.parameters = nil; content = "" }
        guard !oversized else { return }
        let fields = parameters.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4, let time = Double(fields[0]), let mode = Int(fields[1]),
              let entry = MobileDanmakuParser.entry(id: recordCount, time: time, text: content, mode: mode, color: UInt32(fields[3]) ?? 0xFFFFFF) else { return }
        entries.append(entry)
    }

    private func reject(_ parser: XMLParser) { failure = .forbiddenDeclaration; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }
}

struct MobileDanmakuAppearance: Codable, Equatable {
    var fontName = ""
    var fontSize = 24.0
    var speed = 1.0
    var opacity = 1.0
    var useSourceColors = true

    var normalized: Self {
        var value = self
        value.fontSize = fontSize.isFinite ? min(48, max(12, fontSize)) : 24
        value.speed = speed.isFinite ? min(2, max(0.5, speed)) : 1
        value.opacity = opacity.isFinite ? min(1, max(0.1, opacity)) : 1
        return value
    }

    #if os(iOS)
    var font: Font {
        fontName.isEmpty ? .system(size: fontSize, weight: .semibold) : .custom(fontName, fixedSize: fontSize)
    }

    var lineHeight: CGFloat {
        let font = UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
        return max(font.lineHeight, fontSize * 1.4)
    }
    #endif
}

struct MobileScheduledDanmaku: Equatable {
    let entry: MobileDanmakuEntry
    let lane: Int
}

@MainActor @Observable
final class MobileDanmakuStore {
    var enabled = true { didSet { defaults.set(enabled, forKey: "mobile.danmaku.enabled") } }
    private var storedAppearance = MobileDanmakuAppearance()
    var appearance: MobileDanmakuAppearance {
        get { storedAppearance }
        set {
            let value = newValue.normalized
            let speedChanged = storedAppearance.speed != value.speed
            storedAppearance = value
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: "mobile.danmaku.appearance")
            }
            if speedChanged { rebuildTimeline() }
        }
    }
    var automaticEnabled = true {
        didSet {
            defaults.set(automaticEnabled, forKey: "mobile.danmaku.automatic")
            refreshAutomatic()
        }
    }
    private(set) var automaticStatus: MobileAutomaticDanmakuStatus = .idle
    @ObservationIgnored private let automaticLoader: @Sendable (MobileDanmakuTarget) async throws -> [MobileDanmakuEntry]
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRevision = 0
    @ObservationIgnored private var automaticTarget: MobileDanmakuTarget?
    @ObservationIgnored private var automaticAuthority: (@MainActor () throws -> Void)?
    private var hasManualAttachment = false
    var blockedWords = "" {
        didSet { defaults.set(blockedWords, forKey: "mobile.danmaku.blockedWords"); rebuildTimeline() }
    }
    var hideScrolling = false {
        didSet { defaults.set(hideScrolling, forKey: "mobile.danmaku.hideScrolling"); rebuildTimeline() }
    }
    var hideTop = false {
        didSet { defaults.set(hideTop, forKey: "mobile.danmaku.hideTop"); rebuildTimeline() }
    }
    var hideBottom = false {
        didSet { defaults.set(hideBottom, forKey: "mobile.danmaku.hideBottom"); rebuildTimeline() }
    }
    private(set) var entries: [MobileDanmakuEntry] = []
    private var timeline: [MobileScheduledDanmaku] = []
    private var matchingCount = 0
    var filteredCount: Int { enabled ? matchingCount : 0 }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         automaticLoader: @escaping @Sendable (MobileDanmakuTarget) async throws -> [MobileDanmakuEntry] = {
             try await MobileBilibiliDanmakuProvider().comments(for: $0)
         }) {
        self.defaults = defaults
        self.automaticLoader = automaticLoader
        automaticEnabled = defaults.object(forKey: "mobile.danmaku.automatic") as? Bool ?? true
        enabled = defaults.object(forKey: "mobile.danmaku.enabled") as? Bool ?? true
        blockedWords = defaults.string(forKey: "mobile.danmaku.blockedWords") ?? ""
        hideScrolling = defaults.bool(forKey: "mobile.danmaku.hideScrolling")
        hideTop = defaults.bool(forKey: "mobile.danmaku.hideTop")
        hideBottom = defaults.bool(forKey: "mobile.danmaku.hideBottom")
        if let data = defaults.data(forKey: "mobile.danmaku.appearance"),
           let saved = try? JSONDecoder().decode(MobileDanmakuAppearance.self, from: data) {
            storedAppearance = saved.normalized
        }
    }

    // The file importer's caller owns security-scoped access for this read.
    func load(url: URL) throws {
        guard url.isFileURL else { throw MobileDanmakuError.invalidFormat }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: MobileDanmakuParser.maximumBytes + 1) ?? Data()
        try parse(data: data)
    }

    func parse(data: Data) throws {
        let parsed = try MobileDanmakuParser.parse(data: data)
        cancelAutomatic()
        hasManualAttachment = true
        automaticStatus = .manual
        entries = parsed // Commit only after successful import.
        rebuildTimeline()
    }

    func clear() {
        cancelAutomatic()
        automaticTarget = nil
        automaticAuthority = nil
        hasManualAttachment = false
        automaticStatus = .idle
        entries = []
        timeline = []
        matchingCount = 0
    }

    func beginEpisode(target: MobileDanmakuTarget?, authority: @escaping @MainActor () throws -> Void) {
        clear() // Never display or retain the previous episode while a request is pending.
        automaticTarget = target
        automaticAuthority = authority
        refreshAutomatic()
    }

    func cancelAutomatic() {
        automaticRevision += 1
        automaticTask?.cancel()
        automaticTask = nil
        if automaticStatus == .loading { automaticStatus = .cancelled }
    }

    func retryAutomatic() { refreshAutomatic() }

    private func refreshAutomatic() {
        cancelAutomatic()
        guard !hasManualAttachment else { automaticStatus = .manual; return }
        entries = []
        timeline = []
        matchingCount = 0
        guard automaticEnabled else { automaticStatus = .off; return }
        guard let target = automaticTarget, let authority = automaticAuthority else {
            automaticStatus = .unsupported
            return
        }
        let revision = automaticRevision
        automaticStatus = .loading
        let loader = automaticLoader
        automaticTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try authority()
                let comments = try await loader(target)
                try Task.checkCancellation()
                guard let self, automaticRevision == revision, automaticTarget == target,
                      automaticEnabled, !hasManualAttachment else { return }
                try authority() // Re-read current configuration/enablement after the network boundary.
                entries = comments
                rebuildTimeline()
                automaticStatus = comments.isEmpty ? .empty : .loaded
                automaticTask = nil
            } catch {
                guard let self, automaticRevision == revision, automaticTarget == target,
                      automaticEnabled, !hasManualAttachment else { return }
                automaticTask = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    automaticStatus = .cancelled
                } else {
                    automaticStatus = .failed(error as? MobileAutomaticDanmakuFailure ?? .configurationChanged)
                }
            }
        }
    }

    func duration(for mode: MobileDanmakuMode) -> Double {
        mode.duration / appearance.speed
    }

    func activeEntries(at position: Double) -> [MobileScheduledDanmaku] {
        guard enabled, position.isFinite, position >= 0 else { return [] }
        // Binary search avoids scanning an entire episode on each video tick.
        var low = 0
        var high = timeline.count
        while low < high {
            let middle = (low + high) / 2
            if timeline[middle].entry.time < position - duration(for: .scrolling) { low = middle + 1 }
            else { high = middle }
        }
        var visible: [MobileScheduledDanmaku] = []
        for item in timeline[low...] {
            guard item.entry.time <= position else { break }
            if position < item.entry.time + duration(for: item.entry.mode) { visible.append(item) }
        }
        return visible
    }

    private func rebuildTimeline() {
        let words = blockedWords.components(separatedBy: CharacterSet(charactersIn: ",，、\n\r;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var lanes: [MobileDanmakuMode: [Double]] = [:]
        var scheduled: [MobileScheduledDanmaku] = []
        var matches = 0
        for entry in entries {
            if (hideScrolling && entry.mode == .scrolling) || (hideTop && entry.mode == .top) || (hideBottom && entry.mode == .bottom) { continue }
            if words.contains(where: { entry.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) { continue }
            matches += 1
            var available = lanes[entry.mode] ?? Array(repeating: -Double.infinity, count: entry.mode.laneCount)
            // Reserve the whole lifetime of a lane. Dense imports drop overflow
            // visually instead of overlapping text or delaying comments off-time.
            guard let lane = available.firstIndex(where: { $0 <= entry.time }) else { continue }
            scheduled.append(MobileScheduledDanmaku(entry: entry, lane: lane))
            available[lane] = entry.time + duration(for: entry.mode)
            lanes[entry.mode] = available
        }
        timeline = scheduled
        matchingCount = matches
    }
}

#if os(iOS)
struct MobileDanmakuOverlay: View {
    let store: MobileDanmakuStore
    let position: Double

    var body: some View {
        let active = store.activeEntries(at: position)
        Canvas { context, size in
            let appearance = store.appearance
            let lineHeight = appearance.lineHeight
            let font = appearance.font
            let inset = size.height * 0.05
            let rows = max(0, Int((size.height - inset * 2) / lineHeight))
            let fixedRows = min(2, rows / 3)
            let scrollingRows = min(6, rows - fixedRows * 2)
            context.opacity = appearance.opacity
            for item in active {
                let entry = item.entry
                let rgb = appearance.useSourceColors ? entry.color : 0xFFFFFF
                let color = Color(red: Double((rgb >> 16) & 255) / 255,
                                  green: Double((rgb >> 8) & 255) / 255,
                                  blue: Double(rgb & 255) / 255)
                let text = context.resolve(Text(verbatim: entry.text).font(font).foregroundColor(color))
                let extent = text.measure(in: CGSize(width: 10_000, height: lineHeight))
                let progress = (position - entry.time) / store.duration(for: entry.mode)
                let x: CGFloat
                let y: CGFloat
                switch entry.mode {
                case .scrolling:
                    guard item.lane < scrollingRows else { continue }
                    x = size.width - (size.width + extent.width) * progress
                    y = inset + Double(fixedRows + item.lane) * lineHeight
                case .top:
                    guard item.lane < fixedRows else { continue }
                    x = max(4, (size.width - extent.width) / 2)
                    y = inset + Double(item.lane) * lineHeight
                case .bottom:
                    guard item.lane < fixedRows else { continue }
                    x = max(4, (size.width - extent.width) / 2)
                    y = size.height - inset - Double(item.lane + 1) * lineHeight
                }
                var shadow = context
                shadow.addFilter(.shadow(color: .black.opacity(0.95), radius: 2))
                shadow.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // No event accumulator or wall clock: pause, playback speed and both
        // seek directions always follow the actual mpv time-pos value.
    }
}
#endif
