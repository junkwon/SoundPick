import AppKit

/// Shows the app's own artwork as its icon, without macOS re-framing it.
///
/// Recent macOS versions shrink any icon that doesn't fill the rounded-square
/// shape and put it on a grey plate. A custom file icon (the kind Finder's
/// Get Info sets) is exempt, so the app applies its own artwork to its bundle
/// at launch, and uses it for the Dock tile while running.
final class AppIconInstaller: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let folder = NSImage(named: "FolderIcon") else { return }
        NSApp.applicationIconImage = folder

        // "Icon\r" in the bundle root is where a custom icon lives; set it
        // once (it survives until the app is rebuilt or replaced).
        let bundle = Bundle.main.bundleURL
        let marker = bundle.appendingPathComponent("Icon\r")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = NSWorkspace.shared.setIcon(folder, forFile: bundle.path, options: [])
        }
    }
}
