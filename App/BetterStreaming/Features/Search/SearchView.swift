import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var query = ""
    @State private var filter: SearchFilter = .all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Picker("Search filter", selection: $filter) {
                        ForEach(SearchFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(
                            title: query.isEmpty ? "Recent Context" : "Matches",
                            detail: "Results show title, filename, folder path, and cache state"
                        )

                        let results = filteredResults
                        if results.isEmpty {
                            EmptySearchCard(query: query)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(results) { result in
                                    SearchResultRow(result: result)

                                    if result.id != results.last?.id {
                                        Divider()
                                            .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .surfaceCard(fill: DesignTokens.surfaceCard)
                        }
                    }
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 24)
            }
            .appScreenBackground()
            .searchable(text: $query, prompt: "Songs, folders, albums, files")
            .navigationTitle("Search")
            .toolbar {
                Menu {
                    Button("Playable Only", systemImage: "checkmark.circle") {}
                    Button("Reveal Paths", systemImage: "folder") {}
                    Button("Offline Mode", systemImage: environment.offlineMode ? "wifi.slash" : "wifi") {
                        environment.toggleOfflineMode()
                    }
                } label: {
                    Label("Search Options", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private var filteredResults: [SearchResult] {
        environment.searchResults(for: query).filter { result in
            switch filter {
            case .all:
                true
            case .cached:
                result.status == .cached || result.status == .prefetched || result.status == .stale
            case .folders:
                result.systemImage == "folder"
            }
        }
    }
}

private enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case cached = "Cached"
    case folders = "Folders"

    var id: String { rawValue }
}

private struct SearchResultRow: View {
    var result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(symbol: result.systemImage, status: result.status, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                Text(result.context.middleTruncated(maxLength: 54))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            CacheStatusPill(status: result.status)
                .fixedSize()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title), \(result.status.label)")
    }
}

private struct EmptySearchCard: View {
    var query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(label: "No match", systemImage: "magnifyingglass", tint: DesignTokens.textSecondary)
            Text("No indexed title, filename, album, artist, or folder path matches \(query).")
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

#Preview {
    SearchView()
        .environmentObject(AppEnvironment())
}
