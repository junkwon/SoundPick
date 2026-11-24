import SwiftUI
import AppKit

/// A segmented control whose selected segment is filled with the accent
/// colour, so the choice stays obvious even when the window isn't focused
/// (the system control turns grey then).
struct AccentSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(compact ? Theme.label : Theme.body)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 4 : 5)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.controlRadius)
                                .fill(selected ? Theme.accent : Color.clear)
                                .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 1.5, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.groupRadius).fill(Theme.well))
    }
}

/// Shows album art large — up to its full pixel dimensions, or as big as
/// the screen allows — with its real size in the caption.
/// Click the image or press Esc to close.
struct ArtworkViewer: View {
    let candidate: ArtworkCandidate
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var pixels: CGSize = .zero
    @State private var failed = false

    /// Largest side the sheet may take, leaving room around it on screen.
    private var limit: CGFloat {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return max(320, min(screen.width, screen.height) - 220)
    }

    /// Original size in points (1 image pixel = 1 point), capped to the screen.
    private var shown: CGSize {
        guard pixels.width > 0 else { return CGSize(width: 480, height: 480) }
        let scale = min(1, limit / max(pixels.width, pixels.height))
        return CGSize(width: pixels.width * scale, height: pixels.height * scale)
    }

    var body: some View {
        VStack(spacing: Theme.gapLoose) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .onTapGesture { dismiss() }
                } else if failed {
                    Label("Couldn't load the image.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: shown.width, height: shown.height)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))

            HStack {
                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    Text(candidate.title).lineLimit(1)
                    Text(detail)
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: shown.width)
        }
        .padding(16)
        .task {
            do {
                let (data, _) = try await URLSession.shared.data(from: candidate.imageURL)
                guard let rep = NSBitmapImageRep(data: data), let loaded = NSImage(data: data) else {
                    failed = true
                    return
                }
                pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                image = loaded
            } catch {
                failed = true
            }
        }
    }

    private var detail: String {
        guard pixels.width > 0 else { return candidate.subtitle ?? "" }
        var bits = ["\(Int(pixels.width)) × \(Int(pixels.height)) px"]
        if let subtitle = candidate.subtitle { bits.append(subtitle) }
        return bits.joined(separator: " · ")
    }
}
