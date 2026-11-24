import AVFoundation
import Combine

/// Plays a track's audio or video straight from the site so the user can
/// check it's the right one before downloading. One preview at a time.
@MainActor
final class PreviewPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        /// Waiting for the track's details or for the stream to start.
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The track being previewed (`VideoInfo.id`).
    @Published private(set) var trackID: String?
    @Published private(set) var isVideo = false
    /// Position in seconds. The scrubber writes it while dragging.
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0

    /// Preview loudness, 0…1. Remembered between launches.
    @Published var volume: Double = PreviewPlayer.savedVolume {
        didSet {
            player.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: "previewVolume")
        }
    }
    private static var savedVolume: Double {
        (UserDefaults.standard.object(forKey: "previewVolume") as? Double).map { min(max($0, 0), 1) } ?? 1
    }

    let player: AVPlayer = {
        let p = AVPlayer()
        p.volume = Float(PreviewPlayer.savedVolume)
        return p
    }()

    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var scrubbing = false
    private var onFailure: (() -> Void)?

    /// Whether this track's preview is on (loading, playing or paused).
    func isActive(for id: String, video: Bool) -> Bool {
        trackID == id && isVideo == video && state != .idle
    }

    /// Shows the spinner for a track whose stream isn't known yet.
    func prepare(trackID: String, video: Bool, duration: Double?) {
        tearDown()
        self.trackID = trackID
        isVideo = video
        self.duration = duration ?? 0
        time = 0
        state = .loading
    }

    /// Starts playing `url`. `onFailure` is called if the stream can't be opened.
    func play(_ url: URL, trackID: String, video: Bool, duration: Double?, onFailure: @escaping () -> Void) {
        prepare(trackID: trackID, video: video, duration: duration)
        self.onFailure = onFailure

        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.statusChanged(status, of: item) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] t in
            let seconds = t.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func statusChanged(_ status: AVPlayerItem.Status, of item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            if state == .loading { state = .playing }
            // Sites sometimes report a wrong length in the file itself, so the
            // one from the track's details wins.
            if duration <= 0, item.duration.isNumeric { duration = item.duration.seconds }
        case .failed:
            let callback = onFailure
            tearDown()
            state = .loading          // the owner may retry; it calls fail() otherwise
            callback?()
        default:
            break
        }
    }

    private func tick(_ seconds: Double) {
        guard state == .playing, !scrubbing, seconds.isFinite else { return }
        time = seconds
        // Stop at the real end even if the file claims to be longer.
        if duration > 0, seconds >= duration { stop() }
    }

    func togglePause() {
        switch state {
        case .playing: player.pause(); state = .paused
        case .paused: player.play(); state = .playing
        default: break
        }
    }

    /// Called by the scrubber while the user drags and when they let go.
    func scrub(editing: Bool) {
        scrubbing = editing
        guard !editing else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func fail(_ message: String) {
        tearDown()
        state = .failed(message)
    }

    func stop() {
        tearDown()
        trackID = nil
        time = 0
        state = .idle
    }

    private func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver = nil
        onFailure = nil
        scrubbing = false
        player.replaceCurrentItem(with: nil)
    }
}
