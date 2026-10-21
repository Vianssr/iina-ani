import Foundation

public enum SkinArchiveError: Error, Equatable, LocalizedError {
    case invalidArchive, unsupportedFormat, encrypted
    case unsafePath(String)
    case duplicatePath(String)
    case nonRegularEntry(String)
    case sizeLimit, tooManyEntries
    case corruptEntry(String)
    case nestedArchive(String)
    case exportDestinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return String(localized: "The Skin ZIP archive is malformed.")
        case .unsupportedFormat:
            return String(localized: "The Skin ZIP uses an unsupported compression, encryption, or archive format.")
        case .encrypted: return String(localized: "Encrypted Skin archives are not supported.")
        case .unsafePath(let path): return String(localized: "The Skin archive contains an unsafe path: \(path).")
        case .duplicatePath(let path): return String(localized: "The Skin archive contains colliding paths: \(path).")
        case .nonRegularEntry(let path):
            return String(localized: "The Skin archive contains a link or non-regular entry: \(path).")
        case .sizeLimit:
            return
                String(localized: "The Skin ZIP exceeds a limit (65 MiB archive, 16 MiB per file, or 64 MiB expanded).")
        case .tooManyEntries: return String(localized: "The Skin archive contains too many entries.")
        case .corruptEntry(let path):
            return String(localized: "The Skin archive entry failed size or CRC validation: \(path).")
        case .nestedArchive(let path): return String(localized: "Nested archives are not allowed in a Skin: \(path).")
        case .exportDestinationExists: return String(localized: "The export destination already exists.")
        }
    }
}

public enum SkinArchive {
    public static let maximumArchiveBytes = 65 * 1024 * 1024
    public static let maximumEntryBytes = 16 * 1024 * 1024
    public static let maximumExpandedBytes = 64 * 1024 * 1024
    public static let maximumEntryCount = 256

    private struct Entry {
        let path: String
        let isDirectory: Bool
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let expandedSize: UInt32
        let localOffset: UInt32
    }

    public static func extract(from archiveURL: URL, to directoryURL: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        guard ((attrs[.size] as? NSNumber)?.int64Value ?? Int64.max) <= maximumArchiveBytes else {
            throw SkinArchiveError.sizeLimit
        }
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        guard data.count <= maximumArchiveBytes else { throw SkinArchiveError.sizeLimit }
        let entries = try parse(data)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var expandedTotal = 0
        for entry in entries {
            let destination = directoryURL.appendingPathComponent(
                entry.path, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
                continue
            }
            let output = try decode(entry, from: data)
            expandedTotal += output.count
            guard expandedTotal <= maximumExpandedBytes else { throw SkinArchiveError.sizeLimit }
            if isNestedArchive(output, path: entry.path) {
                throw SkinArchiveError.nestedArchive(entry.path)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: destination, options: .withoutOverwriting)
        }
    }

    public static func create(from directoryURL: URL, to archiveURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw SkinArchiveError.exportDestinationExists
        }
        let root = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                ], options: [])
        else { throw SkinArchiveError.invalidArchive }
        var files: [(String, Data)] = []
        var names = Set<String>()
        var expanded = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(root.path + "/") else {
                throw SkinArchiveError.unsafePath(item.lastPathComponent)
            }
            let path = String(itemPath.dropFirst(root.path.count + 1))
            if values.isSymbolicLink == true { throw SkinArchiveError.nonRegularEntry(path) }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw SkinArchiveError.nonRegularEntry(path)
            }
            if values.isDirectory == true { continue }
            let safe = try safePath(path)
            let normalized = normalizedPath(safe)
            guard names.insert(normalized).inserted else {
                throw SkinArchiveError.duplicatePath(path)
            }
            let size = values.fileSize ?? Int.max
            guard size <= maximumEntryBytes else { throw SkinArchiveError.sizeLimit }
            let bytes = try Data(contentsOf: item, options: [.mappedIfSafe])
            expanded += bytes.count
            guard expanded <= maximumExpandedBytes else { throw SkinArchiveError.sizeLimit }
            files.append((safe, bytes))
            guard files.count <= maximumEntryCount else { throw SkinArchiveError.tooManyEntries }
        }
        try validateFilePrefixes(names)
        files.sort { $0.0 < $1.0 }
        try writeZip(files, to: archiveURL)
    }

    private static func parse(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw SkinArchiveError.invalidArchive }
        let minimum = max(0, data.count - 65_557)
        var eocd: Int?
        for offset in stride(from: data.count - 22, through: minimum, by: -1)
        where u32(data, offset) == 0x0605_4b50 {
            if offset + 22 + Int(u16(data, offset + 20)) == data.count {
                eocd = offset
                break
            }
        }
        guard let end = eocd else { throw SkinArchiveError.invalidArchive }
        let disk = u16(data, end + 4)
        let centralDisk = u16(data, end + 6)
        let diskCount = u16(data, end + 8)
        let totalCount = u16(data, end + 10)
        let centralSize = UInt64(u32(data, end + 12))
        let centralOffset = UInt64(u32(data, end + 16))
        guard disk == 0, centralDisk == 0, diskCount == totalCount else {
            throw SkinArchiveError.unsupportedFormat
        }
        guard totalCount != UInt16.max, centralSize != UInt32.max, centralOffset != UInt32.max
        else { throw SkinArchiveError.unsupportedFormat }
        guard Int(totalCount) <= maximumEntryCount else { throw SkinArchiveError.tooManyEntries }
        guard centralOffset + centralSize == UInt64(end), centralOffset <= UInt64(data.count) else {
            throw SkinArchiveError.invalidArchive
        }
        var cursor = Int(centralOffset)
        var result: [Entry] = []
        var names = Set<String>()
        var filePaths = Set<String>()
        var localOffsets = Set<UInt32>()
        for _ in 0..<totalCount {
            guard cursor + 46 <= Int(centralOffset + centralSize), u32(data, cursor) == 0x0201_4b50
            else { throw SkinArchiveError.invalidArchive }
            let madeBy = u16(data, cursor + 4)
            let flags = u16(data, cursor + 8)
            let method = u16(data, cursor + 10)
            let crc = u32(data, cursor + 16)
            let compressed = u32(data, cursor + 20)
            let expanded = u32(data, cursor + 24)
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let diskStart = u16(data, cursor + 34)
            let external = u32(data, cursor + 38)
            let localOffset = u32(data, cursor + 42)
            guard diskStart == 0, compressed != UInt32.max, expanded != UInt32.max,
                localOffset != UInt32.max
            else { throw SkinArchiveError.unsupportedFormat }
            guard flags & 0x0001 == 0 else { throw SkinArchiveError.encrypted }
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8 else {
                throw SkinArchiveError.unsupportedFormat
            }
            guard method != 0 || compressed == expanded else {
                throw SkinArchiveError.invalidArchive
            }
            let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
            try validateExtraFields(data, start: cursor + 46 + nameLength, length: extraLength)
            guard recordEnd <= Int(centralOffset + centralSize), nameLength > 0 else {
                throw SkinArchiveError.invalidArchive
            }
            let rawName = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: rawName, encoding: .utf8),
                !(flags & 0x0800 == 0 && rawName.contains(where: { $0 >= 0x80 }))
            else { throw SkinArchiveError.unsupportedFormat }
            let isDirectory = name.hasSuffix("/")
            let path = try safePath(isDirectory ? String(name.dropLast()) : name)
            let normalized = normalizedPath(path)
            guard names.insert(normalized).inserted else {
                throw SkinArchiveError.duplicatePath(name)
            }
            let unixMode = UInt16((external >> 16) & 0xffff)
            if madeBy >> 8 == 3 {
                let type = unixMode & 0xf000
                guard
                    (isDirectory && (type == 0 || type == 0x4000))
                        || (!isDirectory && (type == 0 || type == 0x8000))
                else { throw SkinArchiveError.nonRegularEntry(name) }
            }
            if isDirectory {
                guard expanded == 0 && compressed == 0 && crc == 0 else {
                    throw SkinArchiveError.invalidArchive
                }
            } else {
                guard expanded <= maximumEntryBytes else { throw SkinArchiveError.sizeLimit }
                filePaths.insert(normalized)
            }
            guard localOffsets.insert(localOffset).inserted else {
                throw SkinArchiveError.invalidArchive
            }
            result.append(
                Entry(
                    path: path, isDirectory: isDirectory, method: method, flags: flags, crc: crc,
                    compressedSize: compressed, expandedSize: expanded, localOffset: localOffset))
            cursor = recordEnd
        }
        guard cursor == Int(centralOffset + centralSize) else {
            throw SkinArchiveError.invalidArchive
        }
        try validateFilePrefixes(filePaths)
        var ranges: [(Int, Int)] = []
        for entry in result {
            let offset = Int(entry.localOffset)
            guard offset + 30 <= Int(centralOffset), u32(data, offset) == 0x0403_4b50 else {
                throw SkinArchiveError.invalidArchive
            }
            let localFlags = u16(data, offset + 6)
            let localMethod = u16(data, offset + 8)
            let nameLength = Int(u16(data, offset + 26))
            let extraLength = Int(u16(data, offset + 28))
            try validateExtraFields(data, start: offset + 30 + nameLength, length: extraLength)
            let bodyOffset = offset + 30 + nameLength + extraLength
            guard bodyOffset <= Int(centralOffset), localFlags == entry.flags,
                localMethod == entry.method
            else { throw SkinArchiveError.invalidArchive }
            let expectedName = Data((entry.path + (entry.isDirectory ? "/" : "")).utf8)
            guard offset + 30 + nameLength <= Int(centralOffset),
                data.subdata(in: (offset + 30)..<(offset + 30 + nameLength)) == expectedName
            else { throw SkinArchiveError.invalidArchive }
            guard UInt64(bodyOffset) + UInt64(entry.compressedSize) <= centralOffset else {
                throw SkinArchiveError.invalidArchive
            }
            let descriptor = entry.flags & 0x0008 != 0
            if !descriptor || u32(data, offset + 14) != 0 || u32(data, offset + 18) != 0
                || u32(data, offset + 22) != 0
            {
                guard u32(data, offset + 14) == entry.crc,
                    u32(data, offset + 18) == entry.compressedSize,
                    u32(data, offset + 22) == entry.expandedSize
                else { throw SkinArchiveError.invalidArchive }
            }
            ranges.append((offset, bodyOffset + Int(entry.compressedSize)))
        }
        ranges.sort { $0.0 < $1.0 }
        if ranges.count > 1 {
            for index in 1..<ranges.count where ranges[index].0 < ranges[index - 1].1 {
                throw SkinArchiveError.invalidArchive
            }
        }
        return result
    }

    private static func decode(_ entry: Entry, from data: Data) throws -> Data {
        let offset = Int(entry.localOffset)
        let start = offset + 30 + Int(u16(data, offset + 26)) + Int(u16(data, offset + 28))
        let compressedLength = Int(entry.compressedSize)
        let outputLength = Int(entry.expandedSize)
        var output: Data
        var consumed = 0
        var produced = 0
        if entry.method == 0 {
            guard compressedLength == outputLength else {
                throw SkinArchiveError.corruptEntry(entry.path)
            }
            output = data.subdata(in: start..<(start + compressedLength))
            consumed = compressedLength
            produced = outputLength
        } else {
            output = Data(count: outputLength + 1)
            let status = data.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { target in
                    skin_inflate_raw(
                        source.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start),
                        compressedLength,
                        target.baseAddress!.assumingMemoryBound(to: UInt8.self), outputLength + 1,
                        &consumed, &produced)
                }
            }
            guard status == 0 else { throw SkinArchiveError.corruptEntry(entry.path) }
            output.removeSubrange(produced..<output.count)
        }
        guard consumed == compressedLength, produced == outputLength, produced <= maximumEntryBytes
        else { throw SkinArchiveError.corruptEntry(entry.path) }
        let crc = output.withUnsafeBytes { bytes in
            skin_zip_crc32(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
        }
        guard crc == entry.crc else { throw SkinArchiveError.corruptEntry(entry.path) }
        return output
    }

    private static func safePath(_ source: String) throws -> String {
        let path = source.precomposedStringWithCanonicalMapping
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SkinArchiveError.unsafePath(source) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkinArchiveError.unsafePath(source)
        }
        return path
    }
    private static func normalizedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func validateFilePrefixes(_ paths: Set<String>) throws {
        for path in paths {
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                guard !paths.contains(parent) else { throw SkinArchiveError.duplicatePath(parent) }
            }
        }
    }
    private static func isNestedArchive(_ data: Data, path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let signatures =
            data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x1f, 0x8b])
            || data.starts(with: [0x1f, 0x9d]) || data.starts(with: [0x42, 0x5a, 0x68])
            || data.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
            || data.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])
            || data.starts(with: [0x52, 0x61, 0x72, 0x21])
            || data.starts(with: [0x04, 0x22, 0x4d, 0x18])
            || data.starts(with: [0x28, 0xb5, 0x2f, 0xfd])
            || (data.count >= 262 && data[257..<262].elementsEqual([0x75, 0x73, 0x74, 0x61, 0x72]))
        return [
            "zip", "iinaskin", "jar", "apk", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
            "xz", "txz", "zst", "lz4", "z",
        ].contains(ext) || signatures
    }

    private static func writeZip(_ files: [(String, Data)], to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SkinArchiveError.exportDestinationExists
        }
        var archive = Data()
        var central = Data()
        for (path, bytes) in files {
            guard bytes.count <= maximumEntryBytes, archive.count <= maximumArchiveBytes else {
                throw SkinArchiveError.sizeLimit
            }
            let name = Data(path.utf8)
            let crc = bytes.withUnsafeBytes {
                skin_zip_crc32($0.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
            }
            guard name.count <= Int(UInt16.max) else { throw SkinArchiveError.sizeLimit }
            let offset = UInt32(archive.count)
            let size = UInt32(bytes.count)
            append32(0x0403_4b50, to: &archive)
            append16(20, to: &archive)
            append16(0x0800, to: &archive)
            append16(0, to: &archive)
            append16(0, to: &archive)
            append16(0, to: &archive)
            append32(crc, to: &archive)
            append32(size, to: &archive)
            append32(size, to: &archive)
            append16(UInt16(name.count), to: &archive)
            append16(0, to: &archive)
            archive.append(name)
            archive.append(bytes)
            append32(0x0201_4b50, to: &central)
            append16(0x0314, to: &central)
            append16(20, to: &central)
            append16(0x0800, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(crc, to: &central)
            append32(size, to: &central)
            append32(size, to: &central)
            append16(UInt16(name.count), to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0, to: &central)
            append32(offset, to: &central)
            central.append(name)
        }
        guard files.count <= maximumEntryCount,
            archive.count + central.count + 22 <= maximumArchiveBytes,
            files.count <= Int(UInt16.max), archive.count <= Int(UInt32.max),
            central.count <= Int(UInt32.max)
        else { throw SkinArchiveError.sizeLimit }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        append32(0x0605_4b50, to: &archive)
        append16(0, to: &archive)
        append16(0, to: &archive)
        append16(UInt16(files.count), to: &archive)
        append16(UInt16(files.count), to: &archive)
        append32(UInt32(central.count), to: &archive)
        append32(centralOffset, to: &archive)
        append16(0, to: &archive)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).iinaskin-tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try archive.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: url) } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                throw SkinArchiveError.exportDestinationExists
            }
            throw error
        }
    }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }
    private static func validateExtraFields(_ data: Data, start: Int, length: Int) throws {
        let end = start + length
        guard end <= data.count else { throw SkinArchiveError.invalidArchive }
        var cursor = start
        while cursor < end {
            guard cursor + 4 <= end else { throw SkinArchiveError.invalidArchive }
            let kind = u16(data, cursor)
            let size = Int(u16(data, cursor + 2))
            cursor += 4
            guard cursor + size <= end else { throw SkinArchiveError.invalidArchive }
            guard [UInt16(0x5455), 0x000a, 0x7875].contains(kind) else {
                throw SkinArchiveError.unsupportedFormat
            }
            cursor += size
        }
    }
    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }
    private static func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(value & 0xffff), to: &data)
        append16(UInt16(value >> 16), to: &data)
    }
}
