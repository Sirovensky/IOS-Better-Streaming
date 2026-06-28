import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sources")
                                .font(.largeTitle.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                            Text("Library roots, health, scan state, and repair actions.")
                                .font(.subheadline)
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                        Spacer()
                        NavigationLink {
                            SourceSetupView()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                    }

                    ForEach(environment.sources) { source in
                        SourceCard(source: source)
                    }

                    DiagnosticsPrivacyCard()
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SourceCard: View {
    var source: LibrarySource

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(DesignTokens.connectionTeal)
                    .frame(width: 44, height: 44)
                    .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name)
                        .font(.headline)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(source.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        SourceHealthPill(health: source.health)
                        StatusPill(label: source.recommendation, systemImage: "speedometer", tint: recommendationTint)
                    }
                }

                Spacer(minLength: 8)

                Menu {
                    Button("Rescan Roots", systemImage: "arrow.triangle.2.circlepath") {}
                    Button("Update Credentials", systemImage: "key") {}
                    Button("Repair Path", systemImage: "wrench.and.screwdriver") {}
                    Button("Copy Redacted Diagnostics", systemImage: "doc.on.doc") {}
                    Button("Remove Source", systemImage: "trash", role: .destructive) {}
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 44, height: 44)
                }
            }

            HStack(spacing: 10) {
                MetricTile(value: source.lastScan, label: "Last scan", systemImage: "clock.arrow.circlepath")
                MetricTile(value: source.speed, label: "Read sample", systemImage: "gauge.with.dots.needle.67percent")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(source.indexedItems)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignTokens.textTertiary)

                ForEach(source.roots) { root in
                    HStack(spacing: 10) {
                        Image(systemName: root.kind == "Video" ? "film" : "folder")
                            .foregroundStyle(DesignTokens.brandPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                            Text(root.path.middleTruncated(maxLength: 52))
                                .font(.caption.monospaced())
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                        Spacer()
                        StatusPill(label: root.kind, systemImage: "tag", tint: DesignTokens.textSecondary)
                    }
                    .padding(10)
                    .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(14)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(source.health == .online ? DesignTokens.connectionTeal : DesignTokens.warning)
                .frame(width: 3)
                .clipShape(Capsule())
                .padding(.vertical, 12)
        }
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private var recommendationTint: Color {
        source.health == .online ? DesignTokens.connectionTeal : DesignTokens.warning
    }
}

private struct DiagnosticsPrivacyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(label: "Redacted diagnostics", systemImage: "lock.shield", tint: DesignTokens.connectionTeal)
            Text("Exports should describe reachability, scan counts, speed samples, and source state without raw credentials, usernames, tokens, or credential-bearing URLs.")
                .font(.footnote)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceRaised)
    }
}

#Preview {
    SourcesView()
        .environmentObject(AppEnvironment())
}
