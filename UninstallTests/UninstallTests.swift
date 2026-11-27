import Foundation
@testable import Uninstall
import XCTest

final class UninstallTests: XCTestCase {
    private var root: URL!
    private var apps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var scanner: AppScanner { AppScanner(applicationDirectories: [apps], libraryDirectory: library) }
    private let identifier = "ch.lkmc.Uninstall.fixture"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testDiscoversAppsInFoldersWithoutFollowingSymlinksOrEmbeddedApps() async throws {
        let editor = try makeApp(relativePath: "Vendor/Editor.app")
        try makeApp(relativePath: "Vendor/Editor.app/Contents/Helpers/Embedded.app")
        try makeApp(relativePath: "../Outside/Other.app")
        let link = apps.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Outside"))

        let installed = await scanner.discover()
        XCTAssertEqual(installed.map { $0.url.resolvingSymlinksInPath().path }, [editor.resolvingSymlinksInPath().path])
        XCTAssertEqual(installed.first?.bundleIdentifier, identifier)
    }

    func testMeasuresExactMatchesAndSkipsSharedFilesAndSymlinks() async throws {
        let editor = try makeApp(relativePath: "Editor.app")
        let appData = editor.appendingPathComponent("Contents/Resources/data")
        try makeFile(at: appData)
        let cache = library.appendingPathComponent("Caches/\(identifier)")
        try makeFile(at: cache.appendingPathComponent("data"))
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        try makeFile(at: preferences)
        let hostPreferences = library.appendingPathComponent("Preferences/ByHost/\(identifier).\(UUID().uuidString).plist")
        try makeFile(at: hostPreferences)
        try makeFile(at: library.appendingPathComponent("Preferences/\(identifier)Other.plist"))
        try makeFile(at: library.appendingPathComponent("Group Containers/\(identifier)/shared"))
        let outside = root.appendingPathComponent("Outside")
        try makeFile(at: outside.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("linked"), withDestinationURL: outside)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent(identifier), withDestinationURL: outside)

        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let footprint = scanner.measure(app)
        XCTAssertTrue(footprint.isComplete)
        XCTAssertEqual(Set(footprint.relatedItems.map(\.url.path)), Set([cache.path, preferences.path, hostPreferences.path]))
        XCTAssertEqual(footprint.bundle.bytes, try allocatedBytes(appData) + allocatedBytes(editor.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(footprint.relatedBytes, try allocatedBytes(cache.appendingPathComponent("data"))
            + allocatedBytes(preferences) + allocatedBytes(hostPreferences))
        XCTAssertEqual(footprint.totalBytes, footprint.bundle.bytes + footprint.relatedBytes)
    }

    func testAppOnlyMovesJustTheBundleToTrash() async throws {
        try makeApp(relativePath: "Editor.app")
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        try makeFile(at: preferences)
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        var trashURL: NSURL?
        defer {
            if let trashURL { try? FileManager.default.removeItem(at: trashURL as URL) }
        }

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: []), moveToTrash: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        })

        XCTAssertEqual(result.moved.map(\.path), [app.url.path])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertNotNil(trashURL)
    }

    func testAppContainersAreMeasuredOnlyOnRequest() async throws {
        try makeApp(relativePath: "Editor.app")
        let containerFile = library.appendingPathComponent("Containers/\(identifier)/Data/Library/Cache")
        try makeFile(at: containerFile)
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)

        let standard = scanner.measure(app)
        let deferred = try XCTUnwrap(standard.relatedItems.first)
        XCTAssertFalse(standard.isComplete)
        XCTAssertTrue(deferred.needsContainerScan)
        XCTAssertFalse(deferred.canRemove)

        let full = scanner.measure(app, includingContainers: true)
        let measured = try XCTUnwrap(full.relatedItems.first)
        XCTAssertTrue(full.isComplete)
        XCTAssertFalse(measured.needsContainerScan)
        XCTAssertTrue(measured.canRemove)
        XCTAssertEqual(full.relatedBytes, try allocatedBytes(containerFile))
    }

    func testProtectedAppsAreMeasuredWithoutOpeningRelatedFiles() async throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)/data"))
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let protected = InstalledApp(id: app.id, url: app.url, name: app.name, bundleIdentifier: app.bundleIdentifier,
                                     identity: app.identity, lastOpened: app.lastOpened, isProtected: true,
                                     vendorUninstaller: nil)
        let footprint = scanner.measure(protected, includingContainers: true)
        XCTAssertTrue(footprint.isComplete)
        XCTAssertTrue(footprint.relatedItems.isEmpty)
        XCTAssertEqual(footprint.totalBytes, footprint.bundle.bytes)
    }

    func testStaleRelatedFileAbortsBeforeTheAppIsMoved() async throws {
        try makeApp(relativePath: "Editor.app")
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        try makeFile(at: preferences)
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let item = try XCTUnwrap(scanner.measure(app).relatedItems.first)

        // Retain the first inode so the new item cannot reuse it.
        try FileManager.default.moveItem(at: preferences, to: preferences.appendingPathExtension("old"))
        try makeFile(at: preferences)

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [item]), moveToTrash: { _ in
            XCTFail("A changed path must not reach the Trash operation")
        })

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testOnlySelectedRelatedFilesAreMovedAndPartialFailureIsReported() async throws {
        try makeApp(relativePath: "Editor.app")
        for path in ["Caches/\(identifier)", "Logs/\(identifier)", "Preferences/\(identifier).plist"] {
            try makeFile(at: library.appendingPathComponent(path))
        }
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let selected = scanner.measure(app).relatedItems.filter { $0.category != .preferences }
        XCTAssertEqual(selected.count, 2)
        var attempts: [URL] = []
        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: selected), moveToTrash: { url in
            attempts.append(url)
            if url.path.contains("/Logs/") {
                throw CocoaError(.fileWriteNoPermission)
            }
        })

        XCTAssertEqual(attempts.map(\.path), [app.url.path] + selected.map(\.url.path))
        XCTAssertEqual(result.moved.map(\.path), [app.url.path] + selected.filter { $0.category == .cache }.map(\.url.path))
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.problems.first).contains("/Logs/"))
    }

    func testPermissionDeniedRetriesTheAppWithAuthorization() async throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let cache = try XCTUnwrap(scanner.measure(app).relatedItems.first)
        var authorized: [URL] = []
        var ordinary: [URL] = []

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [cache]), moveWithAuthorization: {
            authorized.append($0.url)
        }, moveToTrash: { url in
            ordinary.append(url)
            if url == app.url { throw CocoaError(.fileWriteNoPermission) }
        })

        XCTAssertEqual(authorized, [app.url])
        XCTAssertEqual(ordinary, [app.url, cache.url])
        XCTAssertEqual(result.moved, [app.url, cache.url])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertFalse(result.wasCancelled)
    }

    func testCancellingAuthorizationStopsBeforeMovingRelatedFiles() async throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        let cache = try XCTUnwrap(scanner.measure(app).relatedItems.first)
        var attempted: [URL] = []

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [cache]), moveWithAuthorization: { appToMove in
            XCTAssertEqual(appToMove.url, app.url)
            throw CocoaError(.userCancelled)
        }, moveToTrash: { url in
            attempted.append(url)
            throw POSIXError(.EACCES)
        })

        XCTAssertEqual(attempted, [app.url])
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url.path))
    }

    func testOtherTrashErrorsDoNotRequestAuthorization() async throws {
        try makeApp(relativePath: "Editor.app")
        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: []), moveWithAuthorization: { _ in
            XCTFail("An invalid filename must not trigger administrator authentication")
        }, moveToTrash: { _ in
            throw CocoaError(.fileWriteInvalidFileName)
        })

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(result.wasCancelled)
    }

    func testDiscoversManyAppsConcurrentlyWithoutLosingAny() async throws {
        var expected = Set<String>()
        for index in 0..<24 {
            let app = try makeApp(relativePath: "App\(index).app", bundleIdentifier: "dev.example.App\(index)")
            expected.insert(app.resolvingSymlinksInPath().path)
        }

        let installed = await scanner.discover()
        XCTAssertEqual(installed.count, expected.count)
        XCTAssertEqual(Set(installed.map(\.id)), expected)
        // Discovery order must be deterministic across runs.
        let again = await scanner.discover()
        XCTAssertEqual(installed.map(\.id), again.map(\.id))
    }

    func testFindsUninstallerBundledInsideContents() async throws {
        let editor = try makeApp(relativePath: "Editor.app")
        let bundled = editor.appendingPathComponent("Contents/Uninstall Editor.app", isDirectory: true)
            .standardizedFileURL
        try makeApp(at: bundled, bundleIdentifier: "dev.example.EditorUninstaller")

        let installed = await scanner.discover()
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.vendorUninstaller?.resolvingSymlinksInPath().path,
                       bundled.resolvingSymlinksInPath().path)
    }

    func testIgnoresSymlinkedUninstallerInsideContents() async throws {
        let editor = try makeApp(relativePath: "Editor.app")
        let outside = root.appendingPathComponent("Outside/Uninstall Editor.app", isDirectory: true)
            .standardizedFileURL
        try makeApp(at: outside, bundleIdentifier: "dev.example.Outside")
        try FileManager.default.createSymbolicLink(
            at: editor.appendingPathComponent("Contents/Uninstall Editor.app"),
            withDestinationURL: outside)

        let discovered = await scanner.discover()
        let app = try XCTUnwrap(discovered.first)
        XCTAssertNil(app.vendorUninstaller)
    }

    func testFindsSiblingUninstallerNextToTheApp() async throws {
        let editor = try makeApp(relativePath: "Editor.app")
        let uninstaller = try makeApp(relativePath: "Uninstall Editor.app",
                                      bundleIdentifier: "dev.example.Uninstaller")

        let discovered = await scanner.discover()
        let editorPath = editor.resolvingSymlinksInPath().path
        let app = try XCTUnwrap(discovered.first { $0.url.resolvingSymlinksInPath().path == editorPath })
        XCTAssertEqual(app.vendorUninstaller?.resolvingSymlinksInPath().path,
                       uninstaller.resolvingSymlinksInPath().path)
    }

    @discardableResult
    private func makeApp(relativePath: String, bundleIdentifier: String? = nil) throws -> URL {
        try makeApp(at: apps.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL,
                    bundleIdentifier: bundleIdentifier ?? identifier)
    }

    @discardableResult
    private func makeApp(at app: URL, bundleIdentifier: String) throws -> URL {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = ["CFBundleIdentifier": bundleIdentifier, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try makeFile(at: plist, data: data)
        return app
    }

    private func makeFile(at url: URL, data: Data = Data(repeating: 0xa3, count: 8_192)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func allocatedBytes(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
        return Int64(try XCTUnwrap(values.fileAllocatedSize))
    }
}
