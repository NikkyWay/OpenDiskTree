import SwiftUI

@main
struct OpenDiskTreeApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .frame(minWidth: 1_080, minHeight: 700)
    }
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(after: .newItem) {
        Button(String(localized: "scan.folder")) { model.chooseFolder() }.keyboardShortcut("o")
        Button(String(localized: "action.reveal")) {
          if let item = model.selectedItem { model.reveal(item) }
        }.keyboardShortcut("r")
      }
    }

    Settings {
      SettingsView(model: model)
        .frame(width: 500, height: 300)
    }
  }
}
