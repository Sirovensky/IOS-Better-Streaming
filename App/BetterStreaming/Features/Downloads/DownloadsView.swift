import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    DownloadsSummary(
                        offlineMode: environment.offlineMode,
                        playableCount: environment.playableOfflineCount,
                        activeCount: environment.activeDownloadCount,
                        toggleOfflineMode: environment.toggleOfflineMode
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Offline Packs", detail: "Manual, folder, playlist, smart pack, and queue reasons stay visible")

                        ForEach(environment.downloads) { pack in
                            DownloadPackCard(pack: pack)
                        }
                    }

                    PrivacyDonationNote()
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Downloads")
            .toolbar {
                Button {
                    environment.toggleOfflineMode()
                } label: {
                    Label("Offline Mode", systemImage: environment.offlineMode ? "wifi.slash" : "wifi")
                }
            }
        }
    }
}

private struct DownloadsSummary: View {
    var offlineMode: Bool
    var playableCount: Int
    var activeCount: Int
    var toggleOfflineMode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offline Confidence")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("Remote-only items stay visible but dim when Offline Mode is on.")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { offlineMode }, set: { _ in toggleOfflineMode() }))
                    .labelsHidden()
                    .tint(DesignTokens.brandPrimary)
            }

            HStack(spacing: 10) {
                MetricTile(value: "32.6 GB", label: "Storage used", systemImage: "internaldrive")
                MetricTile(value: playableCount.formatted(), label: "Playable offline", systemImage: "checkmark.circle.fill")
                MetricTile(value: activeCount.formatted(), label: "Active", systemImage: "arrow.down.circle")
            }

            ProgressBar(value: 0.58, tint: DesignTokens.brandPrimary)
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

private struct DownloadPackCard: View {
    var pack: DownloadPack

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MediaArtwork(symbol: "arrow.down.circle", status: pack.status, size: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.title)
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text(pack.detail)
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        StatusPill(label: pack.reason, systemImage: "pin.fill", tint: DesignTokens.brandPrimary)
                        CacheStatusPill(status: pack.status)
                    }
                }

                Spacer(minLength: 8)
                Text(pack.bytes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .multilineTextAlignment(.trailing)
            }

            ProgressBar(value: pack.progress, tint: progressTint)

            HStack {
                Button("Retry", systemImage: "arrow.clockwise") {}
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(pack.status != .failed && pack.status != .stale)

                Button("Cancel", systemImage: "xmark") {}
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(pack.status != .downloading && pack.status != .queued)
            }
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private var progressTint: Color {
        switch pack.status {
        case .cached, .prefetched:
            DesignTokens.success
        case .downloading, .queued, .remoteOnly:
            DesignTokens.connectionTeal
        case .stale:
            DesignTokens.warning
        case .missingSource, .failed:
            DesignTokens.error
        }
    }
}

private struct PrivacyDonationNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(label: "Private by design", systemImage: "lock.shield", tint: DesignTokens.connectionTeal)
            Text("Downloads, source credentials, and playback history stay on this device. Donations can support protocol testing and maintenance, but source setup, recursive playback, offline playback, privacy, and security fixes stay core app features.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceRaised)
    }
}

#Preview {
    DownloadsView()
        .environmentObject(AppEnvironment())
}
