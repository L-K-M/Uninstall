import AppKit
import SwiftUI

private func diskSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func diskSize(_ usage: DiskUsage) -> String {
    if usage.isComplete { return usage.bytes > 0 ? diskSize(usage.bytes) : "None" }
    return usage.bytes > 0 ? "≥ " + diskSize(usage.bytes) : "Unavailable"
}

private func displayedPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRow.totalSortValue, order: .reverse)]
    @State private var checkedByApp: [String: Set<String>] = [:]
    @State private var uncheckedByApp: [String: Set<String>] = [:]

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
                    Text(date, format: .dateTime.year().month(.abbreviated).day())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown").foregroundStyle(.tertiary)
                }
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
                VStack(alignment: .leading, spacing: 20) {
                    identityHeader(for: row)
                    if let footprint = row.footprint {
                        storageCard(for: footprint)
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

    // MARK: Identity header

    private func identityHeader(for row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(url: row.app.url, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(displayedPath(row.app.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            let chips = statusChips(for: row)
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        StatusChip(chip: chip)
                    }
                }
            }
        }
    }

    private func statusChips(for row: AppRow) -> [AppStatusChip] {
        var chips: [AppStatusChip] = []
        if row.app.isProtected {
            chips.append(AppStatusChip(title: "Protected", systemImage: "lock",
                                       explanation: "Uninstall shows this app’s size but will not move it."))
        }
        if model.isRunning(row.app) {
            chips.append(AppStatusChip(title: "Running", systemImage: "play",
                                       explanation: "Quit this app before removing it."))
        }
        if row.hasOtherInstallations {
            chips.append(AppStatusChip(title: "Duplicate install", systemImage: "rectangle.2.onrectangle",
                                       explanation: "Another installed copy uses the same bundle ID, so related files are shared and cannot be removed."))
        }
        if row.app.vendorUninstaller != nil {
            chips.append(AppStatusChip(title: "Vendor uninstaller", systemImage: "wrench.and.screwdriver",
                                       explanation: "The vendor ships its own uninstaller next to the app. Click to open it.",
                                       action: { model.openVendorUninstaller(for: row) }))
        }
        return chips
    }

    // MARK: Storage

    private func storageCard(for footprint: AppFootprint) -> some View {
        let relatedUsage = DiskUsage(bytes: footprint.relatedBytes,
                                     isComplete: footprint.relatedInventoryComplete
                                         && footprint.relatedItems.allSatisfy(\.usage.isComplete))
        let total = footprint.totalBytes
        let appShare = total > 0 ? CGFloat(footprint.bundle.bytes) / CGFloat(total) : 0
        let relatedShare = total > 0 ? CGFloat(footprint.relatedBytes) / CGFloat(total) : 0
        let unmeasuredShare = max(0, 1 - appShare - relatedShare)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.headline)
                Spacer()
                Text(diskSize(DiskUsage(bytes: total, isComplete: footprint.isComplete)))
                    .font(.headline).monospacedDigit()
            }

            if total > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        segment(width: geometry.size.width * appShare, color: Color.accentColor)
                        segment(width: geometry.size.width * relatedShare, color: Color.accentColor.opacity(0.4))
                        segment(width: geometry.size.width * unmeasuredShare, color: .secondary.opacity(0.18))
                    }
                }
                .frame(height: 8)
                .accessibilityElement()
                .accessibilityLabel("Storage breakdown")
                .accessibilityValue(
                    "App \(diskSize(footprint.bundle)), related files \(diskSize(relatedUsage))"
                        + (unmeasuredShare > 0 ? ", unmeasured remainder" : ""))

                HStack(spacing: 14) {
                    legend(Color.accentColor, "App", diskSize(footprint.bundle))
                    legend(Color.accentColor.opacity(0.4), "Related Files", diskSize(relatedUsage))
                    if unmeasuredShare > 0 {
                        legend(.secondary.opacity(0.18), "Unmeasured", "")
                    }
                }
            }

            Text("Allocated space for the app bundle and the related files Uninstall can identify. "
                + "Files move to the Trash — empty it to reclaim the space.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !footprint.isComplete {
                Label("Some files couldn’t be measured, so the total is a lower bound.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: max(0, width - 1))
    }

    private func legend(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            if !value.isEmpty {
                Text(value).monospacedDigit()
            }
        }
        .font(.caption)
    }

    // MARK: Related files

    private func relatedFiles(for row: AppRow, footprint: AppFootprint) -> some View {
        let items = footprint.relatedItems
        let selectable = items.filter(\.canRemove)
        let selectionDisabled = row.hasOtherInstallations || row.app.isProtected || model.removingName != nil

        return VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Related Files").font(.headline)
                Spacer()
                if !selectable.isEmpty && !selectionDisabled {
                    Button("All") { selectAll(items, in: row) }
                        .buttonStyle(.borderless)
                    Button("None") { selectNone(items, in: row) }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)

            if row.hasOtherInstallations {
                Text("Another installed copy uses the same bundle ID, so its related files are shared. "
                    + "They are never selected.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if row.app.isProtected {
                Text("Storage covers the app bundle only.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("No related files found.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Caches and logs are selected by default; preferences, saved data and "
                    + "containers are not.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle(item.category.rawValue, isOn: binding(for: item, in: row))
                            .toggleStyle(.checkbox)
                            .disabled(!item.canRemove || selectionDisabled)
                        Spacer(minLength: 4)
                        Text(item.needsContainerScan ? "Scan needed" : diskSize(item.usage))
                            .monospacedDigit()
                        Button {
                            model.reveal(item.url)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        .disabled(model.removingName != nil)
                    }
                    Text(displayedPath(item.url))
                        .textSelection(.enabled)
                    if item.needsContainerScan {
                        Text("Choose Scan Including App Containers to measure this folder.")
                            .foregroundStyle(.secondary)
                    } else if let note = item.category.note {
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func selectAll(_ items: [RelatedItem], in row: AppRow) {
        var checked = checkedByApp[row.id] ?? []
        var unchecked = uncheckedByApp[row.id] ?? []
        for item in items where item.canRemove {
            checked.insert(item.id)
            unchecked.remove(item.id)
        }
        checkedByApp[row.id] = checked
        uncheckedByApp[row.id] = unchecked
    }

    private func selectNone(_ items: [RelatedItem], in row: AppRow) {
        var checked = checkedByApp[row.id] ?? []
        var unchecked = uncheckedByApp[row.id] ?? []
        for item in items {
            checked.remove(item.id)
            unchecked.insert(item.id)
        }
        checkedByApp[row.id] = checked
        uncheckedByApp[row.id] = unchecked
    }

    // MARK: Footer

    private func controls(for row: AppRow) -> some View {
        let blocked = row.app.isProtected || model.isRunning(row.app) || model.removingName != nil
        let sharedData = row.hasOtherInstallations
        let selected = checkedFiles(for: row)
        let removeFiles = !selected.isEmpty && !sharedData
        let primaryTitle = removeFiles ? "Review & Remove…" : "Remove App Only…"

        return VStack(alignment: .leading, spacing: 10) {
            if let chip = statusChips(for: row).first {
                Label(chip.title, systemImage: chip.systemImage)
                    .font(.caption).foregroundStyle(.secondary)
                Text(chip.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            } else if selected.isEmpty && !sharedData {
                Text("No related files selected — only the app bundle will move.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if sharedData {
                Text("Only the app bundle can move while another copy shares its data.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Selected to remove")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(selectedBytesLabel(for: row))
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
                Spacer(minLength: 8)

                Button {
                    model.reveal(row.app.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .disabled(model.removingName != nil)

                if removeFiles {
                    Button("App Only") { model.prepareRemoval(for: row, relatedIDs: []) }
                        .buttonStyle(.borderless)
                        .disabled(blocked)
                }

                Button(primaryTitle) {
                    model.prepareRemoval(for: row, relatedIDs: selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(blocked)
            }
        }
    }

    private func selectedBytesLabel(for row: AppRow) -> String {
        let ids = checkedFiles(for: row)
        let related = (row.footprint?.relatedItems ?? []).filter { ids.contains($0.id) }
            .reduce(0) { $0 + $1.usage.bytes }
        let bundle = row.footprint?.bundle.bytes ?? 0
        return diskSize(DiskUsage(bytes: bundle + related, isComplete: true))
    }

    /// The related items that should move with the app.
    ///
    /// An item is selected when the user checked it, or when the user has never decided
    /// and its category is selected by default. Items the user unchecked stay unchecked.
    private func checkedFiles(for row: AppRow) -> Set<String> {
        let items = row.footprint?.relatedItems ?? []
        let checked = checkedByApp[row.id] ?? []
        let unchecked = uncheckedByApp[row.id] ?? []
        return Set(items.filter { item in
            checked.contains(item.id)
                || (!unchecked.contains(item.id) && item.canRemove && item.category.selectedByDefault)
        }.map(\.id))
    }

    private func binding(for item: RelatedItem, in row: AppRow) -> Binding<Bool> {
        Binding {
            !row.hasOtherInstallations && !row.app.isProtected && checkedFiles(for: row).contains(item.id)
        } set: { checked in
            var checkedSet = checkedByApp[row.id] ?? []
            var uncheckedSet = uncheckedByApp[row.id] ?? []
            if checked {
                checkedSet.insert(item.id)
                uncheckedSet.remove(item.id)
            } else {
                checkedSet.remove(item.id)
                uncheckedSet.insert(item.id)
            }
            checkedByApp[row.id] = checkedSet
            uncheckedByApp[row.id] = uncheckedSet
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

private struct AppStatusChip: Identifiable {
    let title: String
    let systemImage: String
    let explanation: String
    var action: (() -> Void)?
    var id: String { title }
}

private struct StatusChip: View {
    let chip: AppStatusChip

    var body: some View {
        if let action = chip.action {
            Button(action: action) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        Label(chip.title, systemImage: chip.systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(chip.explanation)
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
            Text("Move \(plan.app.name) to Trash?").font(.title2.weight(.semibold))
            Text("The items below will move to the Trash.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    reviewedItem(plan.app.name, url: plan.app.url)
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
                Button("Move to Trash", role: .destructive, action: confirm)
            }
        }
        .padding(22)
        .frame(width: 490)
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
