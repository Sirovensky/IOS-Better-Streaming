import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if model.hasLibrary {
                        heroSection
                        if !model.recentlyPlayed.isEmpty { recentlyPlayedRail }
                        heavyRotationRail
                        madeForYouRail
                        recentlyAddedGrid
                        sourceThread
                    } else {
                        emptyState
                    }
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 120)
            }
            .appScreenBackground()
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: LibraryRoute.settings) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .libraryDestinations()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Late night"
        }
    }

    // MARK: Empty state (no library yet)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: "music.note.house")
                .font(.system(size: 52))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text(model.hasSources ? "Scanning your library…" : "Add your music")
                .font(.title2.weight(.bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text(model.hasSources
                 ? "Your songs will appear here as the scan finds them. Folders are playable before it finishes."
                 : "Connect your NAS or server to start listening to your own library.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
            if !model.hasSources {
                NavigationLink(value: LibraryRoute.sources) {
                    Label("Add a source", systemImage: "externaldrive.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hero — pick up where you left off

    @ViewBuilder
    private var heroSection: some View {
        if let track = model.engine.currentTrack ?? model.recentlyPlayed.first ?? model.audioTracks.first {
            Button {
                if model.engine.currentTrack == nil {
                    model.play(track, in: model.tracks(forAlbum: track.albumID))
                }
                model.isNowPlayingPresented = true
            } label: {
                HStack(spacing: 16) {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 12)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.engine.currentTrack == nil ? "PICK UP WHERE YOU LEFT OFF" : "NOW PLAYING")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(DesignTokens.brandPrimary)
                        Text(track.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: model.engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
                .padding(14)
                .surfaceCard(fill: DesignTokens.surfaceCard)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Recently played

    private var recentlyPlayedRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently Played")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(model.recentlyPlayed.prefix(12)) { track in
                        SquareArtTile(
                            artworkKey: track.albumID,
                            url: track.artworkURL,
                            title: track.title,
                            subtitle: track.artist
                        ) {
                            path.append(.album(track.albumID))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Heavy rotation (signature — driven by play counts)

    @ViewBuilder
    private var heavyRotationRail: some View {
        let top = heavyRotation
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Heavy Rotation", detail: "The songs you keep coming back to")
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(top) { track in
                            SquareArtTile(
                                artworkKey: track.albumID,
                                url: track.artworkURL,
                                title: track.title,
                                subtitle: "\(model.autoCache.stat(for: track.id).playCount) plays",
                                size: 140
                            ) {
                                model.play(track, in: top)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var heavyRotation: [Track] {
        model.audioTracks
            .map { ($0, model.autoCache.score(for: $0.id)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
    }

    // MARK: Made for you

    private var madeForYouRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Made for You", actionTitle: "All") { path.append(.allPlaylists) }
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(model.playlists) { playlist in
                        SquareArtTile(
                            artworkKey: playlist.id,
                            url: playlist.artworkURLs.first,
                            title: playlist.name,
                            subtitle: playlist.subtitle,
                            glyph: playlist.isLiveFolder ? "folder.fill" : "music.note.list"
                        ) {
                            path.append(.playlist(playlist.id))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Recently added

    private var recentlyAddedGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently Added", actionTitle: "All") { path.append(.allAlbums) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
                ForEach(model.recentlyAddedAlbums) { album in
                    Button { path.append(.album(album.id)) } label: {
                        AlbumGridCellStatic(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Quiet source thread (not a dashboard)

    @ViewBuilder
    private var sourceThread: some View {
        if let source = model.sources.first {
            Button { path.append(.sources) } label: {
                HStack(spacing: 10) {
                    Image(systemName: source.health.systemImage)
                        .foregroundStyle(source.health.tint)
                    Text(source.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("· \(model.offlineTracks.count) ready offline")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Spacer()
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
