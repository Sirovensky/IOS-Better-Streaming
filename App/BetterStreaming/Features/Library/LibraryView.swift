import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var mode: LibraryMode = .songs

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    SourceStatusStrip(sources: environment.sources, activeDownloads: environment.activeDownloadCount)

                    ContinueListeningCard(
                        state: environment.nowPlaying,
                        queueCount: environment.queue.count,
                        toggleAction: environment.togglePlayback
                    )

                    Picker("Library mode", selection: $mode) {
                        ForEach(LibraryMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    modeContent
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        Label("Source Health", systemImage: "externaldrive.connected.to.line.below")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SourceSetupView()
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .songs:
            SongsSection(tracks: environment.tracks.filter { $0.kind == .audio }, playAction: environment.play)
        case .albums:
            AlbumsSection(albums: environment.albums)
        case .artists:
            ArtistsSection(artists: environment.artists)
        case .genres:
            GenresSection(genres: environment.genres)
        case .folders:
            FoldersPreviewSection(
                folders: environment.folders,
                playAction: { environment.playFolder($0, recursive: false, shuffled: false) },
                shuffleAction: { environment.playFolder($0, recursive: false, shuffled: true) },
                recursiveAction: { environment.playFolder($0, recursive: true, shuffled: false) }
            )
        case .videos:
            SongsSection(tracks: environment.tracks.filter { $0.kind == .video }, playAction: environment.play)
        }
    }
}

private struct SourceStatusStrip: View {
    var sources: [LibrarySource]
    var activeDownloads: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Source Status",
                detail: "\(sources.filter { $0.health == .online }.count) online - \(activeDownloads) active transfer"
            )

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SourceHealthPill(health: source.health)
                                Spacer(minLength: 0)
                                Text(source.speed)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DesignTokens.textTertiary)
                            }

                            Text(source.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                                .lineLimit(1)

                            Text(source.detail)
                                .font(.caption)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(1)

                            Text(source.indexedItems)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(DesignTokens.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(width: 232, alignment: .leading)
                        .padding(12)
                        .surfaceCard(fill: DesignTokens.surfaceCard)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ContinueListeningCard: View {
    var state: NowPlayingState
    var queueCount: Int
    var toggleAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(symbol: state.artworkSymbol, status: state.status, size: 64)

            VStack(alignment: .leading, spacing: 5) {
                Text("Continue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text("\(state.artist) - \(state.sourceName)")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    CacheStatusPill(status: state.status)
                    Text("\(queueCount) in queue")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }

            Spacer(minLength: 8)

            Button(action: toggleAction) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
        }
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

private struct SongsSection: View {
    var tracks: [MediaTrack]
    var playAction: (MediaTrack) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: tracks.first?.kind == .video ? "Videos" : "Songs",
                detail: "Sort: Title - Filter: All, Cached, Remote, Missing"
            )

            VStack(spacing: 0) {
                ForEach(tracks) { track in
                    TrackRow(track: track) {
                        playAction(track)
                    }
                    if track.id != tracks.last?.id {
                        Divider()
                            .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }
}

private struct AlbumsSection: View {
    var albums: [MediaAlbum]

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Albums", detail: "Artwork-first, metadata can backfill later")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 9) {
                        MediaArtwork(symbol: album.symbol, status: album.cacheStatus, size: 132)
                            .frame(maxWidth: .infinity)
                        Text(album.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .lineLimit(1)
                        Text(album.artist)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                        HStack {
                            CacheStatusPill(status: album.cacheStatus)
                            Spacer()
                            Text("\(album.trackCount) tracks")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                    }
                    .padding(10)
                    .surfaceCard(fill: DesignTokens.surfaceCard)
                }
            }
        }
    }
}

private struct ArtistsSection: View {
    var artists: [MediaArtist]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Artists", detail: "Top songs, albums, folders, and offline state")

            VStack(spacing: 0) {
                ForEach(artists) { artist in
                    HStack(spacing: 12) {
                        MediaArtwork(symbol: "person.crop.square", status: artist.cacheStatus, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artist.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                            Text(artist.detail)
                                .font(.caption)
                                .foregroundStyle(DesignTokens.textSecondary)
                            Text(artist.topPath.middleTruncated(maxLength: 44))
                                .font(.caption2.monospaced())
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                        Spacer()
                        CacheStatusPill(status: artist.cacheStatus)
                    }
                    .padding(.vertical, 10)

                    if artist.id != artists.last?.id {
                        Divider()
                            .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }
}

private struct GenresSection: View {
    var genres: [MediaGenre]

    private let columns = [
        GridItem(.adaptive(minimum: 154), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Genres", detail: "Used by Autoplay to stay local and similar")

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(genres) { genre in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            MediaArtwork(symbol: "tag.fill", status: genre.cacheStatus, size: 44)
                            Spacer()
                            CacheStatusPill(status: genre.cacheStatus)
                        }
                        Text(genre.name)
                            .font(.headline)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .lineLimit(1)
                        Text(genre.detail)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(2)
                            .frame(minHeight: 34, alignment: .topLeading)
                        Text("\(genre.trackCount) tracks")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    .padding(12)
                    .surfaceCard(fill: DesignTokens.surfaceCard)
                }
            }
        }
    }
}

private struct FoldersPreviewSection: View {
    var folders: [LibraryFolder]
    var playAction: (LibraryFolder) -> Void
    var shuffleAction: (LibraryFolder) -> Void
    var recursiveAction: (LibraryFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Folders", detail: "Playable before deep scans finish")
                Spacer()
                NavigationLink("Open") {
                    FoldersView()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(DesignTokens.brandPrimary)
            }

            VStack(spacing: 0) {
                ForEach(folders) { folder in
                    FolderRow(folder: folder) {
                        playAction(folder)
                    } shuffleAction: {
                        shuffleAction(folder)
                    } recursiveAction: {
                        recursiveAction(folder)
                    }

                    if folder.id != folders.last?.id {
                        Divider()
                            .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(AppEnvironment())
}
