import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage(SettingsKeys.useBrowserCookies) private var useCookies = false
    @AppStorage(SettingsKeys.cookieBrowser) private var browser = "safari"
    @AppStorage(SettingsKeys.downloadFolder) private var folder = SettingsKeys.defaultDownloadFolder
    @AppStorage(SettingsKeys.reencodeToHEVC) private var reencodeHEVC = false
    @AppStorage(SettingsKeys.organizeByArtist) private var organizeByArtist = true
    @State private var showOrganizer = false
    @ObservedObject private var updater = YTDLPUpdater.shared

    private let browsers = [
        ("safari", "Safari"), ("chrome", "Chrome"), ("firefox", "Firefox"),
        ("brave", "Brave"), ("edge", "Edge"), ("chromium", "Chromium"),
    ]

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Save into a folder per artist", isOn: $organizeByArtist)
                    .tint(Theme.accent)
                Text(organizeByArtist
                     ? "Example: Downloads/아이유/아이유 - 블루밍.mp3. Downloads without an artist stay in the main folder."
                     : "Example: Downloads/아이유 - 블루밍.mp3")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                Button("Organize Existing Downloads…") { showOrganizer = true }
            }

            Section {
                Toggle("Re-encode AV1/VP9 video (incl. 4K) to HEVC", isOn: $reencodeHEVC)
                    .tint(Theme.accent)
            } header: {
                Text("QuickTime compatibility")
            } footer: {
                Text("YouTube serves 1440p and 4K only as AV1 or VP9, which QuickTime can’t play on most Macs. This converts any AV1/VP9 download to HEVC with hardware encoding after it finishes, which takes extra time. H.264 downloads are left alone. Audio is always converted to AAC.")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use browser cookies", isOn: $useCookies)
                    .tint(Theme.accent)
                Picker("Browser", selection: $browser) {
                    ForEach(browsers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!useCookies)
            } header: {
                Text("Sign-in")
            } footer: {
                Text("Fixes HTTP 403 and “Sign in to confirm” errors by reusing your browser’s session. Safari cookies require giving SoundPick Full Disk Access in System Settings › Privacy & Security.")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
            }

            Section("Bundled tools") {
                LabeledContent("yt-dlp") {
                    HStack(spacing: Theme.gap) {
                        Text(ytdlpSummary).foregroundStyle(.secondary)
                        if case .downloading = updater.state {
                            ProgressView().controlSize(.small)
                        } else if updater.state == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check for Update") { Task { await updater.check() } }
                        }
                    }
                }
                if let note = ytdlpNote {
                    Text(note.text)
                        .font(Theme.meta)
                        .foregroundStyle(note.isError ? Theme.failure : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("ffmpeg", value: status(Vendored.ffmpeg))
                LabeledContent("deno (JS runtime)", value: status(Vendored.deno))
            }
        }
        .formStyle(.grouped)
        .tint(Theme.neutralTint)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showOrganizer) {
            OrganizeSheet(folder: URL(fileURLWithPath: organizerFolder, isDirectory: true))
        }
        #if DEBUG
        // `-openOrganizer YES` shows the sheet for UI checks.
        .task {
            guard UserDefaults.standard.bool(forKey: "openOrganizer") else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showOrganizer = true
        }
        #endif
    }

    /// The download folder; debug builds can point the sheet at a test
    /// folder with `-organizeFolder <path>`.
    private var organizerFolder: String {
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "organizeFolder") { return test }
        #endif
        return folder
    }

    /// "2026.11.23 · updated" / "2026.11.23 · bundled".
    private var ytdlpSummary: String {
        guard let version = updater.version else { return status(Vendored.ytdlp) }
        return "\(version) · \(updater.usingInstalled ? "updated" : "bundled")"
    }

    private var ytdlpNote: (text: String, isError: Bool)? {
        switch updater.state {
        case .idle: return ("SoundPick looks for a newer yt-dlp once a day, because YouTube changes often.", false)
        case .checking: return ("Checking for a newer yt-dlp…", false)
        case .downloading(let version):
            return ("Downloading yt-dlp \(version)…", false)
        case .upToDate: return ("yt-dlp is up to date.", false)
        case .updated(let version): return ("Updated to yt-dlp \(version).", false)
        case .failed(let message): return ("Couldn’t update yt-dlp: \(message)", true)
        }
    }

    private func status(_ url: URL) -> String {
        FileManager.default.isExecutableFile(atPath: url.path) ? "Bundled" : "Missing"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}
