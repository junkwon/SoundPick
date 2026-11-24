import AVFoundation

/// Sorts files that are already in the download folder into per-artist
/// sub-folders, using each file's own artist tag. File names are kept as they
/// are; only the folder changes. Nothing is overwritten.
enum LibraryOrganizer {
    struct Item: Identifiable {
        var id: URL { source }
        let source: URL
        let artist: String?
        /// The artist sub-folder it would go into; nil when it's skipped.
        let folderName: String?
        /// Whether the file carries a source-URL comment, i.e. PullTube wrote it.
        let fromPullTube: Bool
        var include: Bool

        var fileName: String { source.lastPathComponent }
    }

    static let mediaExtensions: Set<String> = ["mp3", "m4a", "mp4", "m4v", "mov"]

    /// Looks at the media files directly inside `folder` (not in sub-folders).
    /// Files PullTube made are pre-selected; other tagged files are listed but
    /// left unchecked; files without an artist tag are returned as skipped.
    static func plan(folder: URL) async -> [Item] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []

        var items: [Item] = []
        for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard mediaExtensions.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }

            let (artist, fromPullTube) = await readTags(file)
            var tags = MP3Tags()
            tags.artist = artist ?? ""
            let folderName = OutputFinalizer.artistFolderName(for: tags)
            items.append(Item(source: file, artist: artist, folderName: folderName,
                              fromPullTube: fromPullTube,
                              include: folderName != nil && fromPullTube))
        }
        return items
    }

    /// Moves the included items. Returns how many moved and any failures.
    static func apply(_ items: [Item], in folder: URL) -> (moved: Int, failures: [String]) {
        var moved = 0
        var failures: [String] = []
        for item in items where item.include {
            guard let name = item.folderName else { continue }
            do {
                let dir = folder.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                _ = try OutputFinalizer.move(item.source, into: dir,
                                             baseName: item.source.deletingPathExtension().lastPathComponent)
                moved += 1
            } catch {
                failures.append("\(item.fileName): \(error.localizedDescription)")
            }
        }
        return (moved, failures)
    }

    /// Artist tag (ID3 TPE1 / iTunes ©ART) and whether a comment holds a web URL.
    private static func readTags(_ file: URL) async -> (artist: String?, fromPullTube: Bool) {
        let asset = AVURLAsset(url: file)
        guard let metadata = try? await asset.load(.metadata) else { return (nil, false) }
        var artist: String?
        var fromPullTube = false
        for item in metadata {
            let value = (try? await item.load(.stringValue))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { continue }
            if item.commonKey == .commonKeyArtist, artist == nil { artist = value }
            if value.hasPrefix("https://") || value.hasPrefix("http://") { fromPullTube = true }
        }
        return (artist, fromPullTube)
    }
}
