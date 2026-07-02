import SwiftUI

/// View-local memo for a revision-keyed track list. A plain class held in `@State`
/// (like DetailViews' SectionCache): populating it inside `body` doesn't invalidate
/// the view, so the O(n) map+filter+sort runs once per library revision, not once
/// per body pass.
private final class TrackRevisionMemo {
    private var rev: Int?
    private(set) var tracks: [Track] = []

    func resolve(rev: Int, build: () -> [Track]) {
        if self.rev == rev { return }
        tracks = build()
        self.rev = rev
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LibraryRoute] = []
    @State private var heavyRotationCache = TrackRevisionMemo()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if model.hasLibrary {
                        heroSection
                        if !model.recentlyPlayed.isEmpty { recentlyPlayedRail }
                        heavyRotationRail
                        topThisMonthRail
                        buriedTreasureRail
                        onThisDayRail
                        haveNotHeardRail
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
            .task {
                #if DEBUG
                // Sim deep-link: `-settings` pushes Settings (with ReplayGain on so
                // the album-gain row is visible) for screenshotting. No-op otherwise.
                guard CommandLine.arguments.contains("-settings") else { return }
                model.engine.enhancements.replayGainEnabled = true
                if path.isEmpty { path = [.settings] }
                #endif
            }
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

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 40)
            if model.isScanning && !(model.isBootstrapping || model.isLoadingSavedLibrary) {
                // The very first scan is running — show live progress instead of a stale
                // "empty / use Sources" prompt the user can't act on yet.
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning your library…")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                Text(model.sources.first?.lastScanLabel ?? "Reading your music…")
                    .font(.subheadline)
                    .foregroundStyle(DesignTokens.textSecondary)
            } else {
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
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hero — pick up where you left off

    @ViewBuilder
    private var heroSection: some View {
        // Only the genuine "continue" state: a session was restored and not yet resumed.
        // Once it is resumed (or anything else starts playing) the mini-player is the
        // now-playing surface, so this big card would just duplicate it. See QUEUE/IDEAS.
        if model.engine.hasRestorableSession, let track = model.engine.currentTrack {
            Button {
                model.engine.resume()            // resolves the item + seeks to the saved position
                model.isNowPlayingPresented = true
            } label: {
                HStack(spacing: 16) {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 12)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CONTINUE WHERE YOU LEFT OFF")
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
                        if model.engine.elapsed > 1 {
                            Text("Resume at \(Self.timeLabel(model.engine.elapsed))")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
                .padding(14)
                .surfaceCard(fill: DesignTokens.surfaceCard)
            }
            .buttonStyle(.plain)
            // One coherent VoiceOver action instead of five fragments.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Continue \(track.title) by \(track.artist)")
            .accessibilityHint(model.engine.elapsed > 1 ? "Resumes at \(Self.timeLabel(model.engine.elapsed))" : "Resumes playback")
            .accessibilityAddTraits(.isButton)
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Recently played

    private var recentlyPlayedRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently Played", actionTitle: "All") {
                path.append(.trackList(title: "Recently Played", ids: model.recentlyPlayed.map(\.id)))
            }
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
        let _ = heavyRotationCache.resolve(rev: model.libraryRevision, build: computeHeavyRotation)
        let top = heavyRotationCache.tracks
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Heavy Rotation", detail: "The songs you keep coming back to",
                              actionTitle: "All") {
                    path.append(.trackList(title: "Heavy Rotation", ids: top.map(\.id)))
                }
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

    private func computeHeavyRotation() -> [Track] {
        guard !model.recentlyPlayed.isEmpty else { return [] }
        return model.audioTracks
            .map { ($0, model.autoCache.score(for: $0.id)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
    }

    // MARK: Rediscovery shelves

    @ViewBuilder
    private var topThisMonthRail: some View {
        trackRail(title: "Top This Month", detail: "Your most-played this month", tracks: model.topThisMonth)
    }

    @ViewBuilder
    private var buriedTreasureRail: some View {
        trackRail(title: "Buried Treasure", detail: "Loved once, gone quiet", tracks: model.buriedTreasure)
    }

    @ViewBuilder
    private var haveNotHeardRail: some View {
        trackRail(title: "Haven't Heard Yet", detail: "In your library, never played", tracks: model.haveNotHeard)
    }

    @ViewBuilder
    private func trackRail(title: String, detail: String, tracks: [Track]) -> some View {
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title, detail: detail)
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(tracks) { track in
                            SquareArtTile(
                                artworkKey: track.albumID,
                                url: track.artworkURL,
                                title: track.title,
                                subtitle: track.artist,
                                size: 140
                            ) {
                                model.play(track, in: tracks)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var onThisDayRail: some View {
        let albums = model.onThisDayAlbums
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "On This Day", detail: "Added to your library years ago")
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(albums) { album in
                            SquareArtTile(
                                artworkKey: album.id,
                                url: album.artworkURL,
                                title: album.title,
                                subtitle: album.artist,
                                size: 140
                            ) {
                                path.append(.album(album.id))
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
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
                // Count tiles navigate into the matching library list; the derived-stat
                // tiles below (duration / plays / listened) are read-only.
                navStatTile(value: "\(stats.songs)", label: "Songs", glyph: "music.note", route: .allSongs)
                navStatTile(value: "\(stats.albums)", label: "Albums", glyph: "square.stack", route: .allAlbums)
                navStatTile(value: "\(stats.artists)", label: "Artists", glyph: "music.mic", route: .allArtists)
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
                    navStatTile(value: "\(stats.favorites)", label: "Favorites", glyph: "star.fill", route: .favorites)
                }
            }
        }
    }

    /// A tappable count tile: opens the matching library list. The chevron + button
    /// trait mark it apart from the read-only stat tiles.
    private func navStatTile(value: String, label: String, glyph: String, route: LibraryRoute) -> some View {
        Button { path.append(route) } label: {
            statTileBody(value: value, label: label, glyph: glyph, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
        .accessibilityHint("Opens \(label)")
        .accessibilityAddTraits(.isButton)
    }

    private func statTile(value: String, label: String, glyph: String) -> some View {
        statTileBody(value: value, label: label, glyph: glyph, showsChevron: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(value) \(label)")
    }

    private func statTileBody(value: String, label: String, glyph: String, showsChevron: Bool) -> some View {
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
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
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
