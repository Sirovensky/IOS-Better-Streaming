import SwiftUI

struct RadioView: View {
    @Environment(AppModel.self) private var model

    private struct GenreStation: Identifiable {
        var name: String
        var trackCount: Int
        var id: String { name }
    }

    private var artistStations: [Artist] {
        Array(model.artists.filter { $0.trackCount > 1 }.prefix(12))
    }

    private var genreStations: [GenreStation] {
        model.genreStations().map { GenreStation(name: $0.name, trackCount: $0.trackCount) }
    }

    private var seedTracks: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for track in model.recentlyPlayed + model.audioTracks {
            guard seen.insert(track.id).inserted else { continue }
            result.append(track)
            if result.count == 12 { break }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.audioTracks.isEmpty {
                        emptyState
                    } else {
                        startStation
                        if !artistStations.isEmpty { artistSection }
                        if !genreStations.isEmpty { genreSection }
                        if !seedTracks.isEmpty { similarSection }
                    }
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 120)
            }
            .appScreenBackground()
            .navigationTitle("Radio")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 52))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text("No stations yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text("Scan a source to build stations from your own library.")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var artistSection: some View {
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

    private var genreSection: some View {
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

    private var similarSection: some View {
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
