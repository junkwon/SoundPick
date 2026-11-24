import SwiftUI
import AppKit

/// Right side: the selected result — cover, format, tags, where it will be
/// saved, and the Download button.
struct RightPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.fetchState {
            case .idle:
                placeholder(icon: "music.note", text: "Pick a result to see its cover and tags here.")
            case .loading:
                loading
            case .failed(let message):
                failure(message)
            case .loaded(let info):
                Inspector(info: info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidePane)
        .clipped()
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: Theme.gapLoose) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    /// Same shape as the loaded inspector, so nothing jumps when info arrives.
    private var loading: some View {
        VStack(alignment: .leading, spacing: Theme.gapLoose) {
            RoundedRectangle(cornerRadius: Theme.coverRadius).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            ForEach([0.5, 1, 1, 0.7], id: \.self) { fraction in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: Theme.controlRadius).fill(.quaternary)
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: 16)
            }
            HStack(spacing: Theme.gap) {
                ProgressView().controlSize(.small)
                Text("Fetching video info…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.gutter)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapLoose) {
            Label("Couldn't load this video", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.heading)
                .foregroundStyle(Theme.failure)
            Text(message)
                .font(Theme.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if message.localizedCaseInsensitiveContains("cookies") {
                    SettingsOpener { Text("Open Settings") }
                }
                Button("Try again") { model.fetch() }
            }
            Spacer()
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Inspector: View {
    @EnvironmentObject private var model: AppModel
    let info: VideoInfo

    @AppStorage(SettingsKeys.reencodeToHEVC) private var hevc = false
    @AppStorage(SettingsKeys.organizeByArtist) private var organizeByArtist = true
    @AppStorage(SettingsKeys.downloadFolder) private var folder = SettingsKeys.defaultDownloadFolder

    private var isAudio: Bool { model.quality.isAudio }
    @State private var hoveringCover = false
    /// The cover being shown at original size, if any.
    @State private var viewedArtwork: ArtworkCandidate?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    visual
                    heading
                    formatControls
                    TagForm(compact: !isAudio)
                    metaLine
                    detailsStatus
                }
                .padding(Theme.gutter)
            }

            Divider()
            footer
        }
        .animation(.easeInOut(duration: 0.18), value: isAudio)
        .sheet(item: $viewedArtwork) { ArtworkViewer(candidate: $0) }
        #if DEBUG
        // Debug builds: `-openArtViewer YES` opens the viewer for UI checks.
        .task {
            guard UserDefaults.standard.bool(forKey: "openArtViewer") else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            viewedArtwork = model.selectedArtwork
        }
        // `-autoPreview YES` starts the (muted) preview for UI checks.
        .task {
            guard UserDefaults.standard.bool(forKey: "autoPreview") else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            model.preview.player.isMuted = true
            model.togglePreview()
        }
        #endif
    }

    // MARK: Cover / preview

    @ViewBuilder private var visual: some View {
        if isAudio {
            VStack(alignment: .leading, spacing: Theme.gap) {
                CoverImage(candidate: model.selectedArtwork, fullSize: true, cornerRadius: Theme.coverRadius)
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        if hoveringCover, model.selectedArtwork != nil {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(8)
                        }
                    }
                    .onHover { hoveringCover = $0 }
                    .onTapGesture { viewedArtwork = model.selectedArtwork }
                    .help("Click to see the cover at its original size")
                    .overlay(alignment: .bottomLeading) {
                        PreviewButton(preview: model.preview, info: info, video: false)
                            .padding(10)
                    }
                PreviewBar(preview: model.preview, info: info, video: false)
                Text(coverCaption)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.gap) {
                VideoPreviewFrame(preview: model.preview, info: info)
                PreviewBar(preview: model.preview, info: info, video: true)
            }
        }
    }

    /// The selected track's full title and artist. The Title field below is
    /// one line, which hides the part that differs between tracks such as
    /// "…Goldberg Variations, BWV 988: Var. 1" and "…: Var. 2".
    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Text(model.tags.title.isEmpty ? info.title : model.tags.title)
                .font(Theme.heading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !model.tags.artist.isEmpty {
                Text(model.tags.artist)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var coverCaption: String {
        if model.artworkSearchState == .searching { return "Searching for album art…" }
        guard let selected = model.selectedArtwork else { return "No cover" }
        return selected.source == .iTunes ? "\(selected.title) · iTunes" : selected.title
    }

    /// Shown while the track is on screen from its list row and the official
    /// details are still being fetched.
    @ViewBuilder private var detailsStatus: some View {
        if model.isRefiningInfo {
            HStack(spacing: Theme.gap) {
                ProgressView().controlSize(.small)
                Text("Getting official details… You can download already.")
            }
            .font(Theme.meta)
            .foregroundStyle(.secondary)
        } else if let error = model.detailsError {
            Label("Couldn't get the official details. Downloading will try again. (\(error))",
                  systemImage: "exclamationmark.triangle")
                .font(Theme.meta)
                .foregroundStyle(Theme.warning)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "YouTube · Channel · 3:43 · up to 2160p"
    private var metaLine: some View {
        var bits = [info.site, info.uploader, info.durationText].compactMap { $0 }
        if !isAudio, let h = info.maxHeight { bits.append("up to \(h)p") }
        if let n = model.tags.trackNumber {
            bits.insert(model.tags.trackCount.map { "Track \(n) of \($0)" } ?? "Track \(n)", at: 0)
        }
        return Text(bits.joined(separator: " · "))
            .font(Theme.meta)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    // MARK: Format

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if !info.audioOptions.isEmpty {
                AccentSegments(options: [(true, "Audio"), (false, "Video")],
                               selection: Binding(get: { isAudio }, set: { model.setAudioMode($0) }))
            }

            let options = isAudio ? info.audioOptions : info.videoOptions
            // Up to seven resolutions have to fit the pane's width, so long
            // lists drop the "p" (1440, 1080 …) and use the small control size.
            let crowded = options.count > 4
            AccentSegments(
                options: options.map { q in
                    (q, crowded ? q.shortLabel.replacingOccurrences(of: "p", with: "") : q.shortLabel)
                },
                selection: $model.quality,
                compact: crowded)

            if !isAudio && hevc {
                Label("AV1/VP9 video is re-encoded to HEVC for QuickTime. Takes extra time.",
                      systemImage: "wand.and.stars")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.gap) {
                    Image(systemName: "folder").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: Theme.gapTight) {
                        Text(fileName)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(folderPath)
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .multilineTextAlignment(.leading)
                }
                .font(Theme.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the download folder")

            HStack(spacing: Theme.gap) {
                // With tracks ticked in a list, the main button downloads
                // those; otherwise it downloads the track shown here.
                Button {
                    if checkedCount > 0 { model.downloadAll() } else { model.startDownload() }
                } label: {
                    Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SolidButtonStyle())
                .keyboardShortcut(.defaultAction)

                // Settings live here because they're mostly about where and
                // how the file above gets saved.
                SettingsOpener {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .frame(width: Theme.buttonHeight, height: Theme.buttonHeight)
                        .background(RoundedRectangle(cornerRadius: Theme.groupRadius).fill(Theme.well))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings: download folder, artist folders, cookies… (⌘,)")
            }

            if checkedCount > 0 {
                Button("Download only this track") { model.startDownload() }
                    .buttonStyle(.quietLink)
                    .font(Theme.label)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help("Download just the track shown above, whatever is ticked")
            }
        }
        .padding(Theme.gutter)
    }

    /// Ticked tracks in a playlist or album (0 outside one).
    private var checkedCount: Int { model.playlist == nil ? 0 : model.checkedResults.count }

    private var downloadLabel: String {
        guard checkedCount > 0 else { return "Download" }
        if checkedCount == model.results.count { return "Download All \(checkedCount) Tracks" }
        return checkedCount == 1 ? "Download 1 Ticked Track" : "Download \(checkedCount) Ticked Tracks"
    }

    /// "아이유 - 블루밍.mp3"
    private var fileName: String {
        let name = OutputFinalizer.fileBaseName(for: model.tags) ?? info.title
        return "\(name).\(model.quality.fileExtension)"
    }

    /// "Music › 아이유"
    private var folderPath: String {
        let parts = [(folder as NSString).abbreviatingWithTildeInPath]
            + OutputFinalizer.subfolders(for: model.tags, byArtist: organizeByArtist)
        return parts.joined(separator: " › ")
    }
}
