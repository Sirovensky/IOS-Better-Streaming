import SwiftUI

struct FoldersView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                FolderHeader(
                    primaryFolder: environment.folders[1],
                    playAction: { environment.playFolder(environment.folders[1], recursive: false, shuffled: false) },
                    shuffleAction: { environment.playFolder(environment.folders[1], recursive: false, shuffled: true) },
                    recursiveAction: { environment.playFolder(environment.folders[1], recursive: true, shuffled: false) }
                )

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Folders", detail: "Current-folder actions start before subtree traversal completes")

                    VStack(spacing: 0) {
                        ForEach(environment.folders) { folder in
                            FolderRow(folder: folder) {
                                environment.playFolder(folder, recursive: false, shuffled: false)
                            } shuffleAction: {
                                environment.playFolder(folder, recursive: false, shuffled: true)
                            } recursiveAction: {
                                environment.playFolder(folder, recursive: true, shuffled: false)
                            }

                            if folder.id != environment.folders.last?.id {
                                Divider()
                                    .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .surfaceCard(fill: DesignTokens.surfaceCard)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Files in Long Hall", detail: "Remote-only rows stay visible; unavailable rows are labeled")

                    VStack(spacing: 0) {
                        ForEach(environment.tracks.filter { $0.folderPath.contains("Long Hall") || $0.folderPath.contains("Late Folder") }) { track in
                            TrackRow(track: track) {
                                environment.play(track)
                            }

                            if track.id != environment.tracks.filter({ $0.folderPath.contains("Long Hall") || $0.folderPath.contains("Late Folder") }).last?.id {
                                Divider()
                                    .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .surfaceCard(fill: DesignTokens.surfaceCard)
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 24)
        }
        .appScreenBackground()
        .navigationTitle("Folders")
        .toolbar {
            Menu {
                Button("Play Current Folder", systemImage: "play.fill") {
                    environment.playFolder(environment.folders[1], recursive: false, shuffled: false)
                }
                Button("Shuffle Current Folder", systemImage: "shuffle") {
                    environment.playFolder(environment.folders[1], recursive: false, shuffled: true)
                }
                Button("Play Recursively - 127 found so far", systemImage: "folder.badge.plus") {
                    environment.playFolder(environment.folders[1], recursive: true, shuffled: false)
                }
                Button("Download Recursively", systemImage: "arrow.down.circle") {}
            } label: {
                Label("Folder Actions", systemImage: "ellipsis.circle")
            }
        }
    }
}

private struct FolderHeader: View {
    var primaryFolder: LibraryFolder
    var playAction: () -> Void
    var shuffleAction: () -> Void
    var recursiveAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(primaryFolder.path.middleTruncated(maxLength: 56))
                    .font(.caption.monospaced())
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(primaryFolder.name)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    StatusPill(label: primaryFolder.sourceName, systemImage: "server.rack", tint: DesignTokens.connectionTeal)
                    StatusPill(label: primaryFolder.scanState, systemImage: "arrow.triangle.2.circlepath", tint: DesignTokens.connectionTeal)
                    CacheStatusPill(status: primaryFolder.cacheStatus)
                }
            }

            HStack(spacing: 10) {
                Button(action: playAction) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())

                Button(action: shuffleAction) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }

            Button(action: recursiveAction) {
                HStack {
                    Label("Play Recursively", systemImage: "folder.badge.plus")
                    Spacer()
                    Text(primaryFolder.recursiveCount)
                        .font(.caption.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

#Preview {
    NavigationStack {
        FoldersView()
            .environmentObject(AppEnvironment())
    }
}
