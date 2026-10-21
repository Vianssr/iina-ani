import Foundation

@main
struct WorkspaceLayoutScriptRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func main() async throws {
        let runner = WorkspaceLayoutScriptRunner(
            helperURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let source = """
            function buildLayout(context) {
                if (Object.keys(context).sort().join(',') !== 'componentContractVersion,components,configuration,schemaVersion')
                    throw new Error('Unexpected context data');
                const ids = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
                const components = context.components.filter(c => c.id.startsWith('favorites.'));
                const panels = [];
                for (let i = 0; i < components.length; i++) {
                    const c = components[i];
                    panels.push({kind:'component', id:ids(i+10), componentID:c.id,
                        contractVersion:c.contractVersion, parameters:{}, size:c.defaultSize});
                }
                const page = {id:ids(1), title:context.configuration.title,
                    root:{kind:'verticalStack', id:ids(2), children:panels}};
                const wide = JSON.parse(JSON.stringify(page));
                if (context.configuration.wide) wide.root.kind = 'horizontalStack';
                return {schemaVersion:context.schemaVersion, pages:[page],
                    breakpointLayouts:[{minimumWidth:960},[wide]]};
            }
            """
        let layout = try await runner.generate(
            source: source, configuration: ["title": .string("Generated"), "wide": .bool(true)])
        check(layout.pages[0].title == "Generated", "explicit configuration reaches buildLayout")
        guard case .verticalStack(_, let narrow) = layout.pages[0].root,
            case .horizontalStack(_, let wide) = layout.breakpointLayouts[
                .init(minimumWidth: 960)]![0].root
        else {
            fatalError("script loops/conditionals must generate real breakpoint layouts")
        }
        check(narrow.count == 2 && narrow == wide, "same instances across breakpoint layouts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "layout-script-regression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(url: root.appendingPathComponent("layout.json"))
        try store.save(layout)
        guard case .loaded(let reloaded) = store.load() else {
            fatalError("saved output cannot reopen")
        }
        check(layout == reloaded, "generated output uses the existing persistence contract")
        let original = try Data(contentsOf: store.url)

        do {
            _ = try await runner.generate(source: source + String(repeating: " ", count: 131_072))
            fatalError("oversized source accepted")
        } catch WorkspaceLayoutScriptError.inputLimit {}
        do {
            _ = try await runner.generate(
                source: "function buildLayout(c) { return {schemaVersion:1,pages:[],extra:1}; }")
            fatalError("unknown output field accepted")
        } catch WorkspaceLayoutScriptError.invalidOutput(let location) {
            check(location.contains("layout"), "output error must identify document field")
        }
        do {
            _ = try await runner.generate(
                source: "function buildLayout(c) {\n throw new Error('fixture-error');\n}")
            fatalError("throw accepted")
        } catch WorkspaceLayoutScriptError.execution(let detail) {
            check(detail.contains("fixture-error"), "script exception must be actionable")
        }
        do {
            _ = try await runner.generate(source: "function buildLayout(c) { while(true) {} }")
            fatalError("unbounded execution accepted")
        } catch WorkspaceLayoutScriptError.timeLimit {}
        do {
            _ = try await runner.generate(source: "function buildLayout(c) { const a=[]; while(true) a.push(new Array(100000).fill(42)); }")
            fatalError("unbounded memory accepted")
        } catch WorkspaceLayoutScriptError.resourceLimit {}
        do {
            _ = try await runner.generate(source: "function buildLayout(c) { return 'x'.repeat(1048575); }")
            fatalError("oversized output accepted")
        } catch WorkspaceLayoutScriptError.outputLimit {}
        let looping = Task {
            try await runner.generate(source: "function buildLayout(c) { while(true) {} }")
        }
        try await Task.sleep(for: .milliseconds(50))
        looping.cancel()
        do {
            _ = try await looping.value
            fatalError("cancelled generation completed")
        } catch is CancellationError {}
        let unchanged = try Data(contentsOf: store.url)
        check(unchanged == original, "failed and cancelled generation must not mutate workspace")
        // A cancelled helper must not poison the next fresh JS context.
        let next = try await runner.generate(
            source: source, configuration: ["title": .string("Again"), "wide": .bool(false)])
        check(next.pages[0].title == "Again", "subsequent independent execution")
        print(
            "WorkspaceLayoutScriptRegression: generated nested/breakpoint layout, persisted/reopened; invalid output, input bound, exception, cancellation and isolation passed"
        )
    }
}
