import SwiftUI

@main
struct SteamClipConverterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Recordings Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
