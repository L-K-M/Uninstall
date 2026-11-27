import SwiftUI

extension Notification.Name {
    static let focusSearch = Notification.Name("UninstallFocusSearch")
    static let scanAgain = Notification.Name("UninstallScanAgain")
    static let scanIncludingContainers = Notification.Name("UninstallScanIncludingContainers")
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
            CommandMenu("Uninstall") {
                Button("Scan Again") {
                    NotificationCenter.default.post(name: .scanAgain, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Scan Including App Containers") {
                    NotificationCenter.default.post(name: .scanIncludingContainers, object: nil)
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
                Button("Find Apps") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
