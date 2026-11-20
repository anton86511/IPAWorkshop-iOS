import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

struct IPAPackage: Sendable {
    let directory: URL
    let app: URL
    let sourceName: String
    let displayName: String
    let bundleID: String
    let version: String
    let images: [String]

    static func open(_ url: URL) throws -> Self {
        guard url.pathExtension.lowercased() == "ipa" else { throw PackageError.notIPA }
        let directory = try workspace()
        do {
            let input = directory.appendingPathComponent("input.ipa")
            try copyFromFiles(url, to: input)
            try validateArchive(input)
            let contents = directory.appendingPathComponent("Contents", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: contents, withIntermediateDirectories: true)
            try manager.unzipItem(at: input, to: contents)
            try manager.removeItem(at: input)

            let payload = contents.appendingPathComponent("Payload", isDirectory: true)
            let apps = try manager.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard apps.count == 1, let app = apps.first else { throw PackageError.invalidApp }
            let metadata = try readPlist(app.appendingPathComponent("Info.plist"))
            guard let bundleID = metadata["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                  let platforms = metadata["CFBundleSupportedPlatforms"] as? [String],
                  platforms.contains("iPhoneOS"),
                  let executable = metadata["CFBundleExecutable"] as? String,
                  !executable.isEmpty, executable != ".", executable != "..",
                  !executable.contains("/"), !executable.contains("\\") else {
                throw PackageError.invalidApp
            }
            try checkExecutable(app.appendingPathComponent(executable))
            let name = (metadata["CFBundleDisplayName"] as? String)
                ?? (metadata["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
            let version = (metadata["CFBundleShortVersionString"] as? String)
                ?? (metadata["CFBundleVersion"] as? String) ?? "未知"
            return Self(directory: directory, app: app, sourceName: url.lastPathComponent,
                        displayName: name, bundleID: bundleID, version: version, images: listImages(app))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func export(name: String, imagePath: String?, replacement: Data?, youtube: YouTubeOptions) throws -> URL {
        let manager = FileManager.default
        let job = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: job, withIntermediateDirectories: true)
        let staged = job.appendingPathComponent("stage", isDirectory: true)
        do {
            try manager.copyItem(at: directory.appendingPathComponent("Contents"), to: staged)
            let stagedApp = staged.appendingPathComponent("Payload", isDirectory: true)
                .appendingPathComponent(app.lastPathComponent, isDirectory: true)
            if !name.isEmpty {
                try Self.renameApp(at: stagedApp, to: name)
            }
            if let imagePath, let replacement {
                guard images.contains(imagePath) else { throw PackageError.invalidImage }
                try replacement.write(to: stagedApp.appendingPathComponent(imagePath), options: .atomic)
            }
            if !youtube.isEmpty {
                try YouTubePackagePatch.apply(youtube, to: stagedApp)
            }
            let originalName = (sourceName as NSString).deletingPathExtension
            let output = job.appendingPathComponent("\(originalName)-edited.ipa")
            try manager.zipItem(at: staged, to: output, shouldKeepParent: false, compressionMethod: .deflate)
            try manager.removeItem(at: staged)
            return output
        } catch {
            try? manager.removeItem(at: job)
            throw error
        }
    }

    static func loadPNG(_ url: URL) throws -> Data {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("image.png")
        try copyFromFiles(url, to: copy)
        let fileSize = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...32_000_000).contains(fileSize),
              let source = CGImageSourceCreateWithURL(copy as CFURL, nil),
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PackageError.invalidImage
        }
        return try Data(contentsOf: copy)
    }

    private static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IPAWorkshop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func copyFromFiles(_ source: URL, to target: URL) throws {
        let accessible = source.startAccessingSecurityScopedResource()
        defer { if accessible { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: url, to: target) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private static func validateArchive(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var paths = Set<String>()
        var size: UInt64 = 0
        for entry in archive {
            var path = entry.path
            if path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            guard !path.contains("\\"), !path.contains("\0"), entry.type != .symlink,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  paths.insert(normalized).inserted else { throw PackageError.invalidArchive }
            let (next, overflow) = size.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= 8_000_000_000, paths.count <= 150_000 else { throw PackageError.largeArchive }
            size = next
        }
        guard !paths.isEmpty else { throw PackageError.invalidArchive }
    }

    private static func readPlist(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = object as? [String: Any] else { throw PackageError.invalidApp }
        return dictionary
    }

    private static func renameApp(at app: URL, to name: String) throws {
        let folder = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
        let localized = folder.filter { $0.pathExtension == "lproj" }
            .map { $0.appendingPathComponent("InfoPlist.strings") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for file in [app.appendingPathComponent("Info.plist")] + localized {
            var metadata = try readPlist(file)
            metadata["CFBundleDisplayName"] = name
            let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
        }
    }

    private static func listImages(_ app: URL) -> [String] {
        let manager = FileManager.default
        guard let files = manager.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var images: [String] = []
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true, ["app", "appex", "framework"].contains(file.pathExtension.lowercased()) {
                files.skipDescendants()
            }
            if values.isRegularFile == true, file.pathExtension.lowercased() == "png" {
                images.append(String(file.path.dropFirst(app.path.count + 1)))
            }
        }
        return images.sorted()
    }

    private static func checkExecutable(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= length, UInt64(count) <= length - offset else { throw PackageError.invalidApp }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw PackageError.invalidApp }
            return data
        }
        func word(_ bytes: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
            let positions = bigEndian ? [0, 1, 2, 3] : [3, 2, 1, 0]
            return positions.reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
        }
        func checkArm64(at offset: UInt64, size: UInt64) throws {
            guard offset <= length, size <= length - offset, size >= 32 else { throw PackageError.invalidApp }
            let header = try read(offset, 32)
            let commands = word(header, 16)
            let commandBytes = UInt64(word(header, 20))
            guard word(header, 0) == 0xfeedfacf, word(header, 4) == 0x0100000c,
                  word(header, 12) == 2, commands <= 4096, commandBytes <= size - 32 else {
                throw PackageError.invalidApp
            }
            var position = offset + 32
            let end = position + commandBytes
            for _ in 0..<commands {
                guard position <= end, end - position >= 8 else { throw PackageError.invalidApp }
                let command = try read(position, 8)
                let kind = word(command, 0)
                let size = UInt64(word(command, 4))
                guard size >= 8, size <= end - position else { throw PackageError.invalidApp }
                if kind == 0x21 || kind == 0x2c {
                    guard size >= 20 else { throw PackageError.invalidApp }
                    if word(try read(position, 20), 16) != 0 { throw PackageError.encrypted }
                }
                position += size
            }
            guard position == end else { throw PackageError.invalidApp }
        }

        let prefix = try read(0, 8)
        let magic = word(prefix, 0, bigEndian: true)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = word(prefix, 4, bigEndian: true)
            let entrySize = magic == 0xcafebabe ? 20 : 32
            guard (1...64).contains(count) else { throw PackageError.invalidApp }
            var found = false
            for index in 0..<Int(count) {
                let entry = try read(UInt64(8 + index * entrySize), entrySize)
                guard word(entry, 0, bigEndian: true) == 0x0100000c else { continue }
                let offset = entrySize == 20 ? UInt64(word(entry, 8, bigEndian: true))
                    : (UInt64(word(entry, 8, bigEndian: true)) << 32) | UInt64(word(entry, 12, bigEndian: true))
                let size = entrySize == 20 ? UInt64(word(entry, 12, bigEndian: true))
                    : (UInt64(word(entry, 16, bigEndian: true)) << 32) | UInt64(word(entry, 20, bigEndian: true))
                try checkArm64(at: offset, size: size)
                found = true
            }
            guard found else { throw PackageError.invalidApp }
        } else {
            try checkArm64(at: 0, size: length)
        }
    }
}

enum PackageError: LocalizedError {
    case notIPA, invalidApp, invalidArchive, largeArchive, encrypted, invalidImage

    var errorDescription: String? {
        switch self {
        case .notIPA: return "請選擇副檔名為 .ipa 的檔案。"
        case .invalidApp: return "找不到有效的 iPhone arm64 App 或 App 資訊不完整。"
        case .invalidArchive: return "封裝包含不支援的檔案路徑或重複項目。"
        case .largeArchive: return "解壓縮後的大小或檔案數超過支援上限。"
        case .encrypted: return "主程式仍有加密。請選擇已解密的 IPA。"
        case .invalidImage: return "請選擇有效且小於 32 MB 的 PNG。"
        }
    }
}
