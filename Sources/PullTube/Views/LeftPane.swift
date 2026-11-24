import SwiftUI

/// Left side: search, results, album art for the selected result, downloads.
struct LeftPane: View {
    @EnvironmentObject private var model: AppModel

    private var showsAlbumArt: Bool {
        if case .loaded = model.fetchState { return model.quality.isAudio }
        return false
    }

    /// Ticks or unticks every track; shows a dash when only some are ticked.
    private var masterCheckbox: some View {
        let checked = model.checkedResults.count, total = model.results.count
        let symbol = checked == total ? "checkmark.square.fill" : (checked == 0 ? "square" : "minus.square.fill")
        return Button {
            model.setAllChecked(checked != total)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(checked == 0 ? Color.secondary : Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(checked == total ? "Untick every track" : "Tick every track")
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar()
                .padding(Theme.gutter)

            SectionHeader(title: model.playlist?.title ?? "Results",
                          leading: model.playlist != nil ? AnyView(masterCheckbox) : nil) {
                HStack(spacing: Theme.gapLoose) {
                    if let offer = model.playlistOffer, !offer.isEmpty {
                        Button("Show playlist") { model.showOfferedPlaylist() }
                            .buttonStyle(.quietLink)
                            .font(Theme.meta)
                            .help("List every track of the playlist this video is in")
                    }
                    if !model.results.isEmpty {
                        // The Download button on the right acts on the ticked tracks.
                        Text(model.playlist != nil
                             ? "\(model.checkedResults.count) of \(model.results.count) ticked"
                             : "\(model.results.count)")
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize()
            }
            ResultsList()
                .frame(minHeight: 120, maxHeight: .infinity)

            if showsAlbumArt {
                AlbumArtSection()
            }
            if !model.downloads.isEmpty {
                DownloadsList()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsAlbumArt)
        .animation(.easeInOut(duration: 0.18), value: model.downloads.isEmpty)
    }
}

/// Grey strip that titles each stacked section.
struct SectionHeader<Trailing: View>: View {
    let title: String
    /// Optional control before the title (the playlist's tick-all box).
    var leading: AnyView? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let leading { leading }
                Text(title)
                    .font(Theme.section)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, Theme.gutter)
            .frame(height: Theme.headerHeight)
            .background(Color.primary.opacity(0.035))
            Divider()
        }
    }
}

// MARK: - Search

/// Makes a click in the search field select its whole text, so typing or
/// Delete replaces what was there, the way a browser's address bar does.
///
/// The field usually keeps the keyboard focus, so "on focus" is not enough.
/// Instead the next click is "armed" whenever the user has been doing
/// something else: after a search or link is submitted or loaded, after a
/// click anywhere outside the field, and at launch. The armed click selects
/// everything; clicks after it place the cursor as usual. Dragging to select
/// part of the text is left alone.
@MainActor
final class SearchFieldSelectAll {
    static let shared = SearchFieldSelectAll()
    static let placeholder = "Search for a song, or paste a link"

    private var armed = true
    private var monitor: Any?

    func arm() { armed = true }

    func install() {
        guard monitor == nil else { return }
        // Mouse-down only: the field's own tracking loop swallows the mouse-up.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if !self.isInSearchField(event) {
                self.armed = true
            } else if self.armed {
                self.armed = false
                self.selectAllOnRelease(in: event.window)
            }
            return event
        }
    }

    /// Waits for the button to come up (the field has placed its cursor by
    /// then), and selects everything unless the user dragged out a selection.
    private func selectAllOnRelease(in window: NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            if NSEvent.pressedMouseButtons & 1 != 0 { self?.selectAllOnRelease(in: window); return }
            guard let editor = window?.firstResponder as? NSTextView,
                  (editor.delegate as? NSTextField)?.placeholderString == Self.placeholder,
                  editor.selectedRange().length == 0 else { return }
            editor.selectAll(nil)
        }
    }

    private func isInSearchField(_ event: NSEvent) -> Bool {
        guard let root = event.window?.contentView?.superview ?? event.window?.contentView,
              var view = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
        while true {
            if let field = view as? NSTextField { return field.placeholderString == Self.placeholder }
            if let editor = view as? NSTextView, let field = editor.delegate as? NSTextField {
                return field.placeholderString == Self.placeholder
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }
}

private struct SearchBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.accent)
            TextField(SearchFieldSelectAll.placeholder, text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit { SearchFieldSelectAll.shared.arm(); model.submit() }
                .onChange(of: model.urlText) { _ in
                    // Text put there by Paste, a drop or ⌘V (not typed): the
                    // next click selects it all again.
                    let event = NSApp.currentEvent
                    if event?.type != .keyDown || event?.modifierFlags.contains(.command) == true {
                        SearchFieldSelectAll.shared.arm()
                    }
                    model.urlTextChanged()
                }
                .onAppear { SearchFieldSelectAll.shared.install() }
            if model.searchState == .searching {
                ProgressView().controlSize(.small)
            }
            if !model.urlText.isEmpty {
                Button { model.clearLink() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Button { model.pasteFromClipboard() } label: {
                Label("Paste", systemImage: "doc.on.clipboard.fill")
                    .font(Theme.label.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paste a link or search text from the clipboard (⌘V)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.groupRadius).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.groupRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Results

private struct ResultsList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.results.isEmpty {
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { result in
                        ResultRow(result: result, selected: model.selectedResultID == result.id,
                                  checked: model.playlist == nil ? nil : Binding(
                                      get: { model.isChecked(result) },
                                      set: { model.setChecked($0, for: result) }),
                                  edited: model.trackEdits[result.id] != nil,
                                  editedTitle: model.trackEdits[result.id]?.tags?.title,
                                  ownFormat: model.ownFormatLabel(for: result),
                                  cover: model.coverOverride(for: result))
                            .onTapGesture { model.select(result) }
                            .contextMenu {
                                if model.trackEdits[result.id] != nil {
                                    Button("Discard Changes to This Track") { model.discardEdits(for: result) }
                                }
                            }
                        Divider().padding(.leading, 100)
                    }
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.searchState {
        case .searching:
            VStack(spacing: Theme.gap) {
                ProgressView()
                Text("Searching…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: Theme.gap) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure).font(.title2)
                Text(message)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if message.localizedCaseInsensitiveContains("cookies") {
                        SettingsOpener { Text("Open Settings") }
                    }
                    Button("Try again") { model.submit() }
                }
            }
            .padding(20)
        case .done:
            Text("No results. Try different words.").foregroundStyle(.secondary)
        case .idle:
            if case .loading = model.fetchState {
                VStack(spacing: Theme.gap) {
                    ProgressView()
                    Text("Loading the link…").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: Theme.gap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 2)
                    Text("Search for a song or paste a link")
                        .font(.title3.weight(.medium))
                    Text("Type a title and press Return, or press ⌘V with a link copied.")
                        .foregroundStyle(.secondary)
                    Text("Search covers YouTube. Links also work for Vimeo and TikTok.")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let selected: Bool
    /// Playlist tracks get a tick box that decides whether "Download all"
    /// includes them; nil for ordinary results.
    var checked: Binding<Bool>? = nil
    /// The user changed this track's cover or tags.
    var edited = false
    /// The title the user typed for this track, shown instead of the site's.
    var editedTitle: String? = nil
    /// "Video 1080p" etc. when this track has its own format choice.
    var ownFormat: String? = nil
    /// A cover chosen by the user for this row (nil artwork = "No cover").
    var cover: (isSet: Bool, artwork: ArtworkCandidate?) = (false, nil)

    /// Album and playlist tracks (numbered) show a small square cover and a
    /// lower row; search results keep the wide video thumbnail.
    private var isTrack: Bool { result.index != nil }
    private var thumbHeight: CGFloat { isTrack ? 36 : 40.5 }
    private var thumbWidth: CGFloat { isTrack ? 36 : 72 }

    var body: some View {
        HStack(spacing: Theme.gapLoose) {
            if let checked {
                Button {
                    checked.wrappedValue.toggle()
                } label: {
                    Image(systemName: checked.wrappedValue ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(checked.wrappedValue ? Theme.accent : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(checked.wrappedValue ? "Included in the download. Click to leave it out." : "Left out. Click to include it.")
            }
            if let index = result.index {
                Text("\(index)")
                    .font(Theme.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            if cover.isSet {
                // The chosen cover replaces the video thumbnail.
                CoverImage(candidate: cover.artwork, cornerRadius: Theme.controlRadius)
                    .frame(width: thumbHeight, height: thumbHeight)
                    .frame(width: thumbWidth)
            } else {
                Rectangle().fill(.quaternary)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .overlay {
                        AsyncImage(url: result.thumbnail) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color.clear }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            }

            VStack(alignment: .leading, spacing: Theme.gapTight) {
                Text(editedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? result.title)
                    .lineLimit(1)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(checked?.wrappedValue == false ? Color.secondary : Color.primary)
                Text([result.subtitle, ownFormat].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.meta)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if edited {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .help("You changed this track's cover, tags or format. Right-click to discard the changes.")
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, isTrack ? 6 : Theme.rowPadding)
        .background(selected ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
    }
}
