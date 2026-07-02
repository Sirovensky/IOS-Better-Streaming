import SwiftUI

struct RadioView: View {
    @Environment(AppModel.self) private var model

    private struct GenreStation: Identifiable {
        var name: String
        var trackCount: Int
        var id: String { name }
    }

    private var artistStations: [Artist] {
        let eligible = model.artists.filter { $0.trackCount > 1 }
        // Rank by summed play count across each artist's tracks so the most-listened
        // artists lead; fall back to the alphabetical order when there's no history.
        let ranked = eligible.map { artist -> (artist: Artist, plays: Int) in
            let plays = model.tracks(forArtist: artist.id)
                .reduce(0) { $0 + model.autoCache.stat(for: $1.id).playCount }
            return (artist, plays)
        }
        guard ranked.contains(where: { $0.plays > 0 }) else {
            return Array(eligible.prefix(12))
        }
        return ranked.sorted { $0.plays > $1.plays }.prefix(12).map(\.artist)
    }

    private var genreStations: [GenreStation] {
        model.genreStations().map { GenreStation(name: $0.name, trackCount: $0.trackCount) }
    }

    private var seedTracks: [Track] {
        // Diversity-constrained seeds: one per album, at most two per artist.
        // Without this a fresh library (no play history) padded the list from
        // the head of the library array — 12 rows of one artist's albums.
        var seenIDs = Set<String>()
        var seenAlbums = Set<String>()
        var perArtist: [String: Int] = [:]
        var result: [Track] = []
        func consider(_ track: Track) {
            guard result.count < 12,
                  seenIDs.insert(track.id).inserted,
                  seenAlbums.insert(track.albumID).inserted,
                  perArtist[track.artistID, default: 0] < 2 else { return }
            perArtist[track.artistID, default: 0] += 1
            result.append(track)
        }
        model.recentlyPlayed.forEach(consider)
        if result.count < 12 {
            // Pad by a per-session-stable hash order — a cheap spread across the
            // whole library instead of its alphabetical head.
            for track in model.audioTracks.sorted(by: { $0.id.hashValue < $1.id.hashValue }) {
                consider(track)
                if result.count == 12 { break }
            }
        }
        return result
    }

    var body: some View {
        // Each of these walks the whole library; the section builders referenced them
        // again, so they ran several times per render. Resolve each ONCE per body pass.
        let artistStations = self.artistStations
        let genreStations = self.genreStations
        let seedTracks = self.seedTracks
        return NavigationStack {
            Group {
                if model.audioTracks.isEmpty {
                    // Outside the ScrollView: Spacers collapse in a scroll view, so an
                    // in-scroll empty state renders top-aligned instead of centered.
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            startStation
                            if !artistStations.isEmpty { artistSection(artistStations) }
                            if !genreStations.isEmpty { genreSection(genreStations) }
                            if !seedTracks.isEmpty { similarSection(seedTracks) }
                        }
                        .padding(DesignTokens.phonePadding)
                        .padding(.bottom, 120)
                    }
                }
            }
            .appScreenBackground()
            .navigationTitle("Radio")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 52))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text("No stations yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text("Scan a source to build stations from your own library.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startStation: some View {
        Button {
            model.shuffleAll()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(DesignTokens.brandPrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Library Radio")
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("\(model.audioTracks.count) songs")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                Image(systemName: "shuffle")
                    .font(.headline)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(14)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
        .buttonStyle(.plain)
    }

    private func artistSection(_ artistStations: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Artist Stations")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(artistStations) { artist in
                        Button {
                            model.playArtistRadio(artist.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ArtworkView(url: artist.artworkURL, artworkKey: artist.id, glyph: "music.mic", cornerRadius: 10)
                                    .frame(width: 144, height: 144)
                                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                                Text(artist.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .lineLimit(1)
                                Text("\(artist.trackCount) songs")
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 144)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func genreSection(_ genreStations: [GenreStation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Genre Stations")
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(genreStations) { station in
                        Button {
                            model.playGenreRadio(station.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(DesignTokens.surfaceRaised)
                                    Image(systemName: "waveform")
                                        .font(.system(size: 34, weight: .semibold))
                                        .foregroundStyle(DesignTokens.brandPrimary)
                                }
                                .frame(width: 132, height: 92)
                                Text(station.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .lineLimit(1)
                                Text("\(station.trackCount) songs")
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func similarSection(_ seedTracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Similar Stations")
            ForEach(seedTracks) { track in
                Button {
                    model.playSimilarRadio(seed: track)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 8)
                            .frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DesignTokens.brandPrimary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
            }
        }
    }
}
