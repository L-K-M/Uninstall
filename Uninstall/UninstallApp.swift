import SwiftUI

extension Notification.Name {
    static let focusAppSearch = Notification.Name("focusAppSearch")
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
                Button("Find App") {
                    NotificationCenter.default.post(name: .focusAppSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
