import SwiftUI

extension Notification.Name {
    /// Focuses the search field, as ⌘F does in every other Mac app.
    static let uninstallFocusSearch = Notification.Name("UninstallFocusSearch")

    /// Rescans the application directories.
    static let uninstallScanAgain = Notification.Name("UninstallScanAgain")

    /// Rescans including app containers.
    static let uninstallScanIncludingContainers = Notification.Name("UninstallScanIncludingContainers")
}

@main
struct UninstallApp: App {
    var body: some Scene {
        Window("Uninstall", id: "uninstall") {
            ContentView()
        }
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .uninstallFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Scan Again") {
                    NotificationCenter.default.post(name: .uninstallScanAgain, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Scan Including App Containers") {
                    NotificationCenter.default.post(name: .uninstallScanIncludingContainers, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }
}
