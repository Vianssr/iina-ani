import Foundation

@main
struct PackageExamples {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["minimal", "full"] {
            let package = try SkinPackageValidator.validate(directoryURL: source.appendingPathComponent(name))
            let archive = destination.appendingPathComponent(name + ".aniskin")
            try SkinArchive.create(from: package.directoryURL, to: archive)
            print("Validated and packaged \(name): \(archive.path)")
        }
    }
}
