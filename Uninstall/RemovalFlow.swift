import AppKit
import Observation
import SwiftUI

/// One app in a multi-app removal, with the related files selected for it.
struct BatchEntry: Identifiable, Sendable {
    let id: String
    let app: InstalledApp
    let related: [RelatedItem]
    let bytes: Int64

    var name: String { app.name }
}

struct RemovalBatch: Identifiable {
    let id = UUID()
    let entries: [BatchEntry]

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}

/// Owns the multi-app removal flow: building a batch from the selection,
/// running it through `RemovalService`, and undoing the last batch.
@MainActor @Observable
final class RemovalFlow {
    var pendingBatch: RemovalBatch?
    var busy = false
    var status: String?
    var lastBatchRecords: [RemovalRecord] = []
    var notice: RemovalNotice?

    func buildBatch(rows: [AppRow], model: AppModel, checked: (AppRow) -> Set<String>) -> RemovalBatch? {
        let entries = rows.compactMap { row -> BatchEntry? in
            guard !row.app.isProtected, !model.isRunning(row.app) else { return nil }
            let related: [RelatedItem]
            if row.hasOtherInstallations {
                related = []
            } else {
                let selected = checked(row)
                related = (row.footprint?.relatedItems ?? [])
                    .filter { selected.contains($0.id) && $0.canRemove }
            }
            return BatchEntry(id: row.id, app: row.app, related: related,
                              bytes: row.footprint?.totalBytes ?? 0)
        }
        guard !entries.isEmpty else { return nil }
        return RemovalBatch(entries: entries)
    }

    func confirmBatch(_ batch: RemovalBatch, model: AppModel) {
        pendingBatch = nil
        busy = true
        status = nil
        let plans = batch.entries.map { RemovalPlan(app: $0.app, relatedItems: $0.related) }

        Task {
            let result = RemovalService.performBatch(plans)
            var records: [RemovalRecord] = []
            for entry in batch.entries {
                for item in result.moved where item.original == entry.app.url || entry.related.contains(where: { $0.url == item.original }) {
                    guard let trash = item.trash else { continue }
                    let isApp = item.original == entry.app.url
                    let record = RemovalRecord(appName: entry.app.name,
                                               originalPath: item.original.path,
                                               trashPath: trash.path,
                                               bytes: isApp ? entry.bytes : 0,
                                               date: Date())
                    RemovalHistory.append(record)
                    records.append(record)
                }
            }
            lastBatchRecords = records

            if !result.problems.isEmpty {
                let title = result.moved.isEmpty
                    ? "Couldn’t move the selected apps to Trash"
                    : "Some files couldn’t be moved"
                notice = RemovalNotice(title: title, message: result.problems.joined(separator: "\n\n"))
            }
            let movedApps = batch.entries.filter { entry in
                result.moved.contains { $0.original == entry.app.url }
            }.count
            if movedApps > 0 {
                status = "Moved \(movedApps) \(movedApps == 1 ? "app" : "apps") to Trash."
            }
            busy = false
            model.refresh()
        }
    }

    /// Puts the last batch's items back from the Trash where possible.
    func undoLast(model: AppModel) {
        var restored = 0
        for record in lastBatchRecords where RemovalHistory.putBack(record) {
            restored += 1
        }
        lastBatchRecords = []
        status = restored > 0
            ? "Put back \(restored) \(restored == 1 ? "item" : "items") from the Trash."
            : "Couldn’t put items back — the original paths may no longer be free."
        model.refresh()
    }

    /// Terminates a running app, waits briefly for it to exit, then opens the
    /// standard removal review for it.
    func quitAndRemove(_ row: AppRow, model: AppModel, checked: Set<String>) {
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            if app.bundleURL?.resolvingSymlinksInPath().path == row.app.id
                || (row.app.bundleIdentifier != nil && app.bundleIdentifier == row.app.bundleIdentifier) {
                return app.processIdentifier
            }
            return nil
        })
        guard !pids.isEmpty else {
            model.prepareRemoval(for: row, relatedIDs: checked)
            return
        }
        for app in NSWorkspace.shared.runningApplications where pids.contains(app.processIdentifier) {
            app.terminate()
        }
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let stillRunning = NSWorkspace.shared.runningApplications.contains { pids.contains($0.processIdentifier) }
                if !stillRunning { break }
            }
            model.refreshRunningApps()
            if model.isRunning(row.app) {
                notice = RemovalNotice(title: "Quit \(row.app.name) first",
                                       message: "The app did not quit in time.")
            } else {
                model.prepareRemoval(for: row, relatedIDs: checked)
            }
        }
    }
}

struct BatchRemovalSheet: View {
    let batch: RemovalBatch
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(batch.entries.count) apps to Trash?")
                .font(.title2.weight(.semibold))
            Text("About \(diskSize(batch.totalBytes)) across \(batch.entries.count) apps. Everything below moves to the Trash and can be restored from there.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batch.entries) { entry in
                        HStack(spacing: 10) {
                            CachedAppIcon(path: entry.app.url.path, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).fontWeight(.medium).lineLimit(1)
                                Text("\(entry.related.count) related \(entry.related.count == 1 ? "file" : "files") · \(diskSize(entry.bytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 58, idealHeight: min(240, CGFloat(batch.entries.count) * 46), maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: confirm)
            }
        }
        .padding(22)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Restyled confirmation sheet for removing a single app.
struct RemovalReviewSheet: View {
    let plan: RemovalPlan
    let cancel: () -> Void
    let confirm: () -> Void

    private var totalBytes: Int64 {
        plan.relatedItems.reduce(0) { $0 + $1.usage.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CachedAppIcon(path: plan.app.url.path, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(plan.app.name) to Trash?").font(.title2.weight(.semibold))
                    Text("About \(diskSize(totalBytes)) of related files selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
