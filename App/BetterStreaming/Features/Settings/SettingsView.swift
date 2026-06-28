import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var autoCache = model.autoCache

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                autoCacheSection(autoCache)
                sourcesSection
                aboutSection
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Settings")
    }

    // MARK: Auto-cache (ask #7)

    private func autoCacheSection(_ autoCache: AutoCacheController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Auto-cache", detail: "Keep the music you play most ready offline")

            VStack(spacing: 0) {
                Toggle(isOn: $autoCache.isEnabled) {
                    settingsLabel("Automatic downloads", "Quietly cache your most-played songs",
                                  icon: "bolt.badge.automatic")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                HStack(spacing: 12) {
                    settingsLabel("Maximum storage", "Auto-cache won’t grow past this",
                                  icon: "internaldrive")
                    Spacer()
                    Picker("Maximum storage", selection: $autoCache.budgetBytes) {
                        ForEach(AutoCacheController.budgetPresets, id: \.self) { bytes in
                            Text(AutoCacheController.byteLabel(bytes)).tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .tint(DesignTokens.brandPrimary)
                }
                .padding(12)

                rowDivider

                Toggle(isOn: $autoCache.wifiOnly) {
                    settingsLabel("Wi-Fi only", "Don’t auto-cache on cellular", icon: "wifi")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                Toggle(isOn: $autoCache.protectFavorites) {
                    settingsLabel("Always keep favourites", "Favourites are never auto-evicted", icon: "star")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)

            HStack {
                Text(autoCache.lastReconcileSummary)
                    .font(.caption).foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button("Clear history", role: .destructive) { autoCache.resetStats() }
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sources")
            VStack(spacing: 0) {
                NavigationLink { SourceSetupView() } label: {
                    settingsLabel("Add music source", "Connect an SMB share or server", icon: "externaldrive.badge.plus")
                        .padding(12)
                }
                .buttonStyle(.plain)
                rowDivider
                NavigationLink(value: LibraryRoute.sources) {
                    settingsLabel("Manage sources", model.sources.isEmpty ? "No sources yet" : "\(model.sources.count) configured",
                                  icon: "server.rack")
                        .padding(12)
                }
                .buttonStyle(.plain)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")
            VStack(alignment: .leading, spacing: 6) {
                Text("Better Streaming")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Text("Your own music library from your NAS or server. Open source, private by design — nothing leaves your devices and your network.")
                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    // MARK: Helpers

    private func settingsLabel(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Text(detail).font(.caption).foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08)).padding(.leading, 52)
    }
}
