import Foundation
@testable import Uninstall
import XCTest

final class UninstallTests: XCTestCase {
    private var root: URL!
    private var apps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var scanner: AppScanner { AppScanner(applicationDirectories: [apps], libraryDirectory: library) }
    private let identifier = "dev.example.Editor"

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

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: []), moveToTrash: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
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

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: [item]), moveToTrash: { _ in
            XCTFail("A changed path must not reach the Trash operation")
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

    func testPermissionDeniedRetriesTheAppWithAuthorization() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let app = try XCTUnwrap(scanner.discover().first)
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

    func testCancellingAuthorizationStopsBeforeMovingRelatedFiles() throws {
        try makeApp(relativePath: "Editor.app")
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)"))
        let app = try XCTUnwrap(scanner.discover().first)
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

    func testOtherTrashErrorsDoNotRequestAuthorization() throws {
        try makeApp(relativePath: "Editor.app")
        let app = try XCTUnwrap(scanner.discover().first)

        let result = AppRemoval.perform(RemovalPlan(app: app, relatedItems: []), moveWithAuthorization: { _ in
            XCTFail("An invalid filename must not trigger administrator authentication")
        }, moveToTrash: { _ in
            throw CocoaError(.fileWriteInvalidFileName)
        })

        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertFalse(result.wasCancelled)
    }

    func testRelatedSelectionDefaultsToCachesAndLogsOnly() throws {
        try makeApp(relativePath: "Editor.app")
        let items = try makeRelatedItems()
        XCTAssertFalse(items.isEmpty)

        let selection = RelatedSelection(allowsRelatedRemoval: true, items: items)
        XCTAssertEqual(selection.selectedIDs, Set(items.filter { $0.category.selectedByDefault }.map(\.id)))
        XCTAssertTrue(selection.isComplete)
        XCTAssertEqual(selection.selectedBytes,
                       items.filter { selection.selectedIDs.contains($0.id) }
                           .reduce(0) { $0 + $1.usage.bytes })
    }

    func testRelatedSelectionHonoursExplicitChecksAndUnchecks() throws {
        try makeApp(relativePath: "Editor.app")
        let items = try makeRelatedItems()
        let cache = try XCTUnwrap(items.first { $0.category == .cache })
        let logs = try XCTUnwrap(items.first { $0.category == .logs })
        let preferences = try XCTUnwrap(items.first { $0.category == .preferences })

        // Unchecking the cache keeps the log, which the user never decided about.
        let checked = RelatedSelection(allowsRelatedRemoval: true, items: items)
            .deselecting(cache).selecting(preferences)
        XCTAssertEqual(checked.selectedIDs, Set([logs.id, preferences.id]))
        XCTAssertEqual(checked.selectedBytes, logs.usage.bytes + preferences.usage.bytes)

        let none = checked.selectingNone()
        XCTAssertTrue(none.selectedIDs.isEmpty)
        XCTAssertEqual(none.selectedBytes, 0)

        let all = none.selectingAll()
        XCTAssertEqual(all.selectedIDs, Set(items.filter(\.canRemove).map(\.id)))
    }

    func testRelatedSelectionKeepsDecisionsForItemsDiscoveredLater() throws {
        try makeApp(relativePath: "Editor.app")
        let first = try makeRelatedItems()
        let cache = try XCTUnwrap(first.first { $0.category == .cache })
        let preferences = try XCTUnwrap(first.first { $0.category == .preferences })

        // The user unchecks the cache and checks the preferences.
        let decided = RelatedSelection(allowsRelatedRemoval: true, items: first)
            .deselecting(cache).selecting(preferences)

        // A rescan finds a saved-state folder that was not there before.
        let savedState = library.appendingPathComponent("Saved Application State/\(identifier).savedState")
        try makeFile(at: savedState.appendingPathComponent("data"))
        let rescanned = try makeRelatedItems()
        let savedItem = try XCTUnwrap(rescanned.first { $0.url.path == savedState.path })

        let carried = RelatedSelection(allowsRelatedRemoval: true, items: rescanned,
                                       checked: decided.checked, unchecked: decided.unchecked)
        XCTAssertFalse(carried.selectedIDs.contains(cache.id), "an unchecked item stays unchecked")
        XCTAssertTrue(carried.selectedIDs.contains(preferences.id), "a checked item stays checked")
        XCTAssertFalse(carried.selectedIDs.contains(savedItem.id),
                       "a newly discovered non-default item is not selected")
    }

    func testRelatedSelectionIsEmptyForSharedAndUnverifiableRows() throws {
        try makeApp(relativePath: "Editor.app")
        let items = try makeRelatedItems()
        XCTAssertFalse(items.isEmpty)

        XCTAssertTrue(RelatedSelection(allowsRelatedRemoval: false, items: items).selectedIDs.isEmpty)

        // An item that cannot be verified never counts, even if explicitly checked.
        let cache = try XCTUnwrap(items.first { $0.category == .cache })
        let unverifiable = RelatedItem(url: cache.url, category: .cache, identity: nil,
                                       usage: .unavailable)
        let forced = RelatedSelection(allowsRelatedRemoval: true, items: [unverifiable],
                                      checked: [unverifiable.id])
        XCTAssertTrue(forced.selectedIDs.isEmpty)
        XCTAssertEqual(forced.selectedBytes, 0)
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

    /// Creates the related files the other tests use and returns the measured items.
    private func makeRelatedItems() throws -> [RelatedItem] {
        try makeFile(at: library.appendingPathComponent("Caches/\(identifier)/data"))
        try makeFile(at: library.appendingPathComponent("Logs/\(identifier)/data"))
        try makeFile(at: library.appendingPathComponent("Preferences/\(identifier).plist"))
        try makeFile(at: library.appendingPathComponent("Application Support/\(identifier)/data"))
        let app = try XCTUnwrap(scanner.discover().first)
        return scanner.measure(app).relatedItems
    }

    private func allocatedBytes(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
        return Int64(try XCTUnwrap(values.fileAllocatedSize))
    }
}
