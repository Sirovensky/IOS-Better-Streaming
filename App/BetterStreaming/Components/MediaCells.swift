import SwiftUI

// MARK: - Track row (Apple Music density)

struct TrackRowView: View {
    @Environment(AppModel.self) private var model
    var track: Track
    var context: [Track]
    /// Show the leading artwork tile (off for tight album track lists).
    var showArtwork: Bool = true
    /// Optional leading number for album track lists.
    var index: Int?

    private var isCurrent: Bool { model.engine.currentTrack?.id == track.id }

    var body: some View {
        Button {
            model.play(track, in: context)
        } label: {
            HStack(spacing: 12) {
                if let index {
                    Text("\(index)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(isCurrent ? DesignTokens.brandPrimary : DesignTokens.textTertiary)
                        .frame(width: 24, alignment: .center)
                } else if showArtwork {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID,
                                glyph: track.kind == .video ? "film" : "music.note", cornerRadius: 6)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .center) {
                            if isCurrent {
                                Image(systemName: "waveform")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrent ? DesignTokens.brandPrimary : DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text(showArtwork ? "\(track.artist) · \(track.album)" : track.artist)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if track.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
                availabilityGlyph

                Menu {
                    trackMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 30, height: 44)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.cacheState.label)")
    }

    @ViewBuilder
    private var availabilityGlyph: some View {
        let state = track.cacheState
        if state == .cached || state == .prefetched {
            Image(systemName: state.systemImage)
                .font(.caption)
                .foregroundStyle(state.tint)
        } else if state == .missingSource || state == .failed {
            Image(systemName: state.systemImage)
                .font(.caption)
                .foregroundStyle(state.tint)
        }
    }

    @ViewBuilder
    private var trackMenu: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            model.engine.playNext(track)
        }
        Button("Add to Queue", systemImage: "text.badge.plus") {
            model.engine.addToQueue(track)
        }
        Button(model.isFavorite(track.id) ? "Remove Favourite" : "Favourite",
               systemImage: model.isFavorite(track.id) ? "star.slash" : "star") {
            model.toggleFavorite(track.id)
        }
        if model.cacheState(track.id) == .cached {
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                model.removeDownload(track.id)
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                model.download(track.id)
            }
        }
    }
}

// MARK: - Square artwork tile (horizontal rails)

struct SquareArtTile: View {
    var artworkKey: String
    var url: URL?
    var title: String
    var subtitle: String
    var glyph: String = "music.note"
    var size: CGFloat = 156
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(url: url, artworkKey: artworkKey, glyph: glyph, cornerRadius: 10)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Album grid cell (2-up grid)

struct AlbumGridCell: View {
    var album: Album
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(url: album.artworkURL, artworkKey: album.id, cornerRadius: 10)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library category row (Playlists / Artists / Albums / Songs nav)

struct LibraryCategoryRow: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 30)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
