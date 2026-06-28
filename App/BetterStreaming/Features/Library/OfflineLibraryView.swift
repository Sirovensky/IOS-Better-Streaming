import SwiftUI

/// Offline surface inside Library (ask #3). Holds the Offline Mode toggle that
/// used to live in Settings, the auto-cache storage picture, and the list of
/// downloaded / auto-cached songs.
struct OfflineLibraryView: View {
    @Environment(AppModel.self) private var model

    private var downloaded: [Track] { model.tracks.filter { $0.cacheState == .cached } }
    private var autoCached: [Track] { model.tracks.filter { $0.cacheState == .prefetched } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                offlineModeCard
                storageCard
                if downloaded.isEmpty && autoCached.isEmpty {
                    AppEmptyState(
                        title: "Nothing offline yet",
                        detail: "Download songs or albums to keep them on this device. Auto-cache also keeps your most-played music ready without the source.",
                        systemImage: "arrow.down.circle"
                    )
                }
                if !downloaded.isEmpty { downloadedSection }
                if !autoCached.isEmpty { autoCachedSection }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Offline")
    }

    private var offlineModeCard: some View {
        @Bindable var bindableModel = model

        return VStack(spacing: 0) {
            Toggle(isOn: $bindableModel.offlineMode) {
                HStack(spacing: 12) {
                    Image(systemName: model.offlineMode ? "wifi.slash" : "wifi")
                        .foregroundStyle(DesignTokens.brandPrimary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline Mode").font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                        Text("Only play downloaded or cached songs. Remote-only songs are dimmed.")
                            .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(DesignTokens.connectionTeal)
            .padding(12)
        }
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private var storageCard: some View {
        let used = model.autoCache.autoCachedBytes
        let budget = model.autoCache.budgetBytes
        let fraction = budget > 0 ? min(Double(used) / Double(budget), 1) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Auto-cache storage").font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Spacer()
                Text("\(AutoCacheController.byteLabel(used)) / \(AutoCacheController.byteLabel(budget))")
                    .font(.caption.monospacedDigit()).foregroundStyle(DesignTokens.textSecondary)
            }
            ProgressBar(value: fraction, tint: DesignTokens.connectionTeal)
            Text(model.autoCache.isEnabled ? model.autoCache.lastReconcileSummary : "Auto-cache is off — turn it on in Settings.")
                .font(.caption).foregroundStyle(DesignTokens.textTertiary)
        }
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Downloaded", detail: "\(downloaded.count) songs kept by you")
            ForEach(downloaded) { track in
                TrackRowView(track: track, context: downloaded)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
            }
        }
    }

    private var autoCachedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Auto-cached", detail: "Kept ready from your listening")
            ForEach(autoCached) { track in
                TrackRowView(track: track, context: autoCached)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
            }
        }
    }
}
