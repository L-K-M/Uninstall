import AppKit
import Observation

struct AppRow: Identifiable {
    var id: String { app.id }
    var name: String { app.name }
    var lastOpened: Date? {
        guard let observedLaunch else { return app.lastOpened }
        return max(observedLaunch, app.lastOpened ?? .distantPast)
    }
    var lastOpenedSortValue: Date { lastOpened ?? .distantPast }
    var totalSortValue: Int64 { footprint?.totalBytes ?? 0 }

    let app: InstalledApp
    var observedLaunch: Date?
    var footprint: AppFootprint?
    var hasOtherInstallations = false
}

struct RemovalNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// What the last removal actually did, so the app can close the loop.
struct RemovalReceipt: Identifiable {
    let id = UUID()
    let appName: String
    /// The app's icon, captured before the move: the bundle is gone afterwards.
    let icon: NSImage
    /// Where the app bundle landed in the Trash, if the move reported it.
    let trashURL: URL?
    let relatedCount: Int
    let problems: [String]

    var itemCount: Int { relatedCount + 1 }

    var summary: String {
        switch relatedCount {
        case 0: "Moved \(appName) to the Trash."
        case 1: "Moved \(appName) and 1 related item to the Trash."
        default: "Moved \(appName) and \(relatedCount) related items to the Trash."
        }
    }
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
    var receipt: RemovalReceipt?

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

    /// Drops the last removal's receipt. Called when the user starts something new;
    /// a refresh triggered *by* a removal must keep it, or the receipt would be wiped
    /// the instant it appeared.
    func clearReceipt() {
        receipt = nil
    }

    func refresh(includingContainers: Bool? = nil) {
        guard removingName == nil, pendingPlan == nil else { return }
        if let includingContainers { includeContainers = includingContainers }
        scanTask?.cancel()
        isScanning = true
        completedScans = 0
        refreshRunningApps()
        let scanner = scanner
        let includeContainers = includeContainers

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

            await withTaskGroup(of: (Int, AppFootprint).self) { group in
                var remaining = apps.enumerated().makeIterator()
                for _ in 0..<min(3, apps.count) {
                    if let (index, app) = remaining.next() {
                        group.addTask { (index, scanner.measure(app, includingContainers: includeContainers)) }
                    }
                }

                for await (index, footprint) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    rows[index].footprint = footprint
                    completedScans += 1
                    if let (index, app) = remaining.next() {
                        group.addTask { (index, scanner.measure(app, includingContainers: includeContainers)) }
                    }
                }
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
        for index in rows.indices {
            let date = observedLaunch(for: rows[index].app)
            if rows[index].observedLaunch != date {
                rows[index].observedLaunch = date
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
        receipt = nil
        let related = row.hasOtherInstallations ? [] : (row.footprint?.relatedItems ?? []).filter {
            relatedIDs.contains($0.id) && $0.canRemove
        }
        pendingPlan = RemovalPlan(app: row.app, relatedItems: related,
                                bundleUsage: row.footprint?.bundle ?? .unavailable)
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
                let movedRelated = max(0, result.moved.count - 1)
                if !result.problems.isEmpty {
                    let title = result.moved.isEmpty ? "Couldn’t move \(app.name) to Trash" : "Some files couldn’t be moved"
                    notice = RemovalNotice(title: title, message: result.problems.joined(separator: "\n\n"))
                }
                if !result.moved.isEmpty {
                    status = nil
                    receipt = RemovalReceipt(appName: app.name,
                                              icon: NSWorkspace.shared.icon(forFile: app.url.path),
                                              trashURL: result.trashed.first { $0.original == app.url }?.trash,
                                              relatedCount: movedRelated, problems: result.problems)
                } else if result.wasCancelled {
                    status = "Removal canceled."
                }
            }
            refresh()
        }
    }

    /// Reveals a file in Finder without opening it.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the user's Trash so they can see what was moved and restore it.
    func openTrash() {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
        else {
            notice = RemovalNotice(title: "Couldn’t open the Trash",
                                   message: "Open the Trash in the Dock instead.")
            return
        }
        if !NSWorkspace.shared.open(trash) {
            notice = RemovalNotice(title: "Couldn’t open the Trash", message: trash.path)
        }
    }

    func openVendorUninstaller(for row: AppRow) {
        guard let url = row.app.vendorUninstaller else { return }
        if !NSWorkspace.shared.open(url) {
            notice = RemovalNotice(title: "Couldn’t open the uninstaller", message: url.path)
        }
    }
}
