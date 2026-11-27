import AppKit
import SwiftUI

/// Right-hand pane: app identity, a storage breakdown bar, related-file
/// review grouped by category, and the removal actions.
struct DetailPane: View {
    let row: AppRow
    @Bindable var model: AppModel
    @Binding var checkedByApp: [String: Set<String>]
    let busy: Bool
    let onRemoveOnly: () -> Void
    let onRemoveSelected: () -> Void
    let onQuitAndRemove: () -> Void

    private var info: [String: Any]? {
        Bundle(url: row.app.url)?.infoDictionary
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let footprint = row.footprint {
                        storage(for: footprint)
                        relatedFiles(for: row, footprint: footprint)
                    } else {
                        ProgressView("Measuring storage…").controlSize(.small)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            controls
                .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CachedAppIcon(path: row.app.url.path, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text(displayedPath(row.app.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            badges
            if let version = info?["CFBundleShortVersionString"] as? String,
               let identifier = row.app.bundleIdentifier {
                Text("Version \(version) · \(identifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let identifier = row.app.bundleIdentifier {
                Text(identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if model.isRunning(row.app) {
                Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
            }
            if row.app.isProtected {
                Label("Protected", systemImage: "lock.fill")
            }
            if row.hasOtherInstallations {
                Label("Duplicate copy", systemImage: "doc.on.doc")
            }
            if row.app.vendorUninstaller != nil {
                Label("Vendor uninstaller", systemImage: "arrow.up.right.square")
            }
            if let date = row.lastOpened, date < Date().addingTimeInterval(-365 * 24 * 3600) {
                Label("Not opened in over a year", systemImage: "clock.badge.exclamationmark")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func storage(for footprint: AppFootprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage").font(.headline)
                Spacer()
                Text(diskSize(DiskUsage(bytes: footprint.totalBytes, isComplete: footprint.isComplete)))
                    .font(.headline).monospacedDigit()
            }
            StorageBar(footprint: footprint)
            storageLegend(for: footprint)
            storageLine("App", value: diskSize(footprint.bundle))
            let relatedUsage = DiskUsage(bytes: footprint.relatedBytes,
                                         isComplete: footprint.relatedInventoryComplete
                                             && footprint.relatedItems.allSatisfy(\.usage.isComplete))
            storageLine("Related Files", value: diskSize(relatedUsage))
            if !footprint.isComplete {
                Label("Some files couldn’t be measured.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storageLegend(for footprint: AppFootprint) -> some View {
        let groups = Dictionary(grouping: footprint.relatedItems, by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.usage.bytes }) }
            .sorted { $0.1 > $1.1 }
        return HStack(spacing: 12) {
            legendDot("App", bytes: footprint.bundle.bytes, color: .accentColor)
            ForEach(groups, id: \.0) { category, bytes in
                legendDot(category.rawValue, bytes: bytes, color: StorageBar.color(for: category))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private func legendDot(_ label: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(diskSize(bytes))")
        }
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
                Menu {
                    Button("Select All") { setAll(for: row, true) }
                    Button("Select None") { setAll(for: row, false) }
                    Button("Restore Defaults") { checkedByApp[row.id] = nil }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(row.hasOtherInstallations || row.app.isProtected || busy)
            }
            if row.hasOtherInstallations {
                Text("Another installed copy uses the same bundle ID. Its related files are shared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if row.app.isProtected {
                Text("Storage covers the app bundle.").foregroundStyle(.secondary)
            } else if footprint.relatedItems.isEmpty {
                Text("No related files found.").foregroundStyle(.secondary)
            }
            RelatedFilesView(row: row, footprint: footprint, checkedByApp: $checkedByApp,
                             model: model, busy: busy)
        }
    }

    private func setAll(for row: AppRow, _ value: Bool) {
        let items = (row.footprint?.relatedItems ?? []).filter { $0.canRemove }
        checkedByApp[row.id] = value ? Set(items.map(\.id)) : []
    }

    private var controls: some View {
        let disabled = row.app.isProtected || busy
        let selected = checkedFiles(for: row, in: checkedByApp)
        let reclaimable = (row.footprint?.bundle.bytes ?? 0)
            + (row.footprint?.relatedItems ?? [])
                .filter { selected.contains($0.id) && $0.canRemove }
                .reduce(0) { $0 + $1.usage.bytes }

        return VStack(alignment: .leading, spacing: 8) {
            if row.app.isProtected {
                Label("This app is protected.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.isRunning(row.app) {
                Label("Quit this app before removing it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if row.app.vendorUninstaller != nil {
                    Button("Open Vendor Uninstaller") { model.openVendorUninstaller(for: row) }
                        .disabled(busy)
                }
                Spacer(minLength: 0)
                if model.isRunning(row.app) && !row.app.isProtected {
                    Button("Quit and Remove…") { onQuitAndRemove() }
                        .disabled(busy)
                }
                Menu {
                    Button("Remove App Only") { onRemoveOnly() }
                        .disabled(disabled)
                    Button("Remove App and Selected Files — \(diskSize(reclaimable))") { onRemoveSelected() }
                        .disabled(disabled || selected.isEmpty || row.hasOtherInstallations)
                } label: {
                    Label("Remove…", systemImage: "trash")
                }
                .fixedSize()
                .disabled(disabled)
            }
        }
    }
}

/// Related files grouped by category, each group with a master toggle.
struct RelatedFilesView: View {
    let row: AppRow
    let footprint: AppFootprint
    @Binding var checkedByApp: [String: Set<String>]
    @Bindable var model: AppModel
    let busy: Bool

    private let categoryOrder: [RelatedCategory] = [
        .support, .container, .webData, .scripts, .savedState, .preferences, .logs, .cache,
    ]

    private var groups: [(RelatedCategory, [RelatedItem])] {
        categoryOrder.compactMap { category in
            let items = footprint.relatedItems.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        ForEach(groups, id: \.0) { category, items in
            VStack(alignment: .leading, spacing: 4) {
                categoryHeader(category, items: items)
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func categoryHeader(_ category: RelatedCategory, items: [RelatedItem]) -> some View {
        let removable = items.filter(\.canRemove)
        let allChecked = !removable.isEmpty
            && removable.allSatisfy { checkedFiles(for: row, in: checkedByApp).contains($0.id) }
        let bytes = items.reduce(0) { $0 + $1.usage.bytes }

        return HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { allChecked },
                set: { checked in
                    var current = checkedFiles(for: row, in: checkedByApp)
                    for item in removable {
                        if checked { current.insert(item.id) } else { current.remove(item.id) }
                    }
                    checkedByApp[row.id] = current
                }
            )) {
                Label(category.rawValue, systemImage: Self.icon(for: category))
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.checkbox)
            .disabled(row.hasOtherInstallations || row.app.isProtected || busy)
            Spacer()
            Text(diskSize(bytes)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
        }
    }

    private func itemRow(_ item: RelatedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(item.category.rawValue, isOn: binding(for: item))
                    .toggleStyle(.checkbox)
                    .disabled(!item.canRemove || row.hasOtherInstallations || row.app.isProtected || busy)
                Spacer()
                Text(item.needsContainerScan ? "Scan needed" : diskSize(item.usage))
                    .monospacedDigit()
            }
            Text(displayedPath(item.url))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if item.needsContainerScan {
                Text("Choose Scan Including App Containers to measure this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let note = item.category.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for item: RelatedItem) -> Binding<Bool> {
        Binding {
            !row.hasOtherInstallations && !row.app.isProtected
                && checkedFiles(for: row, in: checkedByApp).contains(item.id)
        } set: { checked in
            var items = checkedFiles(for: row, in: checkedByApp)
            if checked {
                items.insert(item.id)
            } else {
                items.remove(item.id)
            }
            checkedByApp[row.id] = items
        }
    }

    private static func icon(for category: RelatedCategory) -> String {
        switch category {
        case .cache: "tray"
        case .logs: "doc.text"
        case .preferences: "gearshape"
        case .support: "folder"
        case .savedState: "clock.arrow.circlepath"
        case .webData: "globe"
        case .scripts: "scroll"
        case .container: "shippingbox"
        }
    }
}

/// Stacked bar showing the app bundle versus each related-file category.
struct StorageBar: View {
    let footprint: AppFootprint

    private static let categoryOrder: [RelatedCategory] = [
        .container, .support, .webData, .scripts, .savedState, .preferences, .logs, .cache,
    ]

    static func color(for category: RelatedCategory) -> Color {
        switch category {
        case .cache: .orange
        case .logs: .yellow
        case .preferences: .purple
        case .support: .blue
        case .savedState: .teal
        case .webData: .cyan
        case .scripts: .brown
        case .container: .pink
        }
    }

    private var segments: [(label: String, bytes: Int64, color: Color)] {
        var list = [("App", footprint.bundle.bytes, Color.accentColor)]
        let byCategory = Dictionary(grouping: footprint.relatedItems, by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.usage.bytes } }
        for category in Self.categoryOrder where (byCategory[category] ?? 0) > 0 {
            list.append((category.rawValue, byCategory[category]!, Self.color(for: category)))
        }
        return list
    }

    var body: some View {
        let total = max(footprint.totalBytes, 1)
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(geometry.size.width * CGFloat(segment.bytes) / CGFloat(total), 3))
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityLabel("Storage breakdown")
    }
}

/// Checked related-file ids for a row, defaulting to the safe defaults.
func checkedFiles(for row: AppRow, in checkedByApp: [String: Set<String>]) -> Set<String> {
    checkedByApp[row.id] ?? Set((row.footprint?.relatedItems ?? [])
        .filter { $0.canRemove && $0.category.selectedByDefault }.map(\.id))
}
