import AppKit
import Foundation
import Observation

/// Caches the bundle icons the table renders.
///
/// `NSWorkspace.icon(forFile:)` is synchronous and is called once per cell render, so
/// without a cache every observable change to the scan re-resolves the icon of every
/// visible row.
@MainActor
enum IconCache {
    private static let storage = NSCache<NSURL, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = storage.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        storage.setObject(icon, forKey: key)
        return icon
    }

    static func clear() {
        storage.removeAllObjects()
    }
}

/// A row the table renders.
///
/// This is a class rather than a struct so that completing one app's measurement
/// invalidates only that row. With a struct inside `AppModel.rows`, writing
/// `rows[index].footprint` mutates the whole array, and SwiftUI rebuilds every cell —
/// including re-resolving every app icon — for each of the ~30 measurements in a scan.
@Observable
final class AppRow: Identifiable {
    let id: String
    let app: InstalledApp

    var observedLaunch: Date?
    var footprint: AppFootprint?
    var hasOtherInstallations = false

    init(app: InstalledApp, observedLaunch: Date?, hasOtherInstallations: Bool) {
        self.id = app.id
        self.app = app
        self.observedLaunch = observedLaunch
        self.hasOtherInstallations = hasOtherInstallations
    }

    var name: String { app.name }

    var lastOpened: Date? {
        guard let observedLaunch else { return app.lastOpened }
        return max(observedLaunch, app.lastOpened ?? .distantPast)
    }

    var lastOpenedSortValue: Date { lastOpened ?? .distantPast }
    var totalSortValue: Int64 { footprint?.totalBytes ?? 0 }
}

struct RemovalNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class AppModel {
    private(set) var rows: [AppRow] = []
    private(set) var isScanning = false
    private(set) var completedScans = 0
    private(set) var removingName: String?
    private(set) var runningPaths: Set<String> = []
    private(set) var status: String?
    var selection: String?
    var pendingPlan: RemovalPlan?
    var notice: RemovalNotice?

    @ObservationIgnored private let scanner = AppScanner.standard
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var includeContainers = false
    @ObservationIgnored private var observedLaunches = UserDefaults.standard.object(forKey: "observedLaunches") as? [String: Double] ?? [:]

    var selectedRow: AppRow? { rows.first { $0.id == selection } }

    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()
    }

    func refresh(includingContainers: Bool? = nil) {
        guard removingName == nil, pendingPlan == nil else { return }
        if let includingContainers { includeContainers = includingContainers }
        scanTask?.cancel()
        isScanning = true
        completedScans = 0
        status = nil
        refreshRunningApps()
        let scanner = scanner
        let includeContainers = includeContainers
        let selectedID = selection

        scanTask = Task {
            let apps = await withTaskGroup(of: [InstalledApp].self) { group in
                group.addTask { scanner.discover() }
                return await group.next() ?? []
            }
            guard !Task.isCancelled else { return }

            let counts = apps.reduce(into: [String: Int]()) { counts, app in
                if let identifier = app.bundleIdentifier {
                    counts[identifier.lowercased(), default: 0] += 1
                }
            }
            rows = apps.map { app in
                let copies = counts[app.bundleIdentifier?.lowercased() ?? "", default: 0]
                return AppRow(app: app, observedLaunch: observedLaunch(for: app), hasOtherInstallations: copies > 1)
            }
            refreshRunningApps()
            if !rows.contains(where: { $0.id == selection }) {
                selection = nil
            }

            // Measure the app the user is looking at first, then the rest in discovery
            // order. Discovery order alone can leave a selected app waiting behind
            // dozens of large bundles.
            let order = apps.indices.sorted { lhs, rhs in
                let lhsPriority = apps[lhs].id == selectedID ? 0 : 1
                let rhsPriority = apps[rhs].id == selectedID ? 0 : 1
                return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
            }
            var cursor = order.makeIterator()

            await withTaskGroup(of: (Int, AppFootprint).self) { group in
                for _ in 0..<min(3, apps.count) {
                    if let index = cursor.next() {
                        let app = apps[index]
                        group.addTask { (index, scanner.measure(app, includingContainers: includeContainers)) }
                    }
                }

                // Coalesce completions. A scan of ~90 apps produces ~30 results, and
                // writing each one straight through invalidates the table that often.
                var pending: [(Int, AppFootprint)] = []
                var lastFlush = ContinuousClock.now
                let flush: () -> Void = { [self] in
                    guard !pending.isEmpty else { return }
                    for (index, footprint) in pending {
                        self.rows[index].footprint = footprint
                    }
                    pending.removeAll(keepingCapacity: true)
                    lastFlush = ContinuousClock.now
                }

                for await (index, footprint) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    pending.append((index, footprint))
                    completedScans += 1
                    if ContinuousClock.now - lastFlush >= .milliseconds(50) {
                        flush()
                    }
                    if let index = cursor.next() {
                        let app = apps[index]
                        group.addTask { (index, scanner.measure(app, includingContainers: includeContainers)) }
                    }
                }
                flush()
            }

            guard !Task.isCancelled else { return }
            isScanning = false
        }
    }

    func refreshRunningApps() {
        let installedPaths = Set(rows.map(\.id))
        var paths: Set<String> = []
        var didChange = false
        for running in NSWorkspace.shared.runningApplications {
            guard let path = running.bundleURL?.resolvingSymlinksInPath().path else { continue }
            paths.insert(path)
            if installedPaths.contains(path), let date = running.launchDate?.timeIntervalSince1970,
               date > observedLaunches[path, default: 0] {
                observedLaunches[path] = date
                didChange = true
            }
        }
        runningPaths = paths
        guard didChange else { return }

        UserDefaults.standard.set(observedLaunches, forKey: "observedLaunches")
        for row in rows {
            let date = observedLaunch(for: row.app)
            if row.observedLaunch != date {
                row.observedLaunch = date
            }
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        runningPaths.contains(app.id)
    }

    private func observedLaunch(for app: InstalledApp) -> Date? {
        guard let timestamp = observedLaunches[app.id],
              timestamp >= Double(app.identity.createdSeconds)
        else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func prepareRemoval(for row: AppRow, relatedIDs: Set<String>) {
        guard !row.app.isProtected, removingName == nil, !isRunning(row.app) else { return }
        let related = row.hasOtherInstallations ? [] : (row.footprint?.relatedItems ?? []).filter {
            relatedIDs.contains($0.id) && $0.canRemove
        }
        pendingPlan = RemovalPlan(app: row.app, relatedItems: related)
    }

    func confirmRemoval(_ plan: RemovalPlan) {
        guard pendingPlan?.id == plan.id, removingName == nil else { return }
        pendingPlan = nil

        let app = plan.app
        let activeApps = NSWorkspace.shared.runningApplications
        let isInUse = activeApps.contains { active in
            if active.bundleURL?.resolvingSymlinksInPath().path == app.id { return true }
            guard let identifier = app.bundleIdentifier else { return false }
            return active.bundleIdentifier?.caseInsensitiveCompare(identifier) == .orderedSame
                && (active.bundleURL == nil || !plan.relatedItems.isEmpty)
        }
        guard !isInUse else {
            refreshRunningApps()
            notice = RemovalNotice(title: "Quit \(app.name) first",
                                   message: "The app or another copy is running.")
            return
        }

        removingName = app.name
        status = nil
        scanTask?.cancel()
        isScanning = false

        Task {
            let result = await withTaskGroup(of: RemovalResult.self) { group in
                group.addTask { AppRemoval.perform(plan) }
                return await group.next()
            }
            removingName = nil
            if let result {
                if !result.problems.isEmpty {
                    let title = result.moved.isEmpty ? "Couldn’t move \(app.name) to Trash" : "Some files couldn’t be moved"
                    notice = RemovalNotice(title: title, message: result.problems.joined(separator: "\n\n"))
                }
                if !result.moved.isEmpty {
                    let count = result.moved.count - 1
                    status = switch count {
                    case 0: "Moved \(app.name) to Trash."
                    case 1: "Moved \(app.name) and 1 related item to Trash."
                    default: "Moved \(app.name) and \(count) related items to Trash."
                    }
                } else if result.wasCancelled {
                    status = "Removal canceled."
                }
            }
            refresh()
        }
    }

    func openVendorUninstaller(for row: AppRow) {
        guard let url = row.app.vendorUninstaller else { return }
        if !NSWorkspace.shared.open(url) {
            notice = RemovalNotice(title: "Couldn’t open the uninstaller", message: url.path)
        }
    }
}
