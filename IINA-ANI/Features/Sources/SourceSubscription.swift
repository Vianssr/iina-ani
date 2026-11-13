import Foundation
import SourceRuntime

/// Supplies desktop registry state to the shared search-only CSS1 converter.
extension SourceSubscriptionConverter {
    static func convert(data: Data, registry: SourceRegistry) throws -> SourceSubscriptionPlan {
        var baselines: [String: SourceRuntime.NativeSearchSource] = [:]
        var installed: [String: SourceRuntime.NativeSearchSource] = [:]
        var names: [String: String] = [:]
        for id in managedSourceIDs.union(registry.snapshot.configurations.keys) {
            if let source = registry.builtinSearch(for: id) {
                baselines[id] = SourceRuntime.NativeSearchSource(hosts: source.hosts,
                    search: source.search, resultURLTemplate: source.resultURLTemplate)
            }
            if let source = registry.subscriptionSearch(for: id) {
                installed[id] = SourceRuntime.NativeSearchSource(hosts: source.hosts,
                    search: source.search, resultURLTemplate: source.resultURLTemplate)
            }
            names[id] = registry.descriptor(for: id)?.name ?? id
        }
        return try SourceRuntime.SourceSubscriptionConverter.convert(data: data,
            baselines: baselines, installed: installed, names: names)
    }
}
