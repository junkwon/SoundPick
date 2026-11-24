import SwiftUI

/// A square cover image; video thumbnails are centre-cropped.
struct CoverImage: View {
    let candidate: ArtworkCandidate?
    var fullSize = false
    var cornerRadius: CGFloat = 6

    var body: some View {
        // A square box first, then the image as an overlay, so wide video
        // thumbnails are centre-cropped instead of spilling out.
        Rectangle().fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let candidate {
                    AsyncImage(url: fullSize ? candidate.imageURL : candidate.previewURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                } else {
                    Image(systemName: "nosign").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}

/// Left-pane section: every cover candidate for the selected result.
/// The chosen one shows large in the right pane.
struct AlbumArtSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSearchField = false

    private let tileWidth: CGFloat = 64

    var body: some View {
        content
            // Keep the search field open while its results are showing.
            .onChange(of: model.artworkResultsFirst) { if $0 { showSearchField = true } }
            .onAppear { if model.artworkResultsFirst { showSearchField = true } }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Album art") {
                HStack(spacing: Theme.gapLoose) {
                    if model.artworkSearchState == .searching {
                        ProgressView().controlSize(.small)
                    }
                    // In a playlist a cover belongs to the selected track
                    // unless it's handed to every track here.
                    if model.playlist != nil {
                        if model.selectedCoverIsForAll {
                            if model.coverForAll != .official {
                                Label("Used for all tracks", systemImage: "checkmark")
                                    .font(Theme.meta)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Use for all tracks") { model.useSelectedCoverForAll() }
                                .buttonStyle(.quietLink)
                                .font(Theme.meta)
                                .help("Give every track in the list this cover. Without this, the cover applies only to the selected track.")
                        }
                    }
                    Button { showSearchField.toggle() } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Search for other album art")
                }
            }

            if showSearchField {
                HStack(spacing: Theme.gap) {
                    TextField("Artist, album or song", text: $model.artworkQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.searchArtwork(userInitiated: true) }
                    Button {
                        model.searchArtwork(userInitiated: true)
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.artworkQuery.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.artworkSearchState == .searching)
                    .help("Find album art for these words")
                    Button("Use tags") {
                        model.artworkQuery = model.tags.searchTerm
                        model.searchArtwork(userInitiated: true)
                    }
                    .disabled(model.tags.searchTerm.isEmpty)
                    .help("Replace the words with the Artist and Title from the tags, then search")
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            }

            // One row that scrolls sideways, so the results list keeps its height.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.gap) {
                    ForEach(orderedCandidates) { candidate in
                        tile(candidate, title: candidate.title).frame(width: tileWidth)
                    }
                    tile(nil, title: "No cover").frame(width: tileWidth)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 10)
            }
            .frame(height: tileWidth + 40)

            if let status {
                Text(status.text)
                    .font(Theme.meta)
                    .foregroundStyle(status.isError ? Theme.failure : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 8)
            }
        }
    }

    /// The album's own cover, then search matches, then the video thumbnail.
    /// After a manual search the matches come first.
    private var orderedCandidates: [ArtworkCandidate] {
        let album = model.artworkCandidates.filter { $0.source == .album }
        let found = model.artworkCandidates.filter { $0.source == .iTunes }
        let thumb = model.artworkCandidates.filter { $0.source == .videoThumbnail }
        return model.artworkResultsFirst ? found + album + thumb : album + found + thumb
    }

    private func tile(_ candidate: ArtworkCandidate?, title: String) -> some View {
        let selected = model.selectedArtwork == candidate
        return Button {
            model.pickArtwork(candidate)
        } label: {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                CoverImage(candidate: candidate)
                    .overlay(alignment: .center) {
                        if candidate?.source == .videoThumbnail {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2.5))
                Text(title)
                    .font(Theme.meta.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help([candidate?.title ?? title, candidate?.subtitle, candidate?.year]
            .compactMap { $0 }.joined(separator: " — "))
    }

    private var status: (text: String, isError: Bool)? {
        switch model.artworkSearchState {
        case .failed(let message):
            return (message, true)
        case .done where !model.artworkCandidates.contains(where: { $0.source == .iTunes }):
            return ("No album art found for “\(model.lastArtworkSearch?.query ?? model.artworkQuery)”. Try other words.", false)
        case .done:
            // Confirms that a search ran and what it was for.
            guard showSearchField, let last = model.lastArtworkSearch else { return nil }
            return ("\(last.count) cover\(last.count == 1 ? "" : "s") for “\(last.query)”", false)
        case .searching:
            return ("Searching…", false)
        default:
            return nil
        }
    }
}
