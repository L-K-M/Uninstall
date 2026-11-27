import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "trash.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.accentColor)
            }
            Text("Uninstall")
                .font(.title.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if RemovalHistory.reclaimedTotal > 0 {
                Text("Moved to Trash with Uninstall: \(diskSize(RemovalHistory.reclaimedTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Files are always moved to the Trash, never deleted directly, and can be restored from there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 400)
    }
}
