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
    @State private var sort: SongSort = .title

    /// One unified, sorted list of everything available offline. The per-row
    /// availability glyph (download vs auto-cache) distinguishes them, so there's
    /// no need for two stacked sections.
    private func offlineTracks(downloaded: [Track], autoCached: [Track]) -> [Track] {
        let base: [Track]
        switch filter {
        case .all: base = downloaded + autoCached
        case .downloaded: base = downloaded
        case .autoCached: base = autoCached
        }
        // The filter picker only shows while both buckets are non-empty. If the chosen
        // bucket empties out from under it (e.g. a download removed mid-view), fall back
        // to everything so real offline tracks aren't hidden behind a stale filter.
        let resolved = base.isEmpty ? (downloaded + autoCached) : base
        switch sort {
        case .title:
            return resolved.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            return resolved.sorted { ($0.modifiedAtEpoch ?? 0) > ($1.modifiedAtEpoch ?? 0) }
        case .mostPlayed:
            return resolved.sorted { model.autoCache.stat(for: $0.id).playCount > model.autoCache.stat(for: $1.id).playCount }
        }
    }

    var body: some View {
        // Compute the offline buckets ONCE per body pass. They fed several computed
        // properties before, so the full filter+sort re-ran on every render — a
        // continuous churn while downloads were in flight.
        let downloaded = model.tracks.filter { $0.cacheState == .cached }
        let autoCached = model.tracks.filter { $0.cacheState == .prefetched }
        let list = offlineTracks(downloaded: downloaded, autoCached: autoCached)
        return ScrollView {
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
                    librarySection(downloaded: downloaded, autoCached: autoCached, list: list)
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .toggleStyle(EvensongToggleStyle())
        .navigationTitle("Offline")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SongSort.allCases) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        // Reconcile only updates the usage readout on a reachable pass; refresh
        // from disk on appear so it's real at launch and while offline too.
        .task { model.refreshAutoCacheUsage() }
    }

    @ViewBuilder
    private func librarySection(downloaded: [Track], autoCached: [Track], list: [Track]) -> some View {
        // Only offer the filter when both kinds exist — otherwise it's noise.
        if !downloaded.isEmpty && !autoCached.isEmpty {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
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
                if model.isBatchDownloading {
                    Button { model.cancelBatchDownloads() } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DesignTokens.brandPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop downloads")
                }
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
