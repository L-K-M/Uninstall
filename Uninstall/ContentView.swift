import AppKit
import SwiftUI

func diskSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func diskSize(_ usage: DiskUsage) -> String {
    if usage.isComplete { return diskSize(usage.bytes) }
    return usage.bytes > 0 ? "≥ " + diskSize(usage.bytes) : "Unavailable"
}

func displayedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}

func relativeDate(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

/// Menu commands are declared on the app scene and bridged here via notifications.
enum AppCommand {
    static let scan = Notification.Name("Uninstall.scan")
    static let scanContainers = Notification.Name("Uninstall.scanContainers")
    static let focusSearch = Notification.Name("Uninstall.focusSearch")
    static let exportCSV = Notification.Name("Uninstall.exportCSV")
    static let removeSelected = Notification.Name("Uninstall.removeSelected")
}

private enum SortKey: String, CaseIterable {
    case size, lastOpened, name

    var label: String {
        switch self {
        case .size: "Size"
        case .lastOpened: "Last Opened"
        case .name: "Name"
        }
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var flow = RemovalFlow()
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\AppRow.totalSortValue, order: .reverse)]
    @State private var sortKey: SortKey = .size
    @State private var sortAscending = false
    @State private var checkedByApp: [String: Set<String>] = [:]
    @FocusState private var isSearchFocused: Bool

    init() {
        let key = UserDefaults.standard.string(forKey: "sortKey").flatMap(SortKey.init(rawValue:)) ?? .size
        let ascending = UserDefaults.standard.bool(forKey: "sortAscending")
        let order: SortOrder = ascending ? .forward : .reverse
        let comparators: [KeyPathComparator<AppRow>] = switch key {
        case .size: [KeyPathComparator(\.totalSortValue, order: order)]
        case .lastOpened: [KeyPathComparator(\.lastOpenedSortValue, order: order)]
        case .name: [KeyPathComparator(\.name, order: order)]
        }
        _sortKey = State(initialValue: key)
        _sortAscending = State(initialValue: ascending)
        _sortOrder = State(initialValue: comparators)
    }

    private var visibleRows: [AppRow] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.rows.filter {
            term.isEmpty || $0.name.localizedStandardContains(term)
                || $0.app.bundleIdentifier?.localizedStandardContains(term) == true
                || $0.app.url.path.localizedStandardContains(term)
        }
        .sorted(by: compare)
    }

    private var selectedRows: [AppRow] {
        model.rows.filter { selection.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var totalVisibleBytes: Int64 {
        visibleRows.reduce(0) { $0 + $1.totalSortValue }
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            VStack(spacing: 0) {
                appList
                Divider()
                statusBar
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 560)
        } detail: {
            Group {
                if let row = selectedRows.first, selectedRows.count == 1 {
                    DetailPane(row: row, model: model, checkedByApp: $checkedByApp,
                               busy: flow.busy || model.removingName != nil,
                               onRemoveOnly: { model.prepareRemoval(for: row, relatedIDs: []) },
                               onRemoveSelected: { model.prepareRemoval(for: row, relatedIDs: checked(of: row)) },
                               onQuitAndRemove: { flow.quitAndRemove(row, model: model, checked: checked(of: row)) })
                } else if !selectedRows.isEmpty {
                    multiSelectionSummary
                } else {
                    ContentUnavailableView("Select an App", systemImage: "macwindow",
                                           description: Text("Review its storage and choose what to remove."))
                }
            }
            .frame(minWidth: 320, idealWidth: 420, maxHeight: .infinity)
        }
        .frame(minWidth: 770, minHeight: 470)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Scan Again") { scan(includingContainers: false) }
                    Button("Scan Including App Containers") { scan(includingContainers: true) }
                    Divider()
                    Button("Export List as CSV…") { exportCSV() }
                } label: {
                    Label("Scan Apps", systemImage: "arrow.clockwise")
                }
                .help("Scan installed apps and related files")
                .disabled(model.removingName != nil || flow.busy)
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Picker("Sort", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .onChange(of: sortKey) { applySort() }
                    Button {
                        sortAscending.toggle()
                        applySort()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    }
                    .help(sortAscending ? "Sort ascending" : "Sort descending")
                    .onChange(of: sortAscending) { applySort() }
                }
            }

            ToolbarItem(placement: .automatic) {
                searchField
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.scan)) { _ in
            scan(includingContainers: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.scanContainers)) { _ in
            scan(includingContainers: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.focusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.exportCSV)) { _ in
            exportCSV()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppCommand.removeSelected)) { _ in
            if removableSelection { beginBatchRemoval() }
        }
        .task { model.start() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: RunLoop.main)) { _ in
            model.refreshRunningApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: RunLoop.main)) { _ in
            model.refreshRunningApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRunningApps()
        }
        .onChange(of: search) {
            selection = selection.intersection(Set(visibleRows.map(\.id)))
        }
        .onChange(of: model.rows.count) {
            let ids = Set(model.rows.map(\.id))
            checkedByApp = checkedByApp.filter { ids.contains($0.key) }
            selection = selection.intersection(ids)
        }
        .sheet(item: $model.pendingPlan) { plan in
            RemovalReviewSheet(plan: plan, cancel: { model.pendingPlan = nil },
                               confirm: { model.confirmRemoval(plan) })
        }
        .sheet(item: $flow.pendingBatch) { batch in
            BatchRemovalSheet(batch: batch, cancel: { flow.pendingBatch = nil },
                              confirm: { flow.confirmBatch(batch, model: model) })
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .alert(item: $flow.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel("Search apps")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.25)))
    }

    private var appList: some View {
        @Bindable var model = model
        let rows = visibleRows

        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { row in
                HStack(spacing: 8) {
                    CachedAppIcon(path: row.app.url.path, size: 26)
                    Text(row.name).lineLimit(1)
                    rowBadges(for: row)
                }
                .padding(.vertical, 2)
            }
            .width(min: 160, ideal: 245)

            TableColumn("Total Size", value: \.totalSortValue) { row in
                Group {
                    if let footprint = row.footprint {
                        Text(diskSize(DiskUsage(bytes: footprint.totalBytes, isComplete: footprint.isComplete)))
                    } else {
                        Text("—")
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .width(min: 92, ideal: 104, max: 130)

            TableColumn("Last Opened", value: \.lastOpenedSortValue) { row in
                if let date = row.lastOpened {
                    Text(relativeDate(date))
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("Unknown").foregroundStyle(.tertiary)
                }
            }
            .width(min: 100, ideal: 112, max: 140)
        }
        .contextMenu(forSelectionType: String.self) { items in
            let rows = model.rows.filter { items.contains($0.id) }
            if let row = rows.first {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(row.app.url.path, inFileViewerRootedAtPath: "")
                }
                Button("Copy Name") { copyToPasteboard(row.name) }
                Button("Copy Path") { copyToPasteboard(displayedPath(row.app.url)) }
                if row.app.vendorUninstaller != nil {
                    Button("Open Vendor Uninstaller") { model.openVendorUninstaller(for: row) }
                }
                Divider()
                Button("Remove Selected…") { beginBatchRemoval() }
                    .disabled(!removableSelection)
            }
        }
        .overlay {
            if rows.isEmpty {
                if model.isScanning && model.rows.isEmpty {
                    ProgressView("Finding installed apps…")
                } else if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView("No Apps Found", systemImage: "macwindow")
                }
            }
        }
    }

    private func rowBadges(for row: AppRow) -> some View {
        Group {
            if model.isRunning(row.app) {
                Circle().fill(.green).frame(width: 7, height: 7)
                    .help("Running")
            }
            if row.app.isProtected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Protected")
            }
            if row.hasOtherInstallations {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary).help("Duplicate copy installed")
            }
            if row.app.vendorUninstaller != nil {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary).help("Vendor uninstaller available")
            }
            if let date = row.lastOpened, date < Date().addingTimeInterval(-365 * 24 * 3600) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Not opened in over a year")
            }
        }
        .font(.caption2)
    }

    private var multiSelectionSummary: some View {
        let total = selectedRows.reduce(0) { $0 + $1.totalSortValue }
        return ContentUnavailableView {
            Label("\(selectedRows.count) Apps Selected", systemImage: "checkmark.circle")
        } description: {
            Text("About \(diskSize(total)) across the selection.")
        } actions: {
            Button("Remove Selected…") { beginBatchRemoval() }
                .buttonStyle(.borderedProminent)
                .disabled(!removableSelection)
        }
    }

    private var removableSelection: Bool {
        let rows = selectedRows
        return !rows.isEmpty && rows.allSatisfy { !$0.app.isProtected && !model.isRunning($0.app) }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let removing = model.removingName {
                ProgressView().controlSize(.small)
                Text("Moving \(removing) to Trash…")
            } else if flow.busy {
                ProgressView().controlSize(.small)
                Text("Moving selected apps to Trash…")
            } else if model.isScanning {
                if model.rows.isEmpty {
                    Text("Finding apps…")
                } else {
                    ProgressView(value: Double(model.completedScans), total: Double(model.rows.count))
                        .frame(width: 64)
                    Text("Measuring \(model.completedScans) of \(model.rows.count) apps…")
                }
            } else if let status = flow.status ?? model.status {
                Image(systemName: "checkmark.circle")
                    .accessibilityHidden(true)
                Text(status)
                if !flow.lastBatchRecords.isEmpty {
                    Button("Undo") { flow.undoLast(model: model) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Put the moved items back from the Trash")
                }
            } else {
                Text("\(visibleRows.count) \(visibleRows.count == 1 ? "app" : "apps") · \(diskSize(totalVisibleBytes))")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .accessibilityIdentifier("scanStatus")
    }

    private func checked(of row: AppRow) -> Set<String> {
        checkedFiles(for: row, in: checkedByApp)
    }

    private func beginBatchRemoval() {
        let rows = selectedRows
        guard let first = rows.first else { return }
        if rows.count == 1 {
            model.prepareRemoval(for: first, relatedIDs: checked(of: first))
        } else if let batch = flow.buildBatch(rows: rows, model: model, checked: checked(of:)) {
            flow.pendingBatch = batch
        }
    }

    private func scan(includingContainers: Bool) {
        checkedByApp = [:]
        selection = []
        model.refresh(includingContainers: includingContainers)
    }

    private func applySort() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        sortOrder = switch sortKey {
        case .size: [KeyPathComparator(\.totalSortValue, order: order)]
        case .lastOpened: [KeyPathComparator(\.lastOpenedSortValue, order: order)]
        case .name: [KeyPathComparator(\.name, order: order)]
        }
        UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey")
        UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Uninstall Apps.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        func field(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        var lines = ["Name,Bundle ID,Path,Total Size (bytes),Last Opened"]
        for row in visibleRows {
            lines.append([
                field(row.name),
                field(row.app.bundleIdentifier ?? ""),
                field(row.app.url.path),
                "\(row.totalSortValue)",
                row.lastOpened?.ISO8601Format() ?? "",
            ].joined(separator: ","))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func compare(_ left: AppRow, _ right: AppRow) -> Bool {
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
}
