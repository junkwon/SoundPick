import SwiftUI
import AppKit

/// Lists media files already in the download folder and moves the checked
/// ones into per-artist sub-folders after the user confirms.
struct OrganizeSheet: View {
    /// Starts at the download folder; "Choose Folder…" can point it elsewhere.
    @State var folder: URL
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case scanning, review, done(moved: Int, failures: [String]) }
    @State private var phase: Phase = .scanning
    @State private var items: [LibraryOrganizer.Item] = []

    private var movable: [Binding<LibraryOrganizer.Item>] { $items.filter { $0.wrappedValue.folderName != nil } }
    private var skipped: [LibraryOrganizer.Item] { items.filter { $0.folderName == nil } }
    private var selectedCount: Int { items.filter { $0.include && $0.folderName != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapLoose) {
            Text("Organize Existing Downloads")
                .font(Theme.heading)
            Text("Moves files in “\((folder.path as NSString).abbreviatingWithTildeInPath)” into a folder per artist, using each file’s artist tag. File names stay the same and nothing is overwritten.")
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
                .frame(minHeight: 260)

            footer
        }
        .padding(Theme.gutter + Theme.gapTight)
        .frame(width: 580, height: 480)
        .tint(Theme.neutralTint)
        .task(id: folder) {
            phase = .scanning
            items = await LibraryOrganizer.plan(folder: folder)
            phase = .review
            #if DEBUG
            // `-organizerAutoMove YES` (only with a test `-organizeFolder`) moves
            // the selected files right away, to check the finished screen.
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "organizerAutoMove"), defaults.string(forKey: "organizeFolder") == folder.path {
                let result = LibraryOrganizer.apply(items, in: folder)
                phase = .done(moved: result.moved, failures: result.failures)
            }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .scanning:
            HStack(spacing: Theme.gap) { ProgressView().controlSize(.small); Text("Reading tags…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            if items.isEmpty {
                Text("No MP3, M4A or MP4 files directly in this folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !movable.isEmpty {
                        Section("Will be moved (\(selectedCount) selected)") {
                            ForEach(movable) { $item in
                                Toggle(isOn: $item.include) {
                                    VStack(alignment: .leading, spacing: Theme.gapTight) {
                                        Text(item.fileName).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.turn.down.right")
                                            Text("\(item.folderName ?? "")/")
                                            if !item.fromPullTube {
                                                Text("· not downloaded by SoundPick").foregroundStyle(Theme.warning)
                                            }
                                        }
                                        .font(Theme.meta)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .tint(Theme.accent)
                            }
                        }
                    }
                    if !skipped.isEmpty {
                        Section("Skipped — no artist tag (\(skipped.count))") {
                            ForEach(skipped) { item in
                                Text(item.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        case .done(let moved, let failures):
            VStack(alignment: .leading, spacing: Theme.gap) {
                Label("Moved \(moved) file\(moved == 1 ? "" : "s").", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                if !failures.isEmpty {
                    Text("Couldn’t move \(failures.count):").foregroundStyle(Theme.failure)
                    ScrollView {
                        Text(failures.joined(separator: "\n"))
                            .font(Theme.meta)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var isDone: Bool { if case .done = phase { return true } else { return false } }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Theme.gap) {
            Button("Show Folder") { NSWorkspace.shared.open(folder) }
            if phase != .scanning, !isDone {
                Button("Choose Folder…", action: chooseFolder)
            }
            Spacer()
            switch phase {
            case .done:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            default:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move \(selectedCount) File\(selectedCount == 1 ? "" : "s")") {
                    let result = LibraryOrganizer.apply(items, in: folder)
                    phase = .done(moved: result.moved, failures: result.failures)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(phase != .review || selectedCount == 0)
            }
        }
    }
}
