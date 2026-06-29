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
                        if !model.playlists.isEmpty { madeForYouRail }
                        statsSection
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
            .libraryNavigation($path)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
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
            Text(model.isBootstrapping || model.isLoadingSavedLibrary ? "Loading your library…" : (model.hasSources ? "Library is empty" : "Add your music"))
                .font(.title2.weight(.bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text(model.isBootstrapping || model.isLoadingSavedLibrary
                 ? "Opening your saved library on this device."
                 : (model.hasSources
                    ? "Use Sources to scan or refresh your server."
                    : "Connect your NAS or server to start listening to your own library."))
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
            if !model.hasSources && !model.isBootstrapping {
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
                        Text(model.engine.isPlaying ? "NOW PLAYING" : "PICK UP WHERE YOU LEFT OFF")
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
        guard !model.recentlyPlayed.isEmpty else { return [] }
        return model.audioTracks
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

    // MARK: Your library — fun read-only stats (no actions / setup)

    @ViewBuilder
    private var statsSection: some View {
        let stats = model.libraryStats
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your Library")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                statTile(value: "\(stats.songs)", label: "Songs", glyph: "music.note")
                statTile(value: "\(stats.albums)", label: "Albums", glyph: "square.stack")
                statTile(value: "\(stats.artists)", label: "Artists", glyph: "music.mic")
                if stats.totalDurationSeconds > 0 {
                    statTile(value: Self.durationLabel(stats.totalDurationSeconds), label: "In your library", glyph: "clock")
                }
                if stats.totalPlays > 0 {
                    statTile(value: "\(stats.totalPlays)", label: "Plays", glyph: "play.circle")
                }
                if stats.listenedSeconds > 0 {
                    statTile(value: Self.durationLabel(stats.listenedSeconds), label: "Listened", glyph: "headphones")
                }
                if stats.favorites > 0 {
                    statTile(value: "\(stats.favorites)", label: "Favorites", glyph: "star.fill")
                }
            }
        }
    }

    private func statTile(value: String, label: String, glyph: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.title3)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    /// "12 hr", "1.2k hr", "45 min" — friendly, compact.
    private static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let hours = seconds / 3600
        if hours >= 1 {
            if hours >= 1000 { return String(format: "%.1fk hr", hours / 1000) }
            return "\(Int(hours.rounded())) hr"
        }
        return "\(Int((seconds / 60).rounded())) min"
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
                    Text("· \(source.trackCount) songs")
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
