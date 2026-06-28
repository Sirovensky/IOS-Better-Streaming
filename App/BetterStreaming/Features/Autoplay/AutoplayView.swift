import SwiftUI

struct AutoplayView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedSeedID: UUID?
    @State private var cachedOnly = true

    private var seedTrack: MediaTrack? {
        let audioTracks = environment.tracks.filter { $0.kind == .audio }
        if let selectedSeedID, let selected = audioTracks.first(where: { $0.id == selectedSeedID }) {
            return selected
        }
        return audioTracks.first
    }

    private var recommendations: [MediaTrack] {
        environment.autoplayCandidates(seed: seedTrack)
            .filter { cachedOnly ? ($0.cacheStatus == .cached || $0.cacheStatus == .prefetched || $0.cacheStatus == .stale) : true }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    seedSection
                    rulesSection
                    queueSection
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Autoplay")
        }
    }

    private var seedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Seed Song", detail: "Pick a local track; matching stays inside indexed metadata")

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(environment.tracks.filter { $0.kind == .audio }) { track in
                        Button {
                            selectedSeedID = track.id
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    MediaArtwork(symbol: "music.note", status: track.cacheStatus, size: 44)
                                    Spacer()
                                    if seedTrack?.id == track.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(DesignTokens.connectionTeal)
                                    }
                                }
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .lineLimit(1)
                                Text("\(track.artist) - \(track.genre)")
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 174, alignment: .leading)
                            .padding(12)
                            .surfaceCard(
                                fill: seedTrack?.id == track.id ? DesignTokens.surfaceRaised : DesignTokens.surfaceCard,
                                borderOpacity: seedTrack?.id == track.id ? DesignTokens.borderStrongOpacity : DesignTokens.borderSubtleOpacity
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Matching Rules", detail: "Genre first, then artist, album, and offline readiness")

            VStack(spacing: 0) {
                ruleRow("Genre", value: seedTrack?.genre ?? "Any", icon: "tag.fill")
                Divider().overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                ruleRow("Artist proximity", value: seedTrack?.artist ?? "Any", icon: "person.wave.2")
                Divider().overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                Toggle(isOn: $cachedOnly) {
                    Label("Prefer cached/offline tracks", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                .tint(DesignTokens.connectionTeal)
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    private func ruleRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .foregroundStyle(DesignTokens.brandPrimary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 12)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Next Up", detail: "\(recommendations.count) similar local matches")

            VStack(spacing: 0) {
                ForEach(recommendations) { track in
                    TrackRow(track: track) {
                        environment.play(track)
                    }
                    if track.id != recommendations.last?.id {
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
    AutoplayView()
        .environmentObject(AppEnvironment())
}
