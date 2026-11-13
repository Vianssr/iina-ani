import Foundation
import SourceCore

/// Probes changed rules without allowing one unavailable site to reject unrelated updates.
/// The caller owns preview generations, installed state and atomic persistence.
public enum SourceSubscriptionVerifier {
    public static func verifyChangedSearches(
        _ plan: SourceSubscriptionPlan,
        baselines: [String: NativeSearchSource],
        installed: [String: NativeSearchSource],
        item: @escaping @Sendable (_ sourceID: String, _ raw: String) -> SourceItemRef?,
        fetch: SourceHTTPTransport.Fetch? = nil
    ) async throws -> SourceSubscriptionPlan {
        var overrides = plan.overrides
        var rejected: Set<String> = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var probes: [(String, NativeSearchSource)] = []
        for id in plan.overrides.keys.sorted() {
            try Task.checkCancellation()
            guard let data = overrides[id] else { continue }
            let source = try JSONDecoder().decode(NativeSearchSource.self, from: data)
            let previous = installed[id] ?? baselines[id]
            if let previous, try encoder.encode(previous) == encoder.encode(source) { continue }
            probes.append((id, source))
        }
        try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            func submit(_ probe: (String, NativeSearchSource)) {
                group.addTask {
                    let (id, source) = probe
                    do {
                        let page = try await SourceSearchExecutor.search(
                            query: "海贼王", page: 1, spec: source.search, allowedHosts: Set(source.hosts),
                            resultURLTemplate: source.resultURLTemplate, fetch: fetch, item: { raw in
                                guard let reference = item(id, raw), reference.sourceID == id else { return nil }
                                return reference
                            })
                        return (id, !page.results.isEmpty)
                    } catch {
                        try Task.checkCancellation()
                        return (id, false)
                    }
                }
            }
            while next < min(4, probes.count) { submit(probes[next]); next += 1 }
            while let (id, accepted) = try await group.next() {
                if !accepted { overrides.removeValue(forKey: id); rejected.insert(id) }
                if next < probes.count { submit(probes[next]); next += 1 }
            }
        }
        let entries = plan.entries.map { entry in
            guard let id = entry.sourceID, rejected.contains(id) else { return entry }
            return SourceSubscriptionEntry(sourceID: id, name: entry.name, status: String(localized: "驗證未通過，已保留"),
                detail: String(localized: "新的搜尋規則未取得可辨識作品（網路／驗證頁／無結果）；本次不覆寫舊規則。未判定站點永久失效。"))
        }
        return SourceSubscriptionPlan(fingerprint: plan.fingerprint, checkedAt: plan.checkedAt,
                                      overrides: overrides, entries: entries, configurations: plan.configurations)
    }
}
