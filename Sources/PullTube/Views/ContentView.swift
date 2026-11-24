import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @State private var window: NSWindow?

    var body: some View {
        HStack(spacing: 0) {
            LeftPane()
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            RightPane()
                .frame(width: 350)
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 620)
        .tint(Theme.neutralTint)
        .background(WindowAccessor(window: $window))
        .onDrop(of: [.url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.ink.opacity(0.55), lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: window) {
            PasteMonitor.shared.install(model: model, window: $0)
            #if DEBUG
            DebugSnapshot.scheduleIfRequested(window: $0)
            #endif
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                guard let link = (url as? NSURL)?.absoluteString else { return }
                Task { @MainActor in model.open(link: link) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let link = text as? String else { return }
                Task { @MainActor in model.open(link: link) }
            }
            return true
        }
        return false
    }
}

/// Opens the Settings window (SettingsLink on macOS 14+, the classic action before).
struct SettingsOpener<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink(label: label)
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { label() }
        }
    }
}

// MARK: - Paste anywhere

/// Captures the hosting NSWindow so ⌘V can be scoped to the main window.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if window !== nsView.window { window = nsView.window } }
    }
}

/// ⌘V in the main window loads the clipboard link, unless a text field is
/// being edited (then it pastes text as usual).
@MainActor
private final class PasteMonitor {
    static let shared = PasteMonitor()
    private var monitor: Any?
    private weak var window: NSWindow?
    private weak var model: AppModel?

    func install(model: AppModel, window: NSWindow?) {
        self.model = model
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = self.window, NSApp.keyWindow === window,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSText)
            else { return event }
            self.model?.pasteFromClipboard()
            return nil
        }
    }
}

#if DEBUG
/// Debug builds only: `-snapshotTo <png path> [-snapshotDelay <seconds>]`
/// saves a picture of the window and quits, for checking the UI.
@MainActor
enum DebugSnapshot {
    private static var scheduled = false

    static func scheduleIfRequested(window: NSWindow?) {
        let defaults = UserDefaults.standard
        guard !scheduled, let window, let path = defaults.string(forKey: "snapshotTo") else { return }
        scheduled = true
        let delay = max(defaults.double(forKey: "snapshotDelay"), 1)
        switch defaults.string(forKey: "snapshotAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // `-openSettings YES` also opens the Settings window, saved as "…-settings.png"
        // (and its sheet, if any, as "…-settings-sheet.png").
        if defaults.bool(forKey: "openSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // The Settings… menu item (⌘,) is the one way that works on every macOS.
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    menu.performActionForItem(at: index)
                }
            }
        }
        // `-clickSearch <seconds>` clicks the search field (a real mouse-down
        // and mouse-up sent to the window) that long after launch; a second
        // click follows if `-clickSearchTwice YES`.
        if defaults.object(forKey: "clickSearch") != nil {
            func click() {
                func find(_ v: NSView) -> NSTextField? {
                    if let f = v as? NSTextField, f.isEditable { return f }
                    for sub in v.subviews { if let f = find(sub) { return f } }
                    return nil
                }
                guard let root = window.contentView, let field = find(root) else { return }
                // Towards the right end of the text, away from the start.
                let point = field.convert(NSPoint(x: field.bounds.width * 0.6, y: field.bounds.midY), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.postEvent(up, atStart: false)   // waiting in the queue for the field's tracking loop
                NSApp.sendEvent(down)                 // through the app, as a real click goes
            }
            let at = defaults.double(forKey: "clickSearch")
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { click() }
            if defaults.bool(forKey: "clickSearchTwice") {
                DispatchQueue.main.asyncAfter(deadline: .now() + at + 1) { click() }
            }
        }
        func save(_ win: NSWindow, _ suffix: String) {
            guard let v = win.contentView?.superview ?? win.contentView else { return }
            v.layoutSubtreeIfNeeded()
            guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: r)
            let out = (path as NSString).deletingPathExtension + suffix + ".png"
            try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for other in NSApp.windows where other !== window && other.isVisible && other.sheetParent == nil
                && other.contentView != nil && other.frame.width > 200 {
                save(other, "-settings")
                if let sheet = other.attachedSheet { save(sheet, "-settings-sheet") }
            }
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            // A sheet is its own window; save it next to the main picture.
            if let sheetWindow = window.attachedSheet,
               let sheet = sheetWindow.contentView?.superview ?? sheetWindow.contentView {
                sheet.layoutSubtreeIfNeeded()
                if let sheetRep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                    sheet.cacheDisplay(in: sheet.bounds, to: sheetRep)
                    let sheetPath = (path as NSString).deletingPathExtension + "-sheet.png"
                    try? sheetRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: sheetPath))
                }
            }
            exit(0)
        }
    }
}
#endif
