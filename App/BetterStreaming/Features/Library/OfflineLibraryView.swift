import SwiftUI

/// Offline surface inside Library (ask #3). Holds the Offline Mode toggle that
/// used to live in Settings, the auto-cache storage picture, and the list of
/// downloaded / auto-cached songs.
struct OfflineLibraryView: View {
    @Environment(AppModel.self) private var model

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case downloaded = "Downloaded"
        case autoCached = "Auto-cached"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all

    private var downloaded: [Track] { model.tracks.filter { $0.cacheState == .cached } }
    private var autoCached: [Track] { model.tracks.filter { $0.cacheState == .prefetched } }

    /// One unified, sorted list of everything available offline. The per-row
    /// availability glyph (download vs auto-cache) distinguishes them, so there's
    /// no need for two stacked sections.
    private var offlineTracks: [Track] {
        let base: [Track]
        switch filter {
        case .all: base = model.tracks.filter { $0.cacheState == .cached || $0.cacheState == .prefetched }
        case .downloaded: base = downloaded
        case .autoCached: base = autoCached
        }
        return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

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
                } else {
                    librarySection
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Offline")
        // Reconcile only updates the usage readout on a reachable pass; refresh
        // from disk on appear so it's real at launch and while offline too.
        .task { model.refreshAutoCacheUsage() }
    }

    @ViewBuilder
    private var librarySection: some View {
        // Only offer the filter when both kinds exist — otherwise it's noise.
        if !downloaded.isEmpty && !autoCached.isEmpty {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        let list = offlineTracks
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Available Offline", detail: "\(list.count) songs")
            ForEach(list) { track in
                TrackRowView(track: track, context: list)
                Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
            }
        }
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

}
