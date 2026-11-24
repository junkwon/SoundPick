import SwiftUI
import AVFoundation

/// The round play / pause button drawn over the cover or the video frame.
struct PreviewButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preview: PreviewPlayer
    let info: VideoInfo
    let video: Bool
    var size: CGFloat = 40

    private var active: Bool { preview.isActive(for: info.id, video: video) }

    var body: some View {
        Button { model.togglePreview() } label: {
            ZStack {
                Circle().fill(Theme.accent)
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                if active, preview.state == .loading {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else {
                    Image(systemName: active && preview.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        // The play triangle looks off-centre unless nudged.
                        .offset(x: active && preview.state == .playing ? 0 : size * 0.04)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(active && preview.state == .playing ? "Pause the preview" : (video ? "Preview the video" : "Preview the audio"))
        .accessibilityLabel(active && preview.state == .playing ? "Pause preview" : "Play preview")
    }
}

/// Scrubber and time under the cover while a preview is on, or the reason
/// it couldn't play.
struct PreviewBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preview: PreviewPlayer
    let info: VideoInfo
    let video: Bool
    @State private var showsVolume = false

    private var volumeIcon: String {
        switch preview.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        if preview.isActive(for: info.id, video: video) {
            if case .failed(let message) = preview.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Theme.gapTight) {
                    Slider(value: $preview.time, in: 0...max(preview.duration, 1)) { editing in
                        preview.scrub(editing: editing)
                    }
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(preview.state == .loading)
                    Text("\(Self.clock(preview.time)) / \(Self.clock(preview.duration))")
                        .font(Theme.meta.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { showsVolume.toggle() } label: {
                        Image(systemName: volumeIcon).font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview volume")
                    .popover(isPresented: $showsVolume, arrowEdge: .bottom) {
                        HStack(spacing: Theme.gap) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $preview.volume, in: 0...1).frame(width: 130).tint(Theme.accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        .font(Theme.meta)
                        .padding(10)
                    }
                    Button { model.stopPreview() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the preview")
                }
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The picture of a video preview.
struct PreviewVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

/// The 16:9 frame for Video: the thumbnail, replaced by the picture while
/// the preview plays.
struct VideoPreviewFrame: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preview: PreviewPlayer
    let info: VideoInfo

    private var showsPicture: Bool {
        preview.isActive(for: info.id, video: true) && (preview.state == .playing || preview.state == .paused)
    }

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if showsPicture {
                    PreviewVideoSurface(player: preview.player)
                        .onTapGesture { model.togglePreview() }
                } else {
                    AsyncImage(url: info.thumbnail) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.clear }
                }
            }
            .overlay {
                // While it plays the button steps aside; click the picture to pause.
                if !(showsPicture && preview.state == .playing) {
                    PreviewButton(preview: preview, info: info, video: true, size: 48)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.coverRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.coverRadius).strokeBorder(.primary.opacity(0.08)))
    }
}
