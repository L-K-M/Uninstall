import SwiftUI

@main
struct UninstallApp: App {
    @State private var showAbout = false

    var body: some Scene {
        Window("Uninstall", id: "uninstall") {
            ContentView()
                .sheet(isPresented: $showAbout) {
                    AboutView()
                }
        }
        .defaultSize(width: 1040, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Uninstall") { showAbout = true }
            }
            CommandGroup(after: .toolbar) {
                Button("Scan Again") {
                    NotificationCenter.default.post(name: AppCommand.scan, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Scan Including App Containers") {
                    NotificationCenter.default.post(name: AppCommand.scanContainers, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Focus Search") {
                    NotificationCenter.default.post(name: AppCommand.focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Export List as CSV…") {
                    NotificationCenter.default.post(name: AppCommand.exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                Divider()
                Button("Remove Selected…") {
                    NotificationCenter.default.post(name: AppCommand.removeSelected, object: nil)
                }
                .keyboardShortcut(.delete)
            }
        }
    }
}
