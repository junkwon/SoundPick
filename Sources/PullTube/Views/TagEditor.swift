import SwiftUI

/// Tag fields. They also decide the "Artist - Title" file name and the
/// artist folder (shown live in the card footer).
/// `compact` (video) shows Title and Artist, with the rest behind "More tags".
struct TagForm: View {
    @EnvironmentObject private var model: AppModel
    let compact: Bool
    @State private var showMore = false

    private var showAll: Bool { !compact || showMore }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    label("Title")
                    field("Title", $model.tags.title).gridCellColumns(3)
                }
                GridRow {
                    label("Artist")
                    field("Artist", $model.tags.artist).gridCellColumns(3)
                }
                if showAll {
                    GridRow {
                        label("Album")
                        field("Album", $model.tags.album).gridCellColumns(3)
                    }
                    GridRow {
                        label("Year")
                        HStack(spacing: Theme.gap) {
                            field("YYYY", $model.tags.year).frame(width: 70)
                            label("Genre")
                            field("Genre", $model.tags.genre)
                        }
                        .gridCellColumns(3)
                    }
                }
            }

            if compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showMore.toggle() }
                } label: {
                    Label(showMore ? "Fewer tags" : "More tags",
                          systemImage: showMore ? "chevron.down" : "chevron.right")
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 48)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(Theme.label)
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
    }
}
