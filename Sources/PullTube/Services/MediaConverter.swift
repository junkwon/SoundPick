import Foundation

/// Makes downloaded videos QuickTime-friendly with the bundled ffmpeg:
/// - audio that isn't AAC is re-encoded to AAC (always);
/// - AV1/VP9/VP8 video is re-encoded to HEVC (only when the setting is on).
/// Streams that are already fine are copied untouched.
enum MediaConverter {
    struct Probe {
        var videoCodec: String?
        var pixelFormat: String?
        var height: Int?
        var audioCodecs: [String] = []

        var audioNeedsAAC: Bool { audioCodecs.contains { $0 != "aac" } }

        /// Codecs QuickTime can't reliably play (AV1 only works on M3+ Macs).
        var videoNeedsHEVC: Bool {
            guard let v = videoCodec else { return false }
            return ["av1", "vp9", "vp8"].contains(v)
        }

        var isTenBit: Bool { pixelFormat?.contains("10") == true }
    }

    static var hevcEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.reencodeToHEVC)
    }

    static func probe(_ file: URL) async throws -> Probe {
        // `ffmpeg -i` with no output exits non-zero but prints stream info to stderr.
        let result = try await ProcessRunner().run(
            executable: Vendored.ffmpeg,
            arguments: ["-hide_banner", "-nostdin", "-i", file.path]
        )
        var p = Probe()
        for line in result.stderr.split(separator: "\n") where line.contains("Stream #") {
            if let r = line.range(of: "Audio: ") {
                p.audioCodecs.append(codecName(line[r.upperBound...]))
            } else if p.videoCodec == nil, let r = line.range(of: "Video: ") {
                let rest = line[r.upperBound...]
                let codec = codecName(rest)
                // Skip embedded cover art (mjpeg/png attached pictures).
                if line.contains("attached pic") { continue }
                p.videoCodec = codec
                // "av1 (libdav1d) (Main) (av01 / …), yuv420p10le(tv, bt2020nc…), 3840x2160 …"
                let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count > 1 { p.pixelFormat = String(parts[1].prefix { $0 != "(" }) }
                if let size = parts.first(where: { $0.range(of: #"^\d+x\d+"#, options: .regularExpression) != nil }),
                   let h = Int(size.split(separator: "x")[1].prefix { $0.isNumber }) {
                    p.height = h
                }
            }
        }
        return p
    }

    /// Whether `convert` would do anything for this file.
    static func needsConversion(_ p: Probe) -> Bool {
        p.audioNeedsAAC || (hevcEnabled && p.videoNeedsHEVC)
    }

    /// Converts in place. `onProgress` gets 0…1 when the duration is known.
    static func convert(
        _ file: URL,
        probe p: Probe,
        duration: Double?,
        runner: ProcessRunner,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let tmp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.deletingPathExtension().lastPathComponent).convert-tmp.\(file.pathExtension)")
        try? FileManager.default.removeItem(at: tmp)

        var args = ["-hide_banner", "-nostdin", "-y", "-i", file.path,
                    "-map", "0:v:0?", "-map", "0:a?", "-c", "copy"]
        if hevcEnabled && p.videoNeedsHEVC {
            args += hevcArguments(height: p.height ?? 1080, tenBit: p.isTenBit)
        } else if p.videoCodec == "hevc" {
            args += ["-tag:v", "hvc1"]
        }
        if p.audioNeedsAAC {
            args += ["-c:a", "aac", "-b:a", "192k"]
        }
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", tmp.path]

        let result = try await runner.run(executable: Vendored.ffmpeg, arguments: args) { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            onProgress(min(max(us, 0) / 1_000_000 / duration, 1))
        }

        guard result.status == 0, !result.wasTerminated else {
            try? FileManager.default.removeItem(at: tmp)
            if result.wasTerminated { throw CancellationError() }
            let last = result.stderr.split(separator: "\n").last.map(String.init) ?? "ffmpeg failed"
            throw YTDLPError(message: "Couldn't convert the video: \(last)")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    /// Hardware HEVC via VideoToolbox. Bitrates sit comfortably above what
    /// YouTube's AV1/VP9 sources carry (about 9 Mbit/s at 4K), so the
    /// re-encode isn't visibly worse, without files growing more than needed.
    private static func hevcArguments(height: Int, tenBit: Bool) -> [String] {
        let mbps: Int
        switch height {
        case 2000...: mbps = 30     // 4K and up
        case 1300...: mbps = 14     // 1440p
        case 1000...: mbps = 8      // 1080p
        case 700...:  mbps = 5      // 720p
        default:      mbps = 3
        }
        var args = ["-c:v", "hevc_videotoolbox",
                    "-b:v", "\(mbps)M", "-maxrate", "\(mbps * 3 / 2)M", "-bufsize", "\(mbps * 2)M",
                    // hvc1 tag is required for QuickTime to open HEVC in MP4.
                    "-tag:v", "hvc1"]
        // Keep 10-bit (HDR) sources at 10 bits; otherwise 8-bit Main.
        args += tenBit ? ["-profile:v", "main10", "-pix_fmt", "p010le"]
                       : ["-profile:v", "main", "-pix_fmt", "nv12"]
        return args
    }

    private static func codecName(_ s: Substring) -> String {
        s.prefix { !$0.isWhitespace && $0 != "," && $0 != "(" }.lowercased()
    }
}
