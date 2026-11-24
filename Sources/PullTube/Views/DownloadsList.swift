import SwiftUI
import AppKit

struct DownloadsList: View {
    @EnvironmentObject private var model: AppModel

    /// Shows up to three rows; more scroll.
    private var listHeight: CGFloat { CGFloat(min(model.downloads.count, 3)) * 54 }

    /// "5 of 32 done" once there are more rows than fit.
    private var summary: String? {
        guard model.downloads.count > 3 else { return nil }
        let done = model.downloads.filter { $0.status == .finished }.count
        return "\(done) of \(model.downloads.count) done"
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: summary.map { "Downloads · \($0)" } ?? "Downloads") {
                if model.downloads.contains(where: { !$0.status.isActive }) {
                    Button("Clear finished") { model.clearFinished() }
                        .buttonStyle(.quietLink)
                        .font(Theme.meta)
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.downloads) { item in
                        DownloadRow(item: item)
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .frame(height: listHeight)
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: Theme.gapLoose) {
            AsyncImage(url: item.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: Theme.gapTight) {
                Text(item.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLines
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.rowPadding)
        .contentShape(Rectangle())
        .contextMenu {
            if let file = item.outputFile, item.status == .finished {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if item.status.isActive {
                Button("Cancel") { item.cancel() }
            } else {
                Button("Remove from List") { model.remove(item) }
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusLines: some View {
        switch item.status {
        case .queued:
            caption("Waiting…")
        case .starting:
            thinBar(nil)
            caption(item.detail.isEmpty ? "Starting…" : item.detail)
        case .downloading:
            thinBar(item.progress)
            caption(item.detail)
        case .processing(let what):
            thinBar(item.progress)
            caption(item.progress.map { "\(what) \(Int(($0 * 100).rounded()))%" } ?? what)
        case .finished:
            caption(item.detail)
            if let note = item.note {
                caption(note.prefix(1).uppercased() + note.dropFirst(), color: Theme.warning, lines: 2)
            }
        case .failed(let message):
            caption(message, color: Theme.failure, lines: 3)
        case .cancelled:
            caption("Cancelled")
        }
    }

    private func thinBar(_ value: Double?, tint: Color = Theme.accent) -> some View {
        Group {
            if let value {
                ProgressView(value: value)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .controlSize(.small)
        .tint(tint)
    }

    private func caption(_ s: String, color: Color = .secondary, lines: Int = 1) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(Theme.meta)
            .foregroundStyle(color)
            .lineLimit(lines)
            .monospacedDigit()
            .textSelection(.enabled)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch item.status {
        case .queued, .starting, .downloading, .processing:
            iconButton("xmark.circle.fill", help: "Cancel") { item.cancel() }
        case .finished:
            if item.note == nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
            }
            if let file = item.outputFile {
                iconButton("folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
        case .failed, .cancelled:
            iconButton("arrow.clockwise", help: "Try again") { model.retry(item) }
            iconButton("trash", help: "Remove from list") { model.remove(item) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
