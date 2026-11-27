import Foundation

struct RemovalPlan: Identifiable, Sendable {
    let id = UUID()
    let app: InstalledApp
    let relatedItems: [RelatedItem]
}

struct RemovalResult: Sendable {
    let moved: [URL]
    let problems: [String]
    var wasCancelled = false
}

enum AppRemoval {
    static func perform(
        _ plan: RemovalPlan,
        moveWithAuthorization: (InstalledApp) throws -> Void = AdministratorTrash.move,
        moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
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
        for item in items {
            guard isUnchanged(item.url, identity: item.identity) else {
                problems.append(changedMessage(item.url))
                if moved.isEmpty { break }
                continue
            }

            do {
                do {
                    try moveToTrash(item.url)
                } catch where item.url == app.url && isPermissionError(error) {
                    guard isUnchanged(item.url, identity: item.identity) else {
                        return RemovalResult(moved: [], problems: [changedMessage(item.url)])
                    }
                    try moveWithAuthorization(app)
                }
                moved.append(item.url)
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == CocoaError.userCancelled.rawValue {
                    return RemovalResult(moved: moved, problems: problems, wasCancelled: true)
                }
                problems.append("\(item.url.path)\n\(error.localizedDescription)")
                if moved.isEmpty { break }
            }
        }

        return RemovalResult(moved: moved, problems: problems)
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
