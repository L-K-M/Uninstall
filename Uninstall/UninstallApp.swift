import SwiftUI

@main
struct UninstallApp: App {
    var body: some Scene {
        Window("Uninstall", id: "uninstall") {
            ContentView()
        }
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)
    }
}
