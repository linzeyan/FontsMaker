import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct FontsMakerApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let app = AppModel()
        _app = State(initialValue: app)
        #if os(macOS)
            // Quitting does not take the scene out of .active first, and the
            // window whose view could watch for it may already be closed.
            _ = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { app.saveDrafts() } }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            FlowView(app: app)
        }
        #if os(macOS)
            .defaultSize(width: 1440, height: 920)
        #endif
        // Draft changes are written a second late; iOS may end an app in the
        // background without running it again.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { app.saveDrafts() }
        }
        .commands { FlowCommands(app: app) }

        #if os(macOS)
            Settings {
                Form { ThreeStepsToggle() }
                    .formStyle(.grouped)
                    // A Form fills whatever height it is given; one switch needs little.
                    .frame(width: 460, height: 150)
            }
            Window("第三方授權", id: "licenses") {
                LicensesView().frame(minWidth: 560, minHeight: 480)
            }
        #endif
    }
}

/// ⌘O, ⌘E, ⌘[ and ⌘] (plan, Phase 4e), and on macOS the installed fonts
/// and the licenses, which have no place in the flow.
private struct FlowCommands: Commands {
    @Bindable var app: AppModel
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("加入字型檔…") { app.importRequested = true }
                .keyboardShortcut("o")
            Button("做出字型並存檔") { app.requestExport() }
                .keyboardShortcut("e")
                .disabled(!app.canGo(to: .export))
            #if os(macOS)
                Divider()
                Button("管理已安裝的字型…") { app.showInstalled() }
            #endif
        }
        CommandGroup(before: .toolbar) {
            Button("上一步") { app.goBack() }
                .keyboardShortcut("[")
                .disabled(app.step == .pick)
            Button("下一步") { app.goForward() }
                .keyboardShortcut("]")
                .disabled(!app.canGo(to: .adjust) || app.step == .export)
            Divider()
        }
        #if os(macOS)
            CommandGroup(replacing: .help) {
                Button("第三方授權") { openWindow(id: "licenses") }
            }
        #endif
    }
}
