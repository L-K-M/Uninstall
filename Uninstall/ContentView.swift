import AppKit
import SwiftUI

private func diskSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func diskSize(_ usage: DiskUsage) -> String {
    if usage.isComplete { return diskSize(usage.bytes) }
    return usage.bytes > 0 ? "≥ " + diskSize(usage.bytes) : "Unavailable"
}

private func displayedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func categoryColor(_ category: String) -> Color {
    switch category {
    case "App": return .accentColor
    case RelatedCategory.cache.rawValue: return .orange
    case RelatedCategory.logs.rawValue: return .gray
    case RelatedCategory.preferences.rawValue: return .blue
    case RelatedCategory.support.rawValue: return .purple
    case RelatedCategory.savedState.rawValue: return .teal
    case RelatedCategory.webData.rawValue: return .indigo
    case RelatedCategory.scripts.rawValue: return .brown
    case RelatedCategory.container.rawValue: return .pink
    default: return .secondary
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRow.totalSortValue, order: .reverse)]
    @State private var checkedByApp: [String: Set<String>] = [:]

    private var visibleRows: [AppRow] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.rows.filter {
            term.isEmpty || $0.name.localizedStandardContains(term)
                || $0.app.bundleIdentifier?.localizedStandardContains(term) == true
        }
        .sorted(by: compare)
    }

    var body: some View {
        @Bindable var model = model

        HSplitView {
            VStack(spacing: 0) {
                appList
                Divider()
                statusBar
            }
            .frame(minWidth: 440, idealWidth: 550)

            Group {
                if let row = model.selectedRow {
                    details(for: row)
                } else {
                    ContentUnavailableView("Select an App", systemImage: "macwindow",
                                           description: Text("Review its storage and choose what to remove."))
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxHeight: .infinity)
        }
        .frame(minWidth: 770, minHeight: 470)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Scan Again") { scan(includingContainers: false) }
                    Button("Scan Including App Containers") { scan(includingContainers: true) }
                } label: {
                    Label("Scan Apps", systemImage: "arrow.clockwise")
                }
                .help("Scan installed apps and related files")
                .disabled(model.removingName != nil)
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Largest First") { sortOrder = [KeyPathComparator(\AppRow.totalSortValue, order: .reverse)] }
                    Button("Smallest First") { sortOrder = [KeyPathComparator(\AppRow.totalSortValue)] }
                    Button("Recently Opened") { sortOrder = [KeyPathComparator(\AppRow.lastOpenedSortValue, order: .reverse)] }
                    Button("Least Recently Opened") { sortOrder = [KeyPathComparator(\AppRow.lastOpenedSortValue)] }
                    Button("Name") { sortOrder = [KeyPathComparator(\AppRow.name)] }
                } label: {
                    Label("Sort Apps", systemImage: "arrow.up.arrow.down")
                }
            }

            ToolbarItem(placement: .automatic) {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityLabel("Search apps")
            }
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
            if !visibleRows.contains(where: { $0.id == model.selection }) {
                model.selection = nil
            }
        }
        .sheet(item: $model.pendingPlan) { plan in
            RemovalReview(plan: plan, cancel: { model.pendingPlan = nil },
                          confirm: { model.confirmRemoval(plan) })
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var appList: some View {
        @Bindable var model = model
        let rows = visibleRows

        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { row in
                HStack(spacing: 8) {
                    AppIcon(url: row.app.url, size: 24)
                    Text(row.name).lineLimit(1)
                    if model.isRunning(row.app) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("\(row.name) is running")
                    }
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
                Text(row.lastOpened.map(relativeDate) ?? "Unknown")
                    .foregroundStyle(row.lastOpened == nil ? .tertiary : .secondary)
            }
            .width(min: 100, ideal: 112, max: 140)
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let removing = model.removingName {
                ProgressView().controlSize(.small)
                Text("Moving \(removing) to Trash…")
            } else if model.isScanning {
                if model.rows.isEmpty {
                    Text("Finding apps…")
                } else {
                    ProgressView(value: Double(model.completedScans), total: Double(model.rows.count))
                        .frame(width: 64)
                    Text("Measuring \(model.completedScans) of \(model.rows.count) apps…")
                }
            } else if let status = model.status {
                Image(systemName: "checkmark.circle")
                    .accessibilityHidden(true)
                Text(status)
            } else {
                Text("\(visibleRows.count) \(visibleRows.count == 1 ? "app" : "apps")")
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

    private func details(for row: AppRow) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 12) {
                        AppIcon(url: row.app.url, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(row.name).font(.title2.weight(.semibold)).lineLimit(1)
                                if model.isRunning(row.app) {
                                    statusBadge("Running", systemImage: "play.circle", color: .green)
                                }
                                if row.hasOtherInstallations {
                                    statusBadge("Duplicate", systemImage: "doc.on.doc", color: .orange)
                                }
                                if row.app.isProtected {
                                    statusBadge("Protected", systemImage: "lock", color: .secondary)
                                }
                            }
                            if let version = row.app.version {
                                Text("Version \(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(displayedPath(row.app.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let footprint = row.footprint {
                        storage(for: footprint, row: row)
                        relatedFiles(for: row, footprint: footprint)
                    } else {
                        ProgressView("Measuring storage…").controlSize(.small)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            controls(for: row)
                .padding(14)
        }
    }

    private func statusBadge(_ label: String, systemImage: String, color: Color) -> some View {
        Label(label, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func storage(for footprint: AppFootprint, row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Storage").font(.headline)
                Spacer()
                Text(diskSize(DiskUsage(bytes: footprint.totalBytes, isComplete: footprint.isComplete)))
                    .font(.headline).monospacedDigit()
            }
            storageBar(for: footprint)
            storageLine("App", value: diskSize(footprint.bundle))
            let relatedUsage = DiskUsage(bytes: footprint.relatedBytes,
                                         isComplete: footprint.relatedInventoryComplete
                                             && footprint.relatedItems.allSatisfy(\.usage.isComplete))
            storageLine("Related Files", value: diskSize(relatedUsage))
            let selectedBytes = model.selectedBytes(for: row, relatedIDs: checkedFiles(for: row))
            if selectedBytes > 0 && selectedBytes != footprint.totalBytes {
                storageLine("Selected for Removal", value: diskSize(selectedBytes))
                    .foregroundStyle(.primary)
            }
            if !footprint.isComplete {
                Label("Some files couldn’t be measured.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Allocated space estimate. Empty the Trash to reclaim it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func storageBar(for footprint: AppFootprint) -> some View {
        let segments = AppModel.storageSegments(for: footprint)
        let total = segments.reduce(Int64(0)) { $0 + $1.bytes }
        if total > 0 {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(categoryColor(segment.category))
                            .frame(width: max(3, geo.size.width * (Double(segment.bytes) / Double(total))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(storageBreakdownLabel(for: segments))
        }
    }

    private func storageBreakdownLabel(for segments: [StorageSegment]) -> String {
        let parts = segments.map { "\($0.category) \(diskSize($0.bytes))" }
        return "Storage breakdown: " + parts.joined(separator: ", ")
    }

    private func storageLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func relatedFiles(for row: AppRow, footprint: AppFootprint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Related Files").font(.headline)
                Spacer()
                let removable = removableItems(for: row)
                if !removable.isEmpty && !row.hasOtherInstallations && !row.app.isProtected {
                    Button("Select None") { checkedByApp[row.id] = [] }
                        .disabled(model.removingName != nil)
                    Button("Select All") { checkedByApp[row.id] = Set(removable.map(\.id)) }
                        .disabled(model.removingName != nil)
                }
            }
            .font(.caption)
            if row.hasOtherInstallations {
                Text("Another installed copy uses the same bundle ID. Its related files are shared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if row.app.isProtected {
                Text("Storage covers the app bundle.").foregroundStyle(.secondary)
            } else if footprint.relatedItems.isEmpty {
                Text("No related files found.").foregroundStyle(.secondary)
            } else if !row.hasOtherInstallations {
                let removable = removableItems(for: row)
                Text("\(removable.count) removable · \(diskSize(removable.reduce(Int64(0)) { $0 + $1.usage.bytes }))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(footprint.relatedItems.sorted { $0.usage.bytes > $1.usage.bytes }) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(itemLabel(item), isOn: binding(for: item, in: row))
                            .toggleStyle(.checkbox)
                            .disabled(!item.canRemove || row.hasOtherInstallations || row.app.isProtected
                                      || model.removingName != nil)
                        Spacer()
                        Text(item.needsContainerScan ? "Scan needed" : diskSize(item.usage))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(displayedPath(item.url))
                        .textSelection(.enabled)
                    if item.needsContainerScan {
                        Text("Choose Scan Including App Containers to measure this folder.")
                            .foregroundStyle(.secondary)
                    } else if let note = item.category.note {
                        Text(note)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func itemLabel(_ item: RelatedItem) -> String {
        let size = item.needsContainerScan ? "Scan needed" : diskSize(item.usage)
        return "\(item.category.rawValue) · \(size)"
    }

    private func removableItems(for row: AppRow) -> [RelatedItem] {
        guard let footprint = row.footprint else { return [] }
        return footprint.relatedItems.filter(\.canRemove)
    }

    private func controls(for row: AppRow) -> some View {
        let disabled = row.app.isProtected || model.isRunning(row.app) || model.removingName != nil
        let selected = checkedFiles(for: row)

        return VStack(alignment: .leading, spacing: 8) {
            if row.app.isProtected {
                Label("This app is protected.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.isRunning(row.app) {
                Label("Quit this app before removing it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(row.app.url.path, inFileViewerRootedAtPath: "")
                }
                .disabled(model.removingName != nil)
                if row.app.vendorUninstaller != nil {
                    Button("Open Vendor Uninstaller") { model.openVendorUninstaller(for: row) }
                        .disabled(model.removingName != nil)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Remove App Only") { model.prepareRemoval(for: row, relatedIDs: []) }
                        .disabled(disabled)
                    Button("Remove App and Selected Files") { model.prepareRemoval(for: row, relatedIDs: selected) }
                        .disabled(disabled || selected.isEmpty || row.hasOtherInstallations)
                } label: {
                    Label(removeLabel(selectedCount: selected.count), systemImage: "trash")
                }
                .fixedSize()
                .disabled(disabled)
            }
        }
    }

    private func removeLabel(selectedCount: Int) -> String {
        guard selectedCount > 0 else { return "Remove…" }
        return "Remove App + \(selectedCount) File\(selectedCount == 1 ? "" : "s")…"
    }

    private func checkedFiles(for row: AppRow) -> Set<String> {
        checkedByApp[row.id] ?? Set((row.footprint?.relatedItems ?? [])
            .filter { $0.canRemove && $0.category.selectedByDefault }.map(\.id))
    }

    private func binding(for item: RelatedItem, in row: AppRow) -> Binding<Bool> {
        Binding {
            !row.hasOtherInstallations && !row.app.isProtected && checkedFiles(for: row).contains(item.id)
        } set: { checked in
            var items = checkedFiles(for: row)
            if checked {
                items.insert(item.id)
            } else {
                items.remove(item.id)
            }
            checkedByApp[row.id] = items
        }
    }

    private func scan(includingContainers: Bool) {
        checkedByApp = [:]
        model.refresh(includingContainers: includingContainers)
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

private struct AppIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct RemovalReview: View {
    let plan: RemovalPlan
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AppIcon(url: plan.app.url, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(plan.app.name) to Trash?")
                        .font(.title2.weight(.semibold)).lineLimit(1)
                    Text("\(plan.relatedItems.count + 1) items · about \(diskSize(plan.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("These items move to the Trash, not deleted. Empty the Trash to reclaim the space.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    reviewedItem(plan.app.name, url: plan.app.url)
                    if plan.appBytes > 0 {
                        Text(diskSize(plan.appBytes))
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    ForEach(plan.relatedItems) { item in
                        reviewedItem(item.category.rawValue, url: item.url)
                        if let note = item.category.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 58, idealHeight: min(220, CGFloat(plan.relatedItems.count + 1) * 52),
                   maxHeight: 240)

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(plan.relatedItems.isEmpty ? "Move App to Trash" : "Move \(plan.relatedItems.count + 1) Items to Trash",
                       role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func reviewedItem(_ name: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).fontWeight(.medium)
            Text(displayedPath(url))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
