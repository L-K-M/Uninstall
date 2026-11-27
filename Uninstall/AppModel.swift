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
    var rows: [AppRow] = []
    private(set) var isScanning = false
    private(set) var completedScans = 0
    private(set) var removingName: String?
    private(set) var runningPaths: Set<String> = []
    private(set) var status: String?
    var selection: String?
    var pendingPlan: RemovalPlan?
    var notice: RemovalNotice?
    var sortOrder: [KeyPathComparator<AppRow>] = [KeyPathComparator(\AppRow.totalSortValue, order: .reverse)]

    @ObservationIgnored private let scanner = AppScanner.standard
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var includeContainers = false
    @ObservationIgnored private var observedLaunches = UserDefaults.standard.object(forKey: "observedLaunches") as? [String: Double] ?? [:]
    /// Row order captured when a scan starts, so new measurements cannot reshuffle rows under the pointer.
    @ObservationIgnored private var frozenOrder: [String]?

    var selectedRow: AppRow? { rows.first { $0.id == selection } }

    /// Rows in display order. While a scan is running the pre-scan order is kept, because landing
    /// size measurements would otherwise re-sort the table while the user is interacting with it.
    var orderedRows: [AppRow] {
        guard let frozen = frozenOrder else {
            return rows.sorted(by: compare)
        }
        if frozen.isEmpty { return rows }
        var rank = [String: Int]()
        for (index, id) in frozen.enumerated() { rank[id] = index }
        return rows.sorted { left, right in
            let leftRank = rank[left.id] ?? Int.max
            let rightRank = rank[right.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func beginScanOrdering() {
        frozenOrder = orderedRows.map(\.id)
    }

    func finishScanOrdering() {
        frozenOrder = nil
    }

    static func compare(_ left: AppRow, _ right: AppRow,
                        using sortOrder: [KeyPathComparator<AppRow>]) -> Bool {
        for comparator in sortOrder {
            if comparator.keyPath == \AppRow.lastOpenedSortValue,
               (left.lastOpened == nil) != (right.lastOpened == nil) {
                return left.lastOpened != nil
            }
            if comparator.keyPath == \AppRow.totalSortValue,
               (left.footprint == nil) != (right.footprint == nil) {
                return left.footprint != nil
            }
            let order = comparator.compare(left, right)
            if order != .orderedSame { return order == .orderedAscending }
        }
        let nameOrder = left.name.localizedStandardCompare(right.name)
        return nameOrder == .orderedSame ? left.id < right.id : nameOrder == .orderedAscending
    }

    private func compare(_ left: AppRow, _ right: AppRow) -> Bool {
        Self.compare(left, right, using: sortOrder)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()
    }

    func refresh(includingContainers: Bool? = nil) {
        guard removingName == nil, pendingPlan == nil else { return }
        if let includingContainers { includeContainers = includingContainers }
        scanTask?.cancel()
        finishScanOrdering()
        isScanning = true
        completedScans = 0
        beginScanOrdering()
        refreshRunningApps()
        let scanner = scanner
        let includeContainers = includeContainers
        let priorityIDs: Set<String> = selection.map { [$0] } ?? []

        scanTask = Task {
            let apps = await ScanCoordinator.discover(scanner)
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

            await ScanCoordinator.measure(scanner, apps: apps, includingContainers: includeContainers,
                                          priorityIDs: priorityIDs) { index, footprint in
                guard !Task.isCancelled, index < self.rows.count, self.rows[index].app.id == apps[index].id else { return }
                self.rows[index].footprint = footprint
                self.completedScans += 1
                }

            guard !Task.isCancelled else { return }
            completedScans = rows.count
            finishScanOrdering()
            isScanning = false
        }
    }

    func applySortOrder(_ order: [KeyPathComparator<AppRow>]) {
        sortOrder = order
        // An explicit sort request takes effect immediately, even during a scan.
        frozenOrder = nil
    }

    /// Removes rows that were moved to the Trash so a removal does not require a full rescan.
    func removeRows(withIDs ids: Set<String>) {
        rows.removeAll { ids.contains($0.id) }
        let counts = rows.reduce(into: [String: Int]()) { counts, row in
            if let identifier = row.app.bundleIdentifier {
                counts[identifier.lowercased(), default: 0] += 1
            }
        }
        for index in rows.indices {
            let identifier = rows[index].app.bundleIdentifier?.lowercased() ?? ""
            rows[index].hasOtherInstallations = counts[identifier, default: 0] > 1
        }
        if let selection, !rows.contains(where: { $0.id == selection }) {
            self.selection = nil
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
        finishScanOrdering()
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
                if result.moved.contains(app.url) {
                    removeRows(withIDs: [app.id])
                    refreshRunningApps()
                } else {
                    refresh()
                }
            }
        }
    }

    func openVendorUninstaller(for row: AppRow) {
        guard let url = row.app.vendorUninstaller else { return }
        if !NSWorkspace.shared.open(url) {
            notice = RemovalNotice(title: "Couldn’t open the uninstaller", message: url.path)
        }
    }
}

/// Runs discovery and measurement off the main actor so scanning cannot freeze the window.
enum ScanCoordinator {
    static let measurementLimit = 3

    static func discover(_ scanner: AppScanner) async -> [InstalledApp] {
        await Task.detached(priority: .userInitiated) { scanner.discover() }.value
    }

    static func measure(_ scanner: AppScanner,
                        apps: [InstalledApp],
                        includingContainers: Bool,
                        priorityIDs: Set<String>,
                        onComplete: @escaping @MainActor (Int, AppFootprint) -> Void) async {
        guard !apps.isEmpty else { return }
        await withTaskGroup(of: (Int, AppFootprint).self) { group in
            var order = apps.indices.filter { priorityIDs.contains(apps[$0].id) }
            order.append(contentsOf: apps.indices.filter { !priorityIDs.contains(apps[$0].id) })
            var remaining = order.makeIterator()

            for _ in 0..<min(measurementLimit, order.count) {
                if let index = remaining.next() {
                    group.addTask { (index, scanner.measure(apps[index], includingContainers: includingContainers)) }
                }
            }

            while let (index, footprint) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                await onComplete(index, footprint)
                if let next = remaining.next() {
                    group.addTask { (next, scanner.measure(apps[next], includingContainers: includingContainers)) }
                }
            }
        }
    }
}
