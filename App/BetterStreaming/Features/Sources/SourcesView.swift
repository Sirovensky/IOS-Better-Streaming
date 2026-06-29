import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.sources.isEmpty {
                    NavigationLink { SourceSetupView() } label: {
                        AppEmptyState(
                            title: "No sources yet",
                            detail: "Add an SMB, WebDAV, FTP, or SFTP server to start building your library.",
                            systemImage: "externaldrive.badge.plus"
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(model.sources) { source in
                        sourceCard(source)
                    }
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SourceSetupView() } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func sourceCard(_ source: LibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: source.proto.glyph)
                    .font(.title3)
                    .foregroundStyle(DesignTokens.brandPrimary)
                    .frame(width: 44, height: 44)
                    .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.headline).foregroundStyle(DesignTokens.textPrimary).lineLimit(1)
                    Text(source.detail).font(.caption).foregroundStyle(DesignTokens.textSecondary).lineLimit(1)
                }
                Spacer()
                SourceHealthPill(health: source.health)
            }

            HStack {
                metric("\(source.trackCount)", "songs")
                Divider().frame(height: 28).overlay(DesignTokens.borderSubtle.opacity(0.1))
                metric("\(source.folderCount)", "folders")
                Divider().frame(height: 28).overlay(DesignTokens.borderSubtle.opacity(0.1))
                metric(source.sizeLabel, "on server")
            }

            HStack {
                Text(source.lastScanLabel).font(.caption).foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button {
                    Task { await model.rescan(source.id) }
                } label: {
                    Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .disabled(model.isScanning)
                Menu {
                    Button("Rescan", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.rescan(source.id) }
                    }
                    Button("Remove source", systemImage: "trash", role: .destructive) {
                        model.removeSource(source.id)
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(DesignTokens.textSecondary).frame(width: 30, height: 30)
                }
            }
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(DesignTokens.textPrimary)
            Text(label).font(.caption2).foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
