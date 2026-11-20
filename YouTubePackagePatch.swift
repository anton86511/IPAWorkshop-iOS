import Foundation

struct YouTubeOptions: OptionSet, Sendable {
    let rawValue: UInt32

    static let fewerAds = Self(rawValue: 1 << 0)
    static let backgroundAudio = Self(rawValue: 1 << 1)
    static let hideShortsTab = Self(rawValue: 1 << 2)
    static let cleanShareLinks = Self(rawValue: 1 << 3)
    static let sponsorBlock = Self(rawValue: 1 << 4)
}

enum YouTubePackagePatch {
    static let bundleID = "com.google.ios.youtube"
    static let libraryName = "IPAWorkshopYouTube.dylib"
    static let loadPath = "@executable_path/Frameworks/" + libraryName

    static func apply(_ options: YouTubeOptions, to app: URL) throws {
        let plist = app.appendingPathComponent("Info.plist")
        let original = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        guard var metadata = original as? [String: Any],
              metadata["CFBundleIdentifier"] as? String == bundleID,
              let executable = metadata["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\\") else { throw PatchError.incompatible }
        guard let library = Bundle.main.url(forResource: "YouTubePatch", withExtension: "bin") else {
            throw PatchError.missingLibrary
        }
        let manager = FileManager.default
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        let destination = frameworks.appendingPathComponent(libraryName)
        guard !manager.fileExists(atPath: destination.path) else { throw PatchError.alreadyPatched }
        try appendLoadCommand(to: app.appendingPathComponent(executable))
        try manager.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try manager.copyItem(at: library, to: destination)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        metadata["IPAWorkshopYouTubeOptions"] = NSNumber(value: options.rawValue)
        if options.contains(.backgroundAudio) {
            var modes = metadata["UIBackgroundModes"] as? [String] ?? []
            if !modes.contains("audio") { modes.append("audio") }
            metadata["UIBackgroundModes"] = modes
        }
        let updated = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try updated.write(to: plist, options: .atomic)
    }

    static func appendLoadCommand(to executable: URL) throws {
        let file = try FileHandle(forUpdating: executable)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 32), header.count == 32,
              word(header, 0) == 0xfeedfacf, word(header, 4) == 0x0100000c,
              word(header, 12) == 2 else { throw PatchError.incompatible }
        let commandCount = word(header, 16)
        let commandLength = Int(word(header, 20))
        guard (1...4096).contains(commandCount), (8...4_194_304).contains(commandLength),
              let commands = try file.read(upToCount: commandLength), commands.count == commandLength else {
            throw PatchError.incompatible
        }
        let earliestData = try firstSectionOffset(in: commands, count: commandCount)
        let path = Data(loadPath.utf8) + Data([0])
        let size = (24 + path.count + 7) & ~7
        let end = 32 + commandLength
        guard earliestData >= end + size, UInt64(earliestData) <= (try file.seekToEnd()) else {
            throw PatchError.noSpace
        }
        try file.seek(toOffset: UInt64(end))
        guard let padding = try file.read(upToCount: size), padding.count == size,
              padding.allSatisfy({ $0 == 0 }) else { throw PatchError.noSpace }

        var command = Data()
        let fields: [UInt32] = [0xc, UInt32(size), 24, 0, 0x10000, 0x10000]
        for value in fields {
            command.append(littleEndian(value))
        }
        command.append(path)
        command.append(Data(repeating: 0, count: size - command.count))
        try file.seek(toOffset: UInt64(end))
        try file.write(contentsOf: command)
        try file.seek(toOffset: 16)
        try file.write(contentsOf: littleEndian(commandCount + 1) + littleEndian(UInt32(commandLength + size)))
        try file.synchronize()
    }

    private static func firstSectionOffset(in commands: Data, count: UInt32) throws -> Int {
        var offset = 0
        var first = Int.max
        for _ in 0..<count {
            guard commands.count - offset >= 8 else { throw PatchError.incompatible }
            let kind = word(commands, offset)
            let size = Int(word(commands, offset + 4))
            guard size >= 8, size.isMultiple(of: 8), size <= commands.count - offset else {
                throw PatchError.incompatible
            }
            if kind == 0x2c {
                guard size >= 24, word(commands, offset + 16) == 0 else { throw PatchError.incompatible }
            }
            if kind == 0xc || kind == 0x80000018 || kind == 0x8000001f ||
                kind == 0x20 || kind == 0x80000023 {
                guard size >= 24 else { throw PatchError.incompatible }
                let start = Int(word(commands, offset + 8))
                guard (24..<size).contains(start) else { throw PatchError.incompatible }
                let bytes = commands[(offset + start)..<(offset + size)].prefix(while: { $0 != 0 })
                if String(decoding: bytes, as: UTF8.self) == loadPath { throw PatchError.alreadyPatched }
            }
            if kind == 0x19 {
                guard size >= 72 else { throw PatchError.incompatible }
                let sections = Int(word(commands, offset + 64))
                guard sections <= (size - 72) / 80 else { throw PatchError.incompatible }
                for section in 0..<sections {
                    let dataOffset = Int(word(commands, offset + 72 + section * 80 + 48))
                    if dataOffset > 0 { first = min(first, dataOffset) }
                }
            }
            offset += size
        }
        guard offset == commands.count, first != Int.max else { throw PatchError.incompatible }
        return first
    }

    private static func word(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

enum PatchError: LocalizedError {
    case incompatible, missingLibrary, alreadyPatched, noSpace

    var errorDescription: String? {
        switch self {
        case .incompatible: return "YouTube 補丁需要原始套件識別碼與單一 arm64 執行檔。"
        case .missingLibrary: return "這個版本缺少內建的 YouTube 補丁。"
        case .alreadyPatched: return "這個 IPA 已套用 IPA 工坊的 YouTube 補丁。請以原始已解密 IPA 開始。"
        case .noSpace: return "這個 YouTube 版本的程式標頭沒有足夠空間加入補丁。"
        }
    }
}
