import AppKit
import SwiftUI

/// Caches workspace icons by app path so table rows never call
/// `NSWorkspace.icon(forFile:)` synchronously on the main thread.
actor AppIconCache {
    static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

struct CachedAppIcon: View {
    let path: String
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task {
            let path = path
            image = await Task.detached(priority: .utility) {
                await AppIconCache.shared.icon(for: path)
            }.value
        }
        .accessibilityHidden(true)
    }
}
