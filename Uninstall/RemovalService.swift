import Foundation

/// One item that was moved to the Trash, with where it landed.
struct MovedItem: Sendable {
    let original: URL
    let trash: URL?
}

/// A persisted record of a moved item, used for Undo and the removal history.
struct RemovalRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let appName: String
    let originalPath: String
    let trashPath: String
    let bytes: Int64
    let date: Date
}

enum RemovalHistory {
    static let recordsKey = "removalHistoryRecords"
    static let reclaimedKey = "reclaimedBytesTotal"
    private static let maxRecords = 100

    static var reclaimedTotal: Int64 {
        UserDefaults.standard.object(forKey: reclaimedKey) as? Int64 ?? 0
    }

    static func records() -> [RemovalRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([RemovalRecord].self, from: data)
        else { return [] }
        return records
    }

    static func append(_ record: RemovalRecord) {
        var records = records()
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
        UserDefaults.standard.set(reclaimedTotal + record.bytes, forKey: reclaimedKey)
    }

    /// Moves a trashed item back to its original location when that path is free.
    /// Verifies the Trash path is not a symlink escape before renaming.
    @discardableResult
    static func putBack(_ record: RemovalRecord) -> Bool {
        guard !record.trashPath.isEmpty else { return false }
        let trash = URL(fileURLWithPath: record.trashPath)
        let original = URL(fileURLWithPath: record.originalPath)
        guard AppScanner.isDirectPath(trash),
              FileManager.default.fileExists(atPath: trash.path),
              !FileManager.default.fileExists(atPath: original.path)
        else { return false }
        do {
            try FileManager.default.moveItem(at: trash, to: original)
            return true
        } catch {
            return false
        }
    }
}

/// Destructive removal operations for one or many apps. Kept out of SwiftUI so
/// the behavior is unit-testable; views only collect intent and present state.
enum RemovalService {
    /// Moves every plan's items to the Trash sequentially. Each plan still goes
    /// through `AppRemoval.perform`, so identity re-verification, the privileged
    /// path and cancellation semantics are unchanged. Where each item landed in
    /// the Trash is captured so it can be put back later.
    static func performBatch(
        _ plans: [RemovalPlan],
        moveWithAuthorization: (InstalledApp) throws -> Void = AdministratorTrash.move,
        moveToTrash: (URL) throws -> URL? = { url in
            var trash: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trash)
            return trash as URL?
        }
    ) -> (moved: [MovedItem], problems: [String]) {
        var moved: [MovedItem] = []
        var problems: [String] = []
        for plan in plans {
            var trashByOriginal: [URL: URL] = [:]
            let result = AppRemoval.perform(plan, moveWithAuthorization: moveWithAuthorization) { url in
                if let trash = try moveToTrash(url) {
                    trashByOriginal[url] = trash
                }
            }
            for url in result.moved {
                moved.append(MovedItem(original: url, trash: trashByOriginal[url]))
            }
            problems.append(contentsOf: result.problems)
        }
        return (moved, problems)
    }
}
