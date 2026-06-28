import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    sourcesSection
                    playbackSection
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Settings")
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Sources",
                detail: "\(environment.sources.count) configured"
            )

            VStack(spacing: 0) {
                NavigationLink {
                    SourceSetupView()
                } label: {
                    settingsRow(
                        title: "Add SMB source",
                        detail: "Runs a real SMB connection test before saving",
                        icon: "externaldrive.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Divider().overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))

                NavigationLink {
                    SourcesView()
                } label: {
                    settingsRow(
                        title: "Manage sources",
                        detail: environment.sources.isEmpty ? "No sources saved yet" : "View saved sources and remove entries",
                        icon: "server.rack"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Playback")

            Toggle(isOn: offlineModeBinding) {
                settingsRow(
                    title: "Offline Mode",
                    detail: "Only cached, prefetched, or stale cached tracks can start playback",
                    icon: environment.offlineMode ? "wifi.slash" : "wifi"
                )
            }
            .tint(DesignTokens.connectionTeal)
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    private func settingsRow(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
    }

    private var offlineModeBinding: Binding<Bool> {
        Binding(
            get: { environment.offlineMode },
            set: { newValue in
                if environment.offlineMode != newValue {
                    environment.toggleOfflineMode()
                }
            }
        )
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppEnvironment())
}
