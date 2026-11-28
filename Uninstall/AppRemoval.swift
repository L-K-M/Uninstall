import Foundation

struct RemovalPlan: Identifiable, Sendable {
    let id = UUID()
    let app: InstalledApp
    let relatedItems: [RelatedItem]
    /// The app bundle's measured size, so the confirmation can show a total.
    let bundleUsage: DiskUsage
}

/// One item that reached the Trash, and where it landed.
struct MovedItem: Sendable {
    let original: URL
    let trash: URL
}

struct RemovalResult: Sendable {
    let moved: [URL]
    let problems: [String]
    var wasCancelled = false
    /// Where each moved item ended up, so the receipt can point at the result
    /// rather than at a path that no longer exists.
    var trashed: [MovedItem] = []
}

enum AppRemoval {
    static func perform(
        _ plan: RemovalPlan,
        moveWithAuthorization: (InstalledApp) throws -> URL = AdministratorTrash.move,
        moveToTrash: (URL) throws -> URL = { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            return destination as URL? ?? url
        }
    ) -> RemovalResult {
        let app = plan.app
        guard !app.isProtected else {
            return RemovalResult(moved: [], problems: ["\(app.name) is protected."])
        }

        var items: [(url: URL, identity: FileIdentity)] = [(app.url, app.identity)]
        for file in plan.relatedItems {
            guard let identity = file.identity, file.canRemove else {
                return RemovalResult(moved: [], problems: ["\(file.url.path) could not be verified. Scan again before removing it."])
            }
            items.append((file.url, identity))
        }
        if let changed = items.first(where: { !isUnchanged($0.url, identity: $0.identity) }) {
            return RemovalResult(moved: [], problems: [changedMessage(changed.url)])
        }

        var moved: [URL] = []
        var problems: [String] = []
        var trashed: [MovedItem] = []
        for item in items {
            guard isUnchanged(item.url, identity: item.identity) else {
                problems.append(changedMessage(item.url))
                if moved.isEmpty { break }
                continue
            }

            do {
                do {
                    let destination = try moveToTrash(item.url)
                    trashed.append(MovedItem(original: item.url, trash: destination))
                } catch where item.url == app.url && isPermissionError(error) {
                    guard isUnchanged(item.url, identity: item.identity) else {
                        return RemovalResult(moved: [], problems: [changedMessage(item.url)])
                    }
                    let destination = try moveWithAuthorization(app)
                    trashed.append(MovedItem(original: item.url, trash: destination))
                }
                moved.append(item.url)
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.userCancelled.rawValue {
                    return RemovalResult(moved: moved, problems: problems, wasCancelled: true, trashed: trashed)
                }
                problems.append("\(item.url.path)\n\(error.localizedDescription)")
                if moved.isEmpty { break }
            }
        }

        return RemovalResult(moved: moved, problems: problems, trashed: trashed)
    }

    private static func isUnchanged(_ url: URL, identity: FileIdentity) -> Bool {
        AppScanner.isDirectPath(url) && AppScanner.fileIdentity(at: url) == identity
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == CocoaError.fileWriteNoPermission.rawValue
                || error.code == CocoaError.fileReadNoPermission.rawValue
        case NSPOSIXErrorDomain:
            return error.code == Int(EACCES) || error.code == Int(EPERM)
        default:
            return false
        }
    }

    private static func changedMessage(_ url: URL) -> String {
        "\(url.path) changed after the scan. Scan again before removing it."
    }
}
