import SwiftUI

// MARK: - Routing

enum LibraryRoute: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case allSongs
    case allAlbums
    case allArtists
    case allPlaylists
    case offline
    case sources
    case settings
}

extension View {
    /// Shared destination table so Home and Library navigate identically.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .album(let id): AlbumDetailView(albumID: id)
            case .artist(let id): ArtistDetailView(artistID: id)
            case .playlist(let id): PlaylistDetailView(playlistID: id)
            case .allSongs: AllSongsView()
            case .allAlbums: AllAlbumsView()
            case .allArtists: AllArtistsView()
            case .allPlaylists: AllPlaylistsView()
            case .offline: OfflineLibraryView()
            case .sources: SourcesView()
            case .settings: SettingsView()
            }
        }
    }
}

// MARK: - Detail header

private struct MediaDetailHeader: View {
    var artworkKey: String
    var artworkURL: URL?
    var glyph: String
    var title: String
    var subtitle: String
    var meta: String
    var playAction: () -> Void
    var shuffleAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ArtworkView(url: artworkURL, artworkKey: artworkKey, glyph: glyph, cornerRadius: 12)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DesignTokens.brandPrimary)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
            }

            HStack(spacing: 12) {
                Button(action: playAction) {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Button(action: shuffleAction) {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Album

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    var albumID: String

    private var albumTracks: [Track] { model.tracks(forAlbum: albumID) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if let first = albumTracks.first {
                    MediaDetailHeader(
                        artworkKey: albumID,
                        artworkURL: albumTracks.compactMap(\.artworkURL).first,
                        glyph: "music.note",
                        title: first.album,
                        subtitle: first.artist,
                        meta: "\(albumTracks.count) songs",
                        playAction: { model.playAlbum(albumID) },
                        shuffleAction: { model.playAlbum(albumID, shuffled: true) }
                    )
                    .padding(.bottom, 12)
                }

                ForEach(Array(albumTracks.enumerated()), id: \.element.id) { idx, track in
                    TrackRowView(track: track, context: albumTracks, index: idx + 1)
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle(albumTracks.first?.album ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Artist

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    var artistID: String

    private var artistTracks: [Track] { model.tracks(forArtist: artistID) }
    private var artistAlbums: [Album] { model.albums.filter { $0.artistID == artistID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let name = artistTracks.first?.artist {
                    VStack(spacing: 12) {
                        ArtworkView(url: nil, artworkKey: artistID, glyph: "music.mic", cornerRadius: 80)
                            .frame(width: 140, height: 140)
                        Text(name).font(.title.weight(.bold)).foregroundStyle(DesignTokens.textPrimary)
                        HStack(spacing: 12) {
                            Button {
                                model.engine.setShuffle(false)
                                model.engine.play(model.tracks(forArtist: artistID))
                            } label: {
                                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }.buttonStyle(PrimaryActionButtonStyle())
                            Button {
                                model.engine.playShuffled(model.tracks(forArtist: artistID))
                            } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }.buttonStyle(SecondaryActionButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                if !artistAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Albums")
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(artistAlbums) { album in
                                    NavigationLink(value: LibraryRoute.album(album.id)) {
                                        SquareArtTileStatic(artworkKey: album.id, title: album.title, subtitle: "\(album.trackCount) songs")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Songs")
                    ForEach(artistTracks) { track in
                        TrackRowView(track: track, context: artistTracks)
                        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                    }
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle(artistTracks.first?.artist ?? "Artist")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Non-button tile for use inside a NavigationLink.
struct SquareArtTileStatic: View {
    var artworkKey: String
    var url: URL?
    var title: String
    var subtitle: String
    var glyph: String = "music.note"
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: url, artworkKey: artworkKey, glyph: glyph, cornerRadius: 10)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
        }
        .frame(width: size)
    }
}

// MARK: - Playlist

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    var playlistID: String

    private var playlist: Playlist? { model.playlists.first { $0.id == playlistID } }
    private var playlistTracks: [Track] { model.tracks(playlist?.trackIDs ?? []) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if let playlist {
                    MediaDetailHeader(
                        artworkKey: playlist.id,
                        artworkURL: playlist.artworkURLs.first,
                        glyph: playlist.isLiveFolder ? "folder.fill" : "music.note.list",
                        title: playlist.name,
                        subtitle: playlist.subtitle,
                        meta: "\(playlistTracks.count) songs",
                        playAction: { model.playPlaylist(playlist) },
                        shuffleAction: { model.playPlaylist(playlist, shuffled: true) }
                    )
                    .padding(.bottom, 12)
                }

                ForEach(playlistTracks) { track in
                    TrackRowView(track: track, context: playlistTracks)
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - "All" list screens

struct AllSongsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                PlayShuffleBar(
                    play: { model.engine.setShuffle(false); model.engine.play(model.audioTracks) },
                    shuffle: { model.shuffleAll() }
                )
                .disabled(model.audioTracks.isEmpty)
                .padding(.bottom, 6)

                ForEach(model.audioTracks) { track in
                    TrackRowView(track: track, context: model.audioTracks)
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Songs")
    }
}

/// Reusable Play / Shuffle action pair for list headers.
struct PlayShuffleBar: View {
    var play: () -> Void
    var shuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
    }
}

struct AllAlbumsView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.albums) { album in
                    NavigationLink(value: LibraryRoute.album(album.id)) {
                        AlbumGridCellStatic(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Albums")
    }
}

struct AllArtistsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.artists) { artist in
                    NavigationLink(value: LibraryRoute.artist(artist.id)) {
                        HStack(spacing: 12) {
                            ArtworkView(url: nil, artworkKey: artist.id, glyph: "music.mic", cornerRadius: 26)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                                Text("\(artist.albumCount) albums · \(artist.trackCount) songs")
                                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(DesignTokens.textTertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Artists")
    }
}

struct AllPlaylistsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.playlists) { playlist in
                    NavigationLink(value: LibraryRoute.playlist(playlist.id)) {
                        HStack(spacing: 12) {
                            ArtworkView(url: playlist.artworkURLs.first, artworkKey: playlist.id,
                                        glyph: playlist.isLiveFolder ? "folder.fill" : "music.note.list", cornerRadius: 8)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
                                Text(playlist.subtitle).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(DesignTokens.textTertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Playlists")
    }
}

/// Non-button album cell for NavigationLink.
struct AlbumGridCellStatic: View {
    var album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: album.artworkURL, artworkKey: album.id, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
            Text(album.artist).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
        }
    }
}
