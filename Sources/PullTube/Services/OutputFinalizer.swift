import AppKit

/// Writes the user's tags (and, for audio, the chosen cover art) into a
/// downloaded MP3 (ID3), M4A or MP4 (iTunes atoms) in a single ffmpeg pass —
/// all streams are copied, nothing is re-encoded — and names the file
/// "Artist - Title".
enum OutputFinalizer {
    /// - Returns: a note if the cover couldn't be added (tags are still written).
    static func finalize(
        _ file: URL,
        tags: MP3Tags,
        artwork: ArtworkCandidate?,
        sourceURL: String,
        runner: ProcessRunner
    ) async throws -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PullTube-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var note: String?
        var cover: URL?
        if let artwork {
            do {
                let file = dir.appendingPathComponent("cover.jpg")
                try await jpegData(from: artwork.imageURL).write(to: file)
                cover = file
            } catch {
                note = "saved without album art (\(error.localizedDescription))"
            }
        }

        let ext = file.pathExtension.lowercased()
        let isMP3 = ext == "mp3"
        let isVideo = !["mp3", "m4a", "aac", "opus", "ogg", "flac", "wav"].contains(ext)
        if isVideo { cover = nil }  // album art is for audio files only
        // Same extension so ffmpeg picks the right muxer (mp3 / ipod / mp4 …).
        // On the same volume as the download so the final swap doesn't copy
        // a multi-GB video across disks.
        let output = isVideo
            ? file.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).tagging").appendingPathExtension(file.pathExtension)
            : dir.appendingPathComponent("out").appendingPathExtension(file.pathExtension)
        defer { if isVideo { try? FileManager.default.removeItem(at: output) } }
        var args = ["-hide_banner", "-nostdin", "-y", "-i", file.path]
        if let cover { args += ["-i", cover.path] }
        args += isVideo ? ["-map", "0:v?", "-map", "0:a?"] : ["-map", "0:a"]
        if cover != nil { args += ["-map", "1:0"] }
        args += [
            "-c", "copy",
            // Replace whatever tags yt-dlp wrote with exactly the user's.
            "-map_metadata", "-1",
        ]
        if isMP3 {
            // ID3v2.3 only: v1 can't hold Korean (Latin-1) and would show garbage.
            args += ["-id3v2_version", "3"]
        } else {
            args += ["-movflags", "+faststart"]
        }
        let fields: [(String, String)] = [
            ("title", tags.title), ("artist", tags.artist), ("album", tags.album),
            ("date", tags.year), ("genre", tags.genre), ("comment", sourceURL),
            // "3/32": ID3 TRCK / iTunes trkn, so players sort the album in order.
            ("track", tags.trackNumber.map { n in tags.trackCount.map { "\(n)/\($0)" } ?? "\(n)" } ?? ""),
        ]
        for (key, value) in fields {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { args += ["-metadata", "\(key)=\(v)"] }
        }
        if cover != nil {
            if isMP3 {
                args += ["-metadata:s:v", "title=Album cover",
                         "-metadata:s:v", "comment=Cover (front)"]
            }
            // In M4A this becomes the iTunes "covr" atom.
            args += ["-disposition:v", "attached_pic"]
        }
        args.append(output.path)

        let result = try await runner.run(executable: Vendored.ffmpeg, arguments: args)
        if result.wasTerminated { throw CancellationError() }
        guard result.status == 0 else {
            let last = result.stderr.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
            throw YTDLPError(message: "Couldn't write the tags: \(last)")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: output)
        return note
    }

    /// Whether downloads go into a sub-folder per artist (Settings; on by default).
    static var organizeByArtist: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.organizeByArtist) as? Bool ?? true
    }

    /// Moves the file to its final place:
    /// `<download folder>/<Artist>/Artist - Title.<ext>` when sorting by artist,
    /// otherwise `<download folder>/Artist - Title.<ext>`.
    /// - No artist → stays in the download folder itself.
    /// - No title  → keeps its original file name (but still goes in the artist folder).
    /// - Name taken → " (2)", " (3)", … is added.
    static func place(_ mp3: URL, tags: MP3Tags, byArtist: Bool = organizeByArtist) throws -> URL {
        let fm = FileManager.default

        var dir = mp3.deletingLastPathComponent()
        for folder in subfolders(for: tags, byArtist: byArtist) {
            dir.appendPathComponent(folder, isDirectory: true)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = fileBaseName(for: tags) ?? mp3.deletingPathExtension().lastPathComponent
        return try move(mp3, into: dir, baseName: base)
    }

    /// Moves `file` into `dir` as `baseName.<ext>`, adding " (2)", " (3)", …
    /// if that name is taken by another file. Never overwrites anything.
    static func move(_ mp3: URL, into dir: URL, baseName base: String) throws -> URL {
        let ext = mp3.pathExtension
        let fm = FileManager.default
        var target = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            // Same file (e.g. it's already named this, or only the case differs).
            if target.path.lowercased() == mp3.path.lowercased() { break }
            target = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        if target.path == mp3.path { return mp3 }
        if target.path.lowercased() == mp3.path.lowercased() {
            // Case-only rename on a case-insensitive volume needs a hop.
            let hop = dir.appendingPathComponent(".\(UUID().uuidString).\(ext)")
            try fm.moveItem(at: mp3, to: hop)
            try fm.moveItem(at: hop, to: target)
        } else {
            try fm.moveItem(at: mp3, to: target)
        }
        return target
    }

    /// Folders under the download folder: the artist (when sorting by
    /// artist), then the album for album tracks.
    static func subfolders(for tags: MP3Tags, byArtist: Bool = organizeByArtist) -> [String] {
        var folders: [String] = []
        if byArtist, let artist = artistFolderName(for: tags) { folders.append(artist) }
        if let album = albumFolderName(for: tags) { folders.append(album) }
        return folders
    }

    /// Album folder, used only for album tracks (those with a track number).
    static func albumFolderName(for tags: MP3Tags) -> String? {
        guard tags.trackNumber != nil else { return nil }
        var name = safeName(tags.album)
        guard !name.isEmpty else { return nil }
        while name.utf8.count > 200 { name.removeLast() }
        return name
    }

    /// Folder name for the artist; nil when there's no artist.
    static func artistFolderName(for tags: MP3Tags) -> String? {
        var name = safeName(tags.artist)
        guard !name.isEmpty else { return nil }
        while name.utf8.count > 200 { name.removeLast() }
        return name
    }

    /// "Artist - Title" (or "Title"), without extension; nil when there's no title.
    static func fileBaseName(for tags: MP3Tags) -> String? {
        let artist = safeName(tags.artist)
        let title = safeName(tags.title)
        guard !title.isEmpty else { return nil }
        // Album tracks: "01 - Title" (the artist and album are the folders).
        if let n = tags.trackNumber {
            let width = max(2, String(tags.trackCount ?? n).count)
            var base = String(format: "%0\(width)d", n) + " - " + title
            while base.utf8.count > 200 { base.removeLast() }
            return base
        }
        var base = artist.isEmpty ? title : "\(artist) - \(title)"
        // Keep well under the 255-byte filename limit (Korean is 3 bytes/char in UTF-8).
        while base.utf8.count > 200 { base.removeLast() }
        return base
    }

    /// Makes a tag value safe to use in a file name.
    private static func safeName(_ s: String) -> String {
        var t = s
        // "/" is the path separator and ":" shows up as "/" in Finder.
        for bad in ["/", ":", "\\"] { t = t.replacingOccurrences(of: bad, with: "-") }
        t = t.components(separatedBy: .controlCharacters).joined()
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // No leading dots (hidden files) or surrounding spaces.
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
    }

    /// Downloads an image and converts it to JPEG (thumbnails may be WebP/PNG).
    private static func jpegData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw YTDLPError(message: "HTTP \(http.statusCode)")
        }
        guard let rep = NSBitmapImageRep(data: data),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw YTDLPError(message: "unreadable image") }
        return jpeg
    }
}
