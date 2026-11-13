import Foundation
import SourceRuntime

/// Only sanitized, explicitly previewed configuration reaches the registry. No remote credentials
/// or media URLs are saved. Existing selections and active player/download owners are untouched.
@MainActor
final class SourceSubscriptionService {
    private let registry: SourceRegistry
    private let fetch: @Sendable (URL) async throws -> Data
    private var pending: (plan: SourceSubscriptionPlan, revision: UInt64)?
    private var checkGeneration: UInt64 = 0
    private(set) var lastError: String?
    var lastApplied: SourceSubscriptionPlan? { registry.snapshot.subscription }

    init(registry: SourceRegistry,
         fetchURL: @escaping @Sendable (URL) async throws -> Data = SourceSubscriptionTransport.download(from:)) {
        self.registry = registry
        self.fetch = fetchURL
    }

    convenience init(registry: SourceRegistry, fetch: @escaping @Sendable () async throws -> Data) {
        self.init(registry: registry, fetchURL: { _ in try await fetch() })
    }

    func cancelPendingCheck() {
        checkGeneration &+= 1
        pending = nil
        lastError = nil
    }

    func check(url: URL = SourceSubscriptionTransport.endpoint) async throws -> SourceSubscriptionPlan {
        checkGeneration &+= 1
        let generation = checkGeneration
        let revision = registry.revision
        pending = nil
        lastError = nil
        do {
            guard SourceSubscriptionTransport.allows(url) else { throw SourceSubscriptionFailure.invalidAddress }
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard generation == checkGeneration, revision == registry.revision else {
                throw SourceSubscriptionFailure.stalePreview
            }
            let converted = try SourceSubscriptionConverter.convert(data: data, registry: registry)
            let plan = try await verifyChangedSearches(converted)
            try Task.checkCancellation()
            guard generation == checkGeneration, revision == registry.revision else {
                throw SourceSubscriptionFailure.stalePreview
            }
            pending = (plan, revision)
            return plan
        } catch {
            if generation == checkGeneration { lastError = error is CancellationError ? nil : error.localizedDescription }
            throw error
        }
    }

    func apply(_ plan: SourceSubscriptionPlan) throws {
        guard let pending, pending.plan.fingerprint == plan.fingerprint,
              pending.plan.checkedAt == plan.checkedAt, pending.plan.overrides == plan.overrides,
              pending.plan.configurations == plan.configurations else {
            throw SourceSubscriptionFailure.stalePreview
        }
        do {
            try registry.applySubscription(pending.plan, expectedRevision: pending.revision)
            self.pending = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Shared probes only validate changed search overlays; new static configurations remain
    /// explicit, disabled imports whose playback must be checked after choosing a work/episode.
    private func verifyChangedSearches(_ plan: SourceSubscriptionPlan) async throws -> SourceSubscriptionPlan {
        var baselines: [String: SourceRuntime.NativeSearchSource] = [:]
        var installed: [String: SourceRuntime.NativeSearchSource] = [:]
        for id in plan.overrides.keys {
            if let source = registry.builtinSearch(for: id) {
                baselines[id] = .init(hosts: source.hosts, search: source.search, resultURLTemplate: source.resultURLTemplate)
            }
            if let source = registry.subscriptionSearch(for: id) {
                installed[id] = .init(hosts: source.hosts, search: source.search, resultURLTemplate: source.resultURLTemplate)
            }
        }
        let registry = registry
        return try await SourceSubscriptionVerifier.verifyChangedSearches(plan,
            baselines: baselines, installed: installed, item: { id, raw in
                guard let item = try? registry.item(for: raw, expectedKind: .work), item.sourceID == id else { return nil }
                return item
            })
    }
}
