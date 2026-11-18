import ControlCore
import SwiftUI

@main
struct ContainerControlApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        if let dir = Snapshot.directory { Snapshot.run(model: model, to: dir) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.requests.isEmpty
                ? (model.runningCount > 0 ? "shippingbox.fill" : "shippingbox")
                : "hand.raised.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Container Control", id: MainWindow.id) {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 900, height: 600)
        .windowToolbarStyle(.unified)

        WindowGroup("Logs", id: LogsWindow.id, for: String.self) { $id in
            if let id {
                LogsWindow(projectId: id)
                    .environment(model)
            }
        }
        .defaultSize(width: 820, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Activity", id: ActivityWindow.id) {
            ActivityWindow()
                .environment(model)
        }
        .defaultSize(width: 560, height: 520)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
