import SwiftUI

@main
struct PullTubeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppIconInstaller.self) private var iconInstaller

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // Build the system CA bundle in the background so the first
                // fetch doesn't wait for it.
                .task { _ = await SystemCertificates.bundle() }
                // Use the newest yt-dlp installed, and look for a newer one daily.
                .task { YTDLPUpdater.shared.start() }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 760)

        Settings {
            SettingsView()
        }
    }
}
