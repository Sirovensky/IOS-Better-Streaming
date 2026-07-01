import SwiftUI
import UniformTypeIdentifiers

// MARK: - Routing

enum LibraryRoute: Hashable, Identifiable {
    var id: LibraryRoute { self }
    case album(String)
    case artist(String)
    case albumArtists(String)
    case playlist(String)
    case allSongs
    case allAlbums
    case allArtists
    case allPlaylists
    case offline
    case sources
    case settings
    case fixMetadata
}

/// A push action injected by each NavigationStack host so deep views (e.g. an
/// album cell's context menu) can navigate without owning the path. A
/// `NavigationLink` inside `.contextMenu` doesn't work on iOS (detached platter),
/// so menu items mutate the host path through this instead.
private struct LibraryNavigateKey: EnvironmentKey {
    // nil default; real values are MainActor closures set/read only in SwiftUI's
    // MainActor context, so the static is safe to mark nonisolated(unsafe).
    nonisolated(unsafe) static let defaultValue: ((LibraryRoute) -> Void)? = nil
}

extension EnvironmentValues {
    var libraryNavigate: ((LibraryRoute) -> Void)? {
        get { self[LibraryNavigateKey.self] }
        set { self[LibraryNavigateKey.self] = newValue }
    }
}

extension View {
    /// Wire `libraryNavigate` to push onto a host's NavigationStack path.
    func libraryNavigation(_ path: Binding<[LibraryRoute]>) -> some View {
        environment(\.libraryNavigate, { route in path.wrappedValue.append(route) })
    }
}

extension View {
    /// Shared destination table so Home and Library navigate identically.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .album(let id): AlbumDetailView(albumID: id)
            case .artist(let id): ArtistDetailView(artistID: id)
            case .albumArtists(let id): AlbumArtistsView(albumID: id)
            case .playlist(let id): PlaylistDetailView(playlistID: id)
            case .allSongs: AllSongsView()
            case .allAlbums: AllAlbumsView()
            case .allArtists: AllArtistsView()
            case .allPlaylists: AllPlaylistsView()
            case .offline: OfflineLibraryView()
            case .sources: SourcesView()
            case .settings: SettingsView()
            case .fixMetadata: FixMetadataView()
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
    /// When set, the subtitle becomes a tappable link (e.g. album → artist).
    var subtitleRoute: LibraryRoute? = nil
    var meta: String
    var playAction: () -> Void
    var shuffleAction: () -> Void

    @ViewBuilder private var subtitleLabel: some View {
        Text(subtitle)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DesignTokens.brandPrimary)
    }

    var body: some View {
        VStack(spacing: 16) {
            ArtworkView(url: artworkURL, artworkKey: artworkKey, glyph: glyph, cornerRadius: 12, maxPixel: 600)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.textPrimary)
                if let subtitleRoute {
                    NavigationLink(value: subtitleRoute) {
                        HStack(spacing: 3) {
                            subtitleLabel
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DesignTokens.brandPrimary.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    subtitleLabel
                }
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
                        subtitle: MetadataGrouping.albumDisplayArtist(from: albumTracks.map(\.artist)),
                        // Various-Artists album → a list of every performer; single
                        // artist → straight to their page.
                        subtitleRoute: model.creditedArtists(forAlbum: albumID).count > 1
                            ? .albumArtists(albumID) : .artist(first.artistID),
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
        .toolbar {
            if !albumTracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.metadataEditTarget = .album(albumID)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit album info")
                }
            }
        }
        .task { model.ensureAlbumArtwork(albumID) }
    }
}

// MARK: - Album artists (Various Artists picker)

/// Lists every distinct performer on an album so a "Various Artists" record (opera
/// cast, compilation) doesn't dead-end on whoever was first. Each row opens that
/// artist's page.
struct AlbumArtistsView: View {
    @Environment(AppModel.self) private var model
    var albumID: String

    private var artists: [Artist] { model.creditedArtists(forAlbum: albumID) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(artists) { artist in
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
                        .padding(.vertical, 8)
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
                if let name = model.artistName(artistID) ?? artistTracks.first?.artist {
                    VStack(spacing: 12) {
                        ArtworkView(url: model.artistImage(artistID), artworkKey: artistID, glyph: "music.mic", cornerRadius: 80, maxPixel: 400)
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
                                        SquareArtTileStatic(artworkKey: album.id, url: album.artworkURL, title: album.title, subtitle: "\(album.trackCount) songs")
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
        .navigationTitle(model.artistName(artistID) ?? "Artist")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artistID) { model.ensureArtistImage(artistID) }
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
    @Environment(\.dismiss) private var dismiss
    var playlistID: String
    @State private var showingRename = false
    @State private var renameText = ""

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
        .toolbar {
            if let playlist, !playlist.isLiveFolder {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { renameText = playlist.name; showingRename = true } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            model.deletePlaylist(playlist.id)
                            dismiss()
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") { model.renamePlaylist(playlistID, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - "All" list screens

enum SongSort: String, CaseIterable, Identifiable {
    case title = "Title"
    case recentlyAdded = "Recently Added"
    case mostPlayed = "Most Played"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .title: "textformat"
        case .recentlyAdded: "clock"
        case .mostPlayed: "flame"
        }
    }
    /// Alphabetical sorts keep the A-Z fast-scroll index; the others use a plain list.
    /// Browsing by artist lives in the Artists screen, not here.
    var isAlphabetical: Bool { self == .title }
}

struct AllSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var sort: SongSort = .title
    @State private var genreFilter: String? = nil
    @State private var genres: [String] = []

    private var songs: [Track] {
        var base = model.audioTracks
        if let genreFilter {
            base = base.filter { MetadataGrouping.canonicalGenre($0.genre) == genreFilter }
        }
        switch sort {
        case .title:
            return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            return base.sorted { ($0.modifiedAtEpoch ?? 0) > ($1.modifiedAtEpoch ?? 0) }
        case .mostPlayed:
            return base.sorted { model.autoCache.stat(for: $0.id).playCount > model.autoCache.stat(for: $1.id).playCount }
        }
    }

    var body: some View {
        let list = songs
        Group {
            if sort.isAlphabetical {
                let sections = LibraryIndex.sections(list) { $0.title }
                AlphabetIndexedScroll(sections: sections) {
                    header(list)
                } sectionContent: { section in
                    ForEach(section.items) { track in
                        TrackRowView(track: track, context: list)
                        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header(list)
                        ForEach(list) { track in
                            TrackRowView(track: track, context: list)
                            Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                        }
                    }
                    .padding(.horizontal, DesignTokens.phonePadding)
                    .padding(.bottom, 120)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Songs")
        .toolbar { sortMenu }
        .task { if genres.isEmpty { genres = model.availableGenres } }
    }

    @ViewBuilder private func header(_ list: [Track]) -> some View {
        PlayShuffleBar(
            play: { model.engine.setShuffle(false); model.engine.play(list) },
            shuffle: { model.engine.playShuffled(list) }
        )
        .disabled(list.isEmpty)
        .padding(.bottom, 6)
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SongSort.allCases) { option in
                        Label(option.rawValue, systemImage: option.systemImage).tag(option)
                    }
                }
                if !genres.isEmpty {
                    Divider()
                    Menu("Filter by Genre") {
                        Button("All Genres") { genreFilter = nil }
                        ForEach(genres, id: \.self) { genre in
                            Button {
                                genreFilter = (genreFilter == genre) ? nil : genre
                            } label: {
                                if genreFilter == genre {
                                    Label(genre, systemImage: "checkmark")
                                } else {
                                    Text(genre)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: genreFilter == nil ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
            }
        }
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

enum AlbumSort: String, CaseIterable, Identifiable {
    case title = "Title"
    case artist = "Artist"
    case recentlyAdded = "Recently Added"
    case year = "Year"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .title: "textformat"
        case .artist: "music.mic"
        case .recentlyAdded: "clock"
        case .year: "calendar"
        }
    }
    var isAlphabetical: Bool { self == .title || self == .artist }
}

struct AllAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var sort: AlbumSort = .title
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    /// Alphabetical ordering (used only when `sort.isAlphabetical`).
    private var albums: [Album] {
        if sort == .artist {
            return model.albums.sorted {
                let c = $0.artist.localizedStandardCompare($1.artist)
                return c == .orderedSame
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : c == .orderedAscending
            }
        }
        return model.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if sort.isAlphabetical {
                let sections = LibraryIndex.sections(albums) { sort == .artist ? $0.artist : $0.title }
                AlphabetIndexedScroll(sections: sections) { section in
                    grid(section.items)
                }
            } else {
                ScrollView {
                    grid(orderedAlbums)
                        .padding(.horizontal, DesignTokens.phonePadding)
                        .padding(.bottom, 120)
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(AlbumSort.allCases) { option in
                            Label(option.rawValue, systemImage: option.systemImage).tag(option)
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
    }

    /// Albums in the active non-alphabetical order (recently-added uses the
    /// model's date-ordered list; year sorts newest first).
    private var orderedAlbums: [Album] {
        switch sort {
        case .recentlyAdded: return model.recentlyAddedAlbums
        case .year: return model.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        default: return albums
        }
    }

    private func grid(_ items: [Album]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(items) { album in
                NavigationLink(value: LibraryRoute.album(album.id)) {
                    AlbumGridCellStatic(album: album)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AllArtistsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let sections = LibraryIndex.sections(model.artists) { $0.name }
        AlphabetIndexedScroll(sections: sections) { section in
            ForEach(section.items) { artist in
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
        .appScreenBackground()
        .navigationTitle("Artists")
    }
}

struct AllPlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNew = false
    @State private var newName = ""
    @State private var showingImporter = false
    @State private var importMessage: String?

    private static let m3uTypes: [UTType] = [
        UTType(filenameExtension: "m3u") ?? .plainText,
        UTType(filenameExtension: "m3u8") ?? .plainText,
        .plainText
    ]

    var body: some View {
        Group {
            if model.playlists.isEmpty {
                emptyState
            } else {
                listView
            }
        }
        .appScreenBackground()
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Playlist", systemImage: "plus") { newName = ""; showingNew = true }
                    Button("Import .m3u…", systemImage: "square.and.arrow.down") { showingImporter = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .alert("New Playlist", isPresented: $showingNew) {
            TextField("Name", text: $newName)
            Button("Create") { model.createPlaylist(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.m3uTypes) { result in
            if case .success(let url) = result {
                importMessage = model.importM3U(from: url) == nil ? "No tracks in that file matched your library." : nil
            }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text("No playlists yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text("Create one with the + button, or import a .m3u file.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
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
    @Environment(AppModel.self) private var model
    @Environment(\.libraryNavigate) private var libraryNavigate
    var album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: album.artworkURL, artworkKey: album.id, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
            Text(album.artist).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
        }
        .contextMenu { albumMenu }
    }

    @ViewBuilder private var albumMenu: some View {
        Button("Play", systemImage: "play.fill") { model.playAlbum(album.id) }
        Button("Play Next", systemImage: "text.insert") { model.playAlbumNext(album.id) }
        Button("Add to Queue", systemImage: "text.append") { model.addAlbumToQueue(album.id) }

        Divider()

        if model.canManageAlbumDownload(album.id) {
            if model.albumHasDownloads(album.id) {
                Button("Remove Download", systemImage: "trash") { model.removeAlbumDownloads(album.id) }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.downloadAlbum(album.id) }
            }
        }
        Button {
            model.toggleAlbumFavorite(album.id)
        } label: {
            let fav = model.isAlbumFavorite(album.id)
            Label(fav ? "Unfavorite" : "Favorite", systemImage: fav ? "star.fill" : "star")
        }

        if let libraryNavigate {
            Divider()
            Button("Go to Artist", systemImage: "music.mic") { libraryNavigate(.artist(album.artistID)) }
        }
    }
}

// MARK: - Metadata editor (track + album)

/// Modal metadata editor for a single track or a whole album. Presented from the
/// player menu, context menus, and the "Fix Metadata" review queue via
/// `model.metadataEditTarget`. Edits persist as non-destructive overrides that
/// survive a tag rescan (see AppModel.editTrackMetadata / LibraryService).
struct MetadataEditorView: View {
    @Environment(AppModel.self) private var model
    let target: MetadataEditTarget

    var body: some View {
        switch target {
        case .track(let id):
            if let track = model.track(id) {
                TrackMetadataForm(track: track)
            } else {
                unavailable
            }
        case .album(let id):
            if let album = model.albums.first(where: { $0.id == id }) {
                AlbumMetadataForm(album: album, initialGenre: model.tracks(forAlbum: id).first?.genre ?? "Unknown")
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        NavigationStack {
            ContentUnavailableView("Not Available", systemImage: "questionmark",
                                   description: Text("This item is no longer in your library."))
        }
    }
}

private struct TrackMetadataForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String

    init(track: Track) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MetadataField(label: "Title", text: $title)
                    MetadataField(label: "Artist", text: $artist)
                    MetadataField(label: "Album", text: $album)
                    MetadataField(label: "Genre", text: $genre)
                } footer: {
                    Text("Saved on this device only — your files on the server aren't changed. Your edits are kept when the library is rescanned.")
                }

                Section {
                    Button(role: .destructive) {
                        model.revertTrackMetadata(track.id)
                        dismiss()
                    } label: {
                        Label("Revert to File Tags", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editTrackMetadata(
                            track.id,
                            title: title.trimmingCharacters(in: .whitespaces),
                            artist: artist.trimmingCharacters(in: .whitespaces),
                            album: album.trimmingCharacters(in: .whitespaces),
                            genre: genre.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

private struct AlbumMetadataForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: Album
    @State private var albumTitle: String
    @State private var artist: String
    @State private var genre: String

    init(album: Album, initialGenre: String) {
        self.album = album
        _albumTitle = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _genre = State(initialValue: initialGenre)
    }

    private var canSave: Bool {
        !albumTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MetadataField(label: "Album", text: $albumTitle)
                    MetadataField(label: "Artist", text: $artist)
                    MetadataField(label: "Genre", text: $genre)
                } footer: {
                    Text("Applies to every track on this album. Saved on this device only — your files on the server aren't changed.")
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editAlbumMetadata(
                            album.id,
                            album: albumTitle.trimmingCharacters(in: .whitespaces),
                            artist: artist.trimmingCharacters(in: .whitespaces),
                            genre: genre.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

private struct MetadataField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            TextField(label, text: $text)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }
}

/// Review queue: tracks whose metadata likely needs a fix. Tapping a row opens the
/// track editor (presented at the app root via `model.metadataEditTarget`).
struct FixMetadataView: View {
    @Environment(AppModel.self) private var model
    @State private var fixing = false
    @State private var fixedCount: Int?

    var body: some View {
        let items = model.metadataNeedsAttention
        List {
            Section {
                Button {
                    guard !fixing else { return }
                    fixing = true
                    fixedCount = nil
                    Task {
                        let n = await model.autoFixMetadataFromFiles()
                        fixing = false
                        fixedCount = n
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(DesignTokens.brandPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-fix from file names & folders")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                            Text(autoFixSubtitle(itemCount: items.count))
                                .font(.caption)
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                        Spacer(minLength: 8)
                        if fixing { ProgressView().controlSize(.small) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(fixing || (items.isEmpty && fixedCount == nil))
            } footer: {
                Text("Fills only broken fields (missing artist, album that fell back to the source name, blank title) from the folder layout. Changes stay on this device and stay reversible per track.")
            }

            if items.isEmpty {
                Section {
                    ContentUnavailableView("All Clean", systemImage: "checkmark.seal",
                                           description: Text("No tracks look like they need a metadata fix."))
                }
            } else {
                Section {
                    ForEach(items) { track in
                        Button {
                            model.metadataEditTarget = .track(track.id)
                        } label: {
                            fixRow(track)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(items.count) need attention")
                }
            }
        }
        .navigationTitle("Fix Metadata")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func autoFixSubtitle(itemCount: Int) -> String {
        if fixing { return "Scanning file names and folders…" }
        if let fixedCount {
            return fixedCount == 0 ? "Nothing could be inferred from the files" : "Fixed \(fixedCount) tracks"
        }
        return itemCount == 0 ? "Nothing flagged right now" : "Try to fix all \(itemCount) automatically"
    }

    private func fixRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "pencil")
                .font(.footnote)
                .foregroundStyle(DesignTokens.brandPrimary)
        }
        .contentShape(Rectangle())
    }
}
