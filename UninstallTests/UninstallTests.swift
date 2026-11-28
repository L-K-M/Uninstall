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

    func testDiscoversAppsInFoldersWithoutFollowingSymlinksOrEmbeddedApps() throws {
        let editor = try makeApp(relativePath: "Vendor/Editor.app")
        try makeApp(relativePath: "Vendor/Editor.app/Contents/Helpers/Embedded.app")
        try makeApp(relativePath: "../Outside/Other.app")
        let link = apps.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Outside"))

        let installed = scanner.discover()
        XCTAssertEqual(installed.map { $0.url.resolvingSymlinksInPath().path }, [editor.resolvingSymlinksInPath().path])
        XCTAssertEqual(installed.first?.bundleIdentifier, identifier)
    }

    func testMeasuresExactMatchesAndSkipsSharedFilesAndSymlinks() throws {
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

        let app = try XCTUnwrap(scanner.discover().first)
        let footprint = scanner.measure(app)
        XCTAssertTrue(footprint.isComplete)
        XCTAssertEqual(Set(footprint.relatedItems.map(\.url.path)), Set([cache.path, preferences.path, hostPreferences.path]))
        XCTAssertEqual(footprint.bundle.bytes, try allocatedBytes(appData) + allocatedBytes(editor.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(footprint.relatedBytes, try allocatedBytes(cache.appendingPathComponent("data"))
            + allocatedBytes(preferences) + allocatedBytes(hostPreferences))
        XCTAssertEqual(footprint.totalBytes, footprint.bundle.bytes + footprint.relatedBytes)
    }

    func testAppOnlyMovesJustTheBundleToTrash() throws {
        try makeApp(relativePath: "Editor.app")
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        try makeFile(at: preferences)
        let app = try XCTUnwrap(scanner.discover().first)
        var trashURL: NSURL?
        defer {
            if let trashURL { try? FileManager.default.removeItem(at: trashURL as URL) }
        }

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [], bundleUsage: scanner.measure(app).bundle), moveToTrash: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            return trashURL as URL? ?? url
        })

        XCTAssertEqual(result.moved.map(\.path), [app.url.path])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path))
        XCTAssertNotNil(trashURL)
    }

    func testAppContainersAreMeasuredOnlyOnRequest() throws {
        try makeApp(relativePath: "Editor.app")
        let containerFile = library.appendingPathComponent("Containers/\(identifier)/Data/Library/Cache")
        try makeFile(at: containerFile)
        let app = try XCTUnwrap(scanner.discover().first)

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

    func testProtectedAppsAreMeasuredWithoutOpeningRelatedFiles() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)/data"))
        let app = try XCTUnwrap(scanner.discover().first)
        let protected = InstalledApp(id: app.id, url: app.url, name: app.name, bundleIdentifier: app.bundleIdentifier,
                                     identity: app.identity, lastOpened: app.lastOpened, isProtected: true,
                                     vendorUninstaller: nil)
        let footprint = scanner.measure(protected, includingContainers: true)
        XCTAssertTrue(footprint.isComplete)
        XCTAssertTrue(footprint.relatedItems.isEmpty)
        XCTAssertEqual(footprint.totalBytes, footprint.bundle.bytes)
    }

    func testStaleRelatedFileAbortsBeforeTheAppIsMoved() throws {
        try makeApp(relativePath: "Editor.app")
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        try makeFile(at: preferences)
        let app = try XCTUnwrap(scanner.discover().first)
        let item = try XCTUnwrap(scanner.measure(app).relatedItems.first)

        // Retain the first inode so the new item cannot reuse it.
        try FileManager.default.moveItem(at: preferences, to: preferences.appendingPathExtension("old"))
        try makeFile(at: preferences)

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [item], bundleUsage: scanner.measure(app).bundle), moveToTrash: { _ in
            XCTFail("A changed path must not reach the Trash operation")
            return URL(fileURLWithPath: "/")
        })

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testOnlySelectedRelatedFilesAreMovedAndPartialFailureIsReported() throws {
        try makeApp(relativePath: "Editor.app")
        for path in ["Caches/\(identifier)", "Logs/\(identifier)", "Preferences/\(identifier).plist"] {
            try makeFile(at: library.appendingPathComponent(path))
        }
        let app = try XCTUnwrap(scanner.discover().first)
        let selected = scanner.measure(app).relatedItems.filter { $0.category != .preferences }
        XCTAssertEqual(selected.count, 2)
        var attempts: [URL] = []
        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: selected, bundleUsage: scanner.measure(app).bundle), moveToTrash: { url in
            attempts.append(url)
            if url.path.contains("/Logs/") {
                throw CocoaError(.fileWriteNoPermission)
            }
            return url
        })

        XCTAssertEqual(attempts.map(\.path), [app.url.path] + selected.map(\.url.path))
        XCTAssertEqual(result.moved.map(\.path), [app.url.path] + selected.filter { $0.category == .cache }.map(\.url.path))
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.problems.first).contains("/Logs/"))
    }

    func testPermissionDeniedRetriesTheAppWithAuthorization() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let app = try XCTUnwrap(scanner.discover().first)
        let cache = try XCTUnwrap(scanner.measure(app).relatedItems.first)
        var authorized: [URL] = []
        var ordinary: [URL] = []

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [cache], bundleUsage: scanner.measure(app).bundle), moveWithAuthorization: { appToMove in
            authorized.append(appToMove.url)
            return appToMove.url
        }, moveToTrash: { url in
            ordinary.append(url)
            if url == app.url { throw CocoaError(.fileWriteNoPermission) }
            return url
        })

        XCTAssertEqual(authorized, [app.url])
        XCTAssertEqual(ordinary, [app.url, cache.url])
        XCTAssertEqual(result.moved, [app.url, cache.url])
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertFalse(result.wasCancelled)
    }

    func testCancellingAuthorizationStopsBeforeMovingRelatedFiles() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let app = try XCTUnwrap(scanner.discover().first)
        let cache = try XCTUnwrap(scanner.measure(app).relatedItems.first)
        var attempted: [URL] = []

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [cache], bundleUsage: scanner.measure(app).bundle), moveWithAuthorization: { appToMove in
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

    func testOtherTrashErrorsDoNotRequestAuthorization() throws {
        try makeApp(relativePath: "Editor.app")
        let app = try XCTUnwrap(scanner.discover().first)

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [], bundleUsage: scanner.measure(app).bundle), moveWithAuthorization: { _ in
            XCTFail("An invalid filename must not trigger administrator authentication")
            return URL(fileURLWithPath: "/")
        }, moveToTrash: { _ in
            throw CocoaError(.fileWriteInvalidFileName)
        })

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(result.wasCancelled)
    }

    func testRemovalReportsWhereEachItemLanded() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)/data"))
        let app = try XCTUnwrap(scanner.discover().first)
        let cache = try XCTUnwrap(scanner.measure(app).relatedItems.first { $0.category == .cache })
        let plan = RemovalPlan(app: app, relatedItems: [cache], bundleUsage: scanner.measure(app).bundle)

        let result = AppRemoval.perform(plan, moveToTrash: { url in
            url.appendingPathExtension("trashed")
        })

        XCTAssertEqual(result.moved.map(\.path), [app.url.path, cache.url.path])
        XCTAssertEqual(result.trashed.map(\.original.path), [app.url.path, cache.url.path])
        XCTAssertEqual(result.trashed.map(\.trash.path),
                       [app.url.path + ".trashed", cache.url.path + ".trashed"])
    }

    func testRemovalKeepsTrashDestinationsWhenAuthorizationIsCancelled() throws {
        try makeApp(relativePath: "Editor.app")
        let app = try XCTUnwrap(scanner.discover().first)
        let plan = RemovalPlan(app: app, relatedItems: [], bundleUsage: scanner.measure(app).bundle)

        let result = AppRemoval.perform(plan, moveWithAuthorization: { _ in
            throw CocoaError(.userCancelled)
        }, moveToTrash: { url in
            if url == app.url { throw CocoaError(.fileWriteNoPermission) }
            return url.appendingPathExtension("trashed")
        })

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testReceiptSummaryCountsTheAppItself() throws {
        let receipt = RemovalReceipt(appName: "Editor", icon: NSImage(), trashURL: nil,
                                     relatedCount: 0, problems: [])
        XCTAssertEqual(receipt.itemCount, 1)
        XCTAssertEqual(receipt.summary, "Moved Editor to the Trash.")

        let withOne = RemovalReceipt(appName: "Editor", icon: NSImage(), trashURL: nil,
                                     relatedCount: 1, problems: [])
        XCTAssertEqual(withOne.itemCount, 2)
        XCTAssertEqual(withOne.summary, "Moved Editor and 1 related item to the Trash.")

        let withThree = RemovalReceipt(appName: "Editor", icon: NSImage(), trashURL: nil,
                                       relatedCount: 3, problems: [])
        XCTAssertEqual(withThree.itemCount, 4)
        XCTAssertEqual(withThree.summary, "Moved Editor and 3 related items to the Trash.")
    }

    @discardableResult
    private func makeApp(relativePath: String) throws -> URL {
        let app = apps.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
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
