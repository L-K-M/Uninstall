import Darwin
import Foundation
import CoreServices

struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let createdSeconds: Int
    let createdNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        createdSeconds = info.st_birthtimespec.tv_sec
        createdNanoseconds = info.st_birthtimespec.tv_nsec
    }
}

struct InstalledApp: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let identity: FileIdentity
    let lastOpened: Date?
    let isProtected: Bool
    let vendorUninstaller: URL?
}

struct DiskUsage: Sendable {
    let bytes: Int64
    let isComplete: Bool

    static let unavailable = DiskUsage(bytes: 0, isComplete: false)
}

enum RelatedCategory: String, Sendable {
    case cache = "Cache"
    case logs = "Logs"
    case preferences = "Preferences"
    case support = "Application Support"
    case savedState = "Saved State"
    case webData = "Website Data"
    case scripts = "Application Scripts"
    case container = "App Container"

    var selectedByDefault: Bool {
        self == .cache || self == .logs
    }

    var note: String? {
        switch self {
        case .support, .container:
            "May contain saved data or documents."
        case .preferences:
            "Resets stored preferences."
        case .webData:
            "May include sign-in data."
        default:
            nil
        }
    }
}

struct RelatedItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let category: RelatedCategory
    let identity: FileIdentity?
    let usage: DiskUsage
    var needsContainerScan = false

    var canRemove: Bool { identity != nil }
}

struct AppFootprint: Sendable {
    let bundle: DiskUsage
    let relatedItems: [RelatedItem]
    let relatedInventoryComplete: Bool

    var relatedBytes: Int64 { relatedItems.reduce(0) { $0 + $1.usage.bytes } }
    var totalBytes: Int64 { bundle.bytes + relatedBytes }
    var isComplete: Bool {
        bundle.isComplete && relatedInventoryComplete && relatedItems.allSatisfy(\.usage.isComplete)
    }
}

struct AppScanner: Sendable {
    let applicationDirectories: [URL]
    let libraryDirectory: URL

    static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            ],
            libraryDirectory: home.appendingPathComponent("Library", isDirectory: true)
        )
    }

    init(applicationDirectories: [URL], libraryDirectory: URL) {
        self.applicationDirectories = applicationDirectories.map { $0.resolvingSymlinksInPath() }
        self.libraryDirectory = libraryDirectory.resolvingSymlinksInPath()
    }

    func discover() -> [InstalledApp] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsReadOnlyKey]
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for directory in applicationDirectories {
            guard let contents = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in contents {
                if Task.isCancelled { return apps }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                if url.pathExtension.lowercased() == "app" {
                    contents.skipDescendants()
                    guard let app = makeApp(at: url, readOnly: values.volumeIsReadOnly == true),
                          seen.insert(app.id).inserted
                    else { continue }
                    apps.append(app)
                }
            }
        }
        return apps
    }

    func measure(_ app: InstalledApp, includingContainers: Bool = false) -> AppFootprint {
        var sizes = DiskMeasurement()
        let bundle = sizes.measure(at: app.url)
        guard !app.isProtected, let identifier = app.bundleIdentifier, Self.isPathComponent(identifier) else {
            return AppFootprint(bundle: bundle, relatedItems: [], relatedInventoryComplete: true)
        }

        var candidates: [(path: String, category: RelatedCategory)] = [
            ("Caches/\(identifier)", .cache),
            ("Logs/\(identifier)", .logs),
            ("Preferences/\(identifier).plist", .preferences),
            ("Application Support/\(identifier)", .support),
            ("Saved Application State/\(identifier).savedState", .savedState),
            ("HTTPStorages/\(identifier)", .webData),
            ("HTTPStorages/\(identifier).binarycookies", .webData),
            ("Cookies/\(identifier).binarycookies", .webData),
            ("WebKit/\(identifier)", .webData),
            ("Application Scripts/\(identifier)", .scripts),
            ("Containers/\(identifier)", .container),
        ]

        let byHost = libraryDirectory.appendingPathComponent("Preferences/ByHost", isDirectory: true)
        var relatedInventoryComplete = true
        if Self.isDirectPath(byHost) {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: byHost.path)
                let prefix = identifier + "."
                for file in names.sorted() where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
                    let host = file.dropFirst(prefix.count).dropLast(".plist".count)
                    if UUID(uuidString: String(host)) != nil {
                        candidates.append(("Preferences/ByHost/\(file)", .preferences))
                    }
                }
            } catch let error as CocoaError {
                relatedInventoryComplete = error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
            } catch {
                relatedInventoryComplete = false
            }
        }

        var relatedItems: [RelatedItem] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            let url = libraryDirectory.appendingPathComponent(candidate.path)
            guard Self.isDirectPath(url) else { continue }

            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == EACCES || errno == EPERM {
                    relatedItems.append(RelatedItem(url: url, category: candidate.category,
                                                    identity: nil, usage: .unavailable))
                }
                continue
            }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else { continue }
            if candidate.category == .container && !includingContainers {
                relatedItems.append(RelatedItem(url: url, category: .container, identity: nil,
                                                usage: .unavailable, needsContainerScan: true))
                continue
            }
            relatedItems.append(RelatedItem(url: url, category: candidate.category,
                                            identity: FileIdentity(info), usage: sizes.measure(at: url)))
        }

        return AppFootprint(bundle: bundle, relatedItems: relatedItems,
                            relatedInventoryComplete: relatedInventoryComplete)
    }

    static func isDirectPath(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path
    }

    static func fileIdentity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
            return nil
        }
        return FileIdentity(info)
    }

    private static func isPathComponent(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier != "." && identifier != ".."
            && identifier.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || byte == 45 || byte == 46
            }
    }

    private func makeApp(at url: URL, readOnly: Bool) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let identity = Self.fileIdentity(at: url),
              let info = bundle.infoDictionary
        else { return nil }

        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let metadata = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
        let lastOpened = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let path = url.resolvingSymlinksInPath().path
        let isSelf = path == Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let isProtected = readOnly || url.path.hasPrefix("/System/") || isSelf

        return InstalledApp(id: path, url: url, name: name, bundleIdentifier: bundle.bundleIdentifier,
                            identity: identity, lastOpened: lastOpened, isProtected: isProtected,
                            vendorUninstaller: isProtected ? nil : vendorUninstaller(for: url, named: name))
    }

    private func vendorUninstaller(for appURL: URL, named name: String) -> URL? {
        let parent = appURL.deletingLastPathComponent()
        let stem = appURL.deletingPathExtension().lastPathComponent
        var names = ["Uninstall \(stem)", "\(stem) Uninstaller"]
        if name != stem && !name.contains("/") {
            names += ["Uninstall \(name)", "\(name) Uninstaller"]
        }
        if parent.lastPathComponent == stem || parent.lastPathComponent == name {
            names += ["Uninstall", "Uninstaller"]
        }
        return names.lazy.map { parent.appendingPathComponent($0).appendingPathExtension("app") }
            .first { $0.path != appURL.path && Self.isDirectPath($0)
                && Self.fileIdentity(at: $0) != nil && Bundle(url: $0)?.infoDictionary != nil }
    }
}

private struct DiskMeasurement {
    private struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private var countedHardLinks = Set<HardLink>()

    mutating func measure(at url: URL) -> DiskUsage {
        var root = stat()
        guard lstat(url.path, &root) == 0 else { return .unavailable }
        let type = root.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFREG) {
            return DiskUsage(bytes: measureFile(root), isComplete: true)
        }
        guard type == mode_t(S_IFDIR) else { return .unavailable }

        var complete = true
        guard let contents = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in
                complete = false
                return true
            }
        ) else { return .unavailable }

        var bytes: Int64 = 0
        for case let child as URL in contents {
            if Task.isCancelled { return DiskUsage(bytes: bytes, isComplete: false) }
            var info = stat()
            guard lstat(child.path, &info) == 0 else {
                complete = false
                continue
            }
            let childType = info.st_mode & mode_t(S_IFMT)
            if info.st_dev != root.st_dev {
                if childType == mode_t(S_IFDIR) { contents.skipDescendants() }
                complete = false
            } else if childType == mode_t(S_IFREG) {
                bytes += measureFile(info)
            }
        }
        return DiskUsage(bytes: bytes, isComplete: complete)
    }

    private mutating func measureFile(_ info: stat) -> Int64 {
        if info.st_nlink > 1 && !countedHardLinks.insert(HardLink(device: info.st_dev, inode: info.st_ino)).inserted {
            return 0
        }
        return Int64(info.st_blocks) * 512
    }
}
