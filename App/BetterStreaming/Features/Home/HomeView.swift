import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    statsGrid
                    serverSection
                    activePlaybackSection
                    quickActions
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }

                        NavigationLink {
                            SourceSetupView()
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var statsGrid: some View {
        let summary = environment.librarySummary
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(value: "\(summary.sourceCount)", label: "servers", systemImage: "externaldrive.connected.to.line.below")
            MetricTile(value: "\(summary.trackCount)", label: "songs", systemImage: "music.note.list")
            MetricTile(value: "\(summary.folderCount)", label: "folders", systemImage: "folder")
            MetricTile(value: "\(environment.playableOfflineCount)", label: "offline ready", systemImage: "checkmark.circle")
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Servers",
                detail: "\(environment.sources.filter { $0.health == .online }.count) online - \(environment.activeDownloadCount) active transfer"
            )

            if environment.sources.isEmpty {
                NavigationLink {
                    SourceSetupView()
                } label: {
                    AppEmptyState(
                        title: "No sources added",
                        detail: "Add an SMB server to start indexing and playing your library.",
                        systemImage: "externaldrive.badge.plus"
                    )
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 10) {
                    ForEach(environment.sources) { source in
                    NavigationLink {
                        SourcesView()
                    } label: {
                        HStack(spacing: 12) {
                            MediaArtwork(symbol: "externaldrive.connected.to.line.below", status: source.health.cacheStatus, size: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(source.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(DesignTokens.textPrimary)
                                    Spacer()
                                    SourceHealthPill(health: source.health)
                                }
                                Text(source.detail)
                                    .font(.caption)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .lineLimit(1)
                                HStack {
                                    Text(source.indexedItems)
                                    Spacer()
                                    Text(source.speed)
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(DesignTokens.textTertiary)
                            }
                        }
                        .padding(12)
                        .surfaceCard(fill: DesignTokens.surfaceCard)
                    }
                    .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var activePlaybackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Now Playing", detail: "Current queue and cache state")

            HStack(spacing: 12) {
                MediaArtwork(symbol: environment.nowPlaying.artworkSymbol, status: environment.nowPlaying.status, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(environment.nowPlaying.title)
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text("\(environment.nowPlaying.artist) - \(environment.nowPlaying.album)")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        CacheStatusPill(status: environment.nowPlaying.status)
                        Text("\(environment.queue.count) queued")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
                Spacer()
                Button(action: environment.togglePlayback) {
                    Image(systemName: environment.nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
            .padding(12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quick Actions")

            HStack(spacing: 10) {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())

                NavigationLink {
                    SearchView()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }
        }
    }
}

private extension SourceHealth {
    var cacheStatus: CacheStatus {
        switch self {
        case .online:
            return .cached
        case .asleep, .degraded:
            return .stale
        case .authFailed, .localNetworkBlocked, .unreachable:
            return .missingSource
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
}
