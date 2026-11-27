import Foundation
@testable import Uninstall
import XCTest

final class UIFlowTests: XCTestCase {
    private var root: URL!
    private var apps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    private var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    private var scanner: AppScanner { AppScanner(applicationDirectories: [apps], libraryDirectory: library) }
    private let identifier = "ch.lkmc.Uninstall.flowfixture"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: RemovalHistory.recordsKey)
        UserDefaults.standard.removeObject(forKey: RemovalHistory.reclaimedKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: RemovalHistory.recordsKey)
        UserDefaults.standard.removeObject(forKey: RemovalHistory.reclaimedKey)
        try FileManager.default.removeItem(at: root)
    }

    func testPerformBatchCapturesTrashLocationsAndPutBackRestores() throws {
        let appA = try makeApp(relativePath: "Alpha.app", bundleIdentifier: "ch.lkmc.Uninstall.Alpha")
        let appB = try makeApp(relativePath: "Beta.app", bundleIdentifier: "ch.lkmc.Uninstall.Beta")
        let cacheA = library.appendingPathComponent("Caches/ch.lkmc.Uninstall.Alpha")
        try makeFile(at: cacheA.appendingPathComponent("data"))
        let discovered = scanner.discover()
        let alpha = try XCTUnwrap(discovered.first { $0.url.resolvingSymlinksInPath().path == appA.resolvingSymlinksInPath().path })
        let beta = try XCTUnwrap(discovered.first { $0.url.resolvingSymlinksInPath().path == appB.resolvingSymlinksInPath().path })
        let alphaCache = try XCTUnwrap(scanner.measure(alpha).relatedItems.first)

        let plans = [
            RemovalPlan(app: alpha, relatedItems: [alphaCache]),
            RemovalPlan(app: beta, relatedItems: []),
        ]
        let result = RemovalService.performBatch(plans, moveToTrash: { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })

        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(Set(result.moved.map { $0.original }), Set([alpha.url, alphaCache.url, beta.url]))
        XCTAssertTrue(result.moved.allSatisfy { $0.trash != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: appA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appB.path))

        for item in result.moved {
            let record = RemovalRecord(appName: "Test", originalPath: item.original.path,
                                       trashPath: item.trash!.path, bytes: 0, date: Date())
            XCTAssertTrue(RemovalHistory.putBack(record))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: appA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheA.appendingPathComponent("data").path))
    }

    func testPutBackRefusesWhenOriginalPathIsTaken() throws {
        let file = root.appendingPathComponent("item")
        try makeFile(at: file)
        let trashed = trash.appendingPathComponent("item")
        try FileManager.default.moveItem(at: file, to: trashed)
        try makeFile(at: file)

        let record = RemovalRecord(appName: "Test", originalPath: file.path,
                                   trashPath: trashed.path, bytes: 0, date: Date())
        XCTAssertFalse(RemovalHistory.putBack(record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testPutBackRefusesSymlinkedTrashPath() throws {
        let file = root.appendingPathComponent("item")
        try makeFile(at: file)
        let outside = root.appendingPathComponent("outside")
        try makeFile(at: outside)
        let link = trash.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let record = RemovalRecord(appName: "Test", originalPath: file.path,
                                   trashPath: link.path, bytes: 0, date: Date())
        XCTAssertFalse(RemovalHistory.putBack(record))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testHistoryAppendsRecordsAndAccumulatesReclaimedBytes() {
        XCTAssertEqual(RemovalHistory.records().count, 0)
        XCTAssertEqual(RemovalHistory.reclaimedTotal, 0)

        RemovalHistory.append(RemovalRecord(appName: "A", originalPath: "/a", trashPath: "/t/a",
                                            bytes: 100, date: Date()))
        RemovalHistory.append(RemovalRecord(appName: "B", originalPath: "/b", trashPath: "/t/b",
                                            bytes: 250, date: Date()))

        XCTAssertEqual(RemovalHistory.records().map(\.appName), ["B", "A"])
        XCTAssertEqual(RemovalHistory.reclaimedTotal, 350)
    }

    @discardableResult
    private func makeApp(relativePath: String, bundleIdentifier: String) throws -> URL {
        let app = apps.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
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
}
