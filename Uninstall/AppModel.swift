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

    func showTrash() {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false) else {
            notice = RemovalNotice(title: "Couldn’t open the Trash",
                                   message: "The Trash location could not be found.")
            return
        }
        if !NSWorkspace.shared.open(trash) {
            notice = RemovalNotice(title: "Couldn’t open the Trash",
                                   message: "Finder could not open \(trash.path).")
        }
    }
}
