import SwiftUI

private extension View {
    /// Focus the search field where supported (iOS 18+); no-op on older OS.
    @ViewBuilder
    func autoFocusSearch(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18.0, *) {
            self.searchFocused(focused)
        } else {
            self
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var path: [LibraryRoute] = []
    @FocusState private var searchFocused: Bool

    // Filtered results are cached in state and recomputed ONLY when the query
    // changes (debounced) — never in `body`. Re-running the O(N) filter over the
    // whole library on every render (each 0.5s playback tick, each scroll frame)
    // was the search-scroll lag.
    @State private var results: [Track] = []
    @State private var matchingAlbums: [Album] = []
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trimmedQuery.isEmpty {
                    browse
                } else if results.isEmpty && matchingAlbums.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultsList
                }
            }
            .appScreenBackground()
            .navigationTitle("Search")
            .libraryDestinations()
            .libraryNavigation($path)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums, folders")
        .autoFocusSearch($searchFocused)
        .onChange(of: query) { _, q in scheduleSearch(q) }
        .onSubmit(of: .search) {
            searchTask?.cancel()
            runSearch(query)
            model.recordSearch(query)
        }
        .task {
            // Open the keyboard immediately when Search appears.
            try? await Task.sleep(nanoseconds: 350_000_000)
            searchFocused = true
        }
    }

    /// Debounce so a fast typist doesn't trigger a filter per keystroke.
    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            runSearch(q)
        }
    }

    private func runSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            matchingAlbums = []
            return
        }
        results = model.searchResults(q)
        matchingAlbums = model.albums.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.artist.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !matchingAlbums.isEmpty {
                    SectionHeader(title: "Albums")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
                        ForEach(matchingAlbums) { album in
                            NavigationLink(value: LibraryRoute.album(album.id)) {
                                AlbumGridCellStatic(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.isEmpty {
                    SectionHeader(title: "Songs")
                    LazyVStack(spacing: 0) {
                        ForEach(results) { track in
                            TrackRowView(track: track, context: results)
                            Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                        }
                    }
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
    }

    private var browse: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !model.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionHeader(title: "Recent")
                            Spacer()
                            Button("Clear") { model.clearRecentSearches() }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.brandPrimary)
                        }
                        ForEach(model.recentSearches, id: \.self) { term in
                            Button { query = term } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.footnote)
                                        .foregroundStyle(DesignTokens.textSecondary)
                                    Text(term)
                                        .font(.subheadline)
                                        .foregroundStyle(DesignTokens.textPrimary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                        }
                    }
                }

                if !model.recentlyPlayed.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Recently Played")
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(model.recentlyPlayed.prefix(10)) { track in
                                    SquareArtTile(artworkKey: track.albumID, url: track.artworkURL,
                                                  title: track.title, subtitle: track.artist) {
                                        path.append(.album(track.albumID))
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Browse")
                    let genres = model.availableGenres
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(genres, id: \.self) { genre in
                            Button { query = genre } label: {
                                HStack {
                                    Text(genre).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                                    Spacer()
                                    Image(systemName: "music.quarternote.3").foregroundStyle(DesignTokens.brandPrimary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .surfaceCard(fill: DesignTokens.surfaceCard)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
    }
}
