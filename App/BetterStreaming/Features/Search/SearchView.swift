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
    @State private var matchingArtists: [Artist] = []
    @State private var searchTask: Task<Void, Never>?
    // The trimmed query the current `results` were computed for. During the 150ms
    // debounce this lags the live query, so we only show "No Results" once it catches
    // up — otherwise an empty in-flight state flashed the no-results view mid-typing.
    @State private var searchedQuery = ""

    /// Auto-focus the keyboard only on the FIRST time Search appears this app run —
    /// not every time the tab is re-entered or a pushed result is popped.
    @MainActor private static var didAutoFocusThisSession = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trimmedQuery.isEmpty {
                    browse
                } else if !results.isEmpty || !matchingAlbums.isEmpty || !matchingArtists.isEmpty {
                    resultsList
                } else if searchedQuery == trimmedQuery {
                    ContentUnavailableView.search(text: query)
                } else {
                    // Debounce in flight for a new query: hold blank rather than flash
                    // "No Results" before runSearch has actually looked.
                    Color.clear
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
            // Open the keyboard the first time Search appears this session only.
            guard !Self.didAutoFocusThisSession else { return }
            Self.didAutoFocusThisSession = true
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
            matchingArtists = []
            searchedQuery = ""
            return
        }
        results = model.searchResults(q)
        matchingArtists = model.artistResults(q)
        matchingAlbums = model.albums.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.artist.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        searchedQuery = trimmed
    }

    /// Recents are recorded on submit; also record when the user acts on a result, so
    /// a query typed-then-tapped (never Return-pressed) still lands in Recent.
    private func recordOnResultTap() {
        model.recordSearch(query)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !matchingArtists.isEmpty {
                    SectionHeader(title: "Artists")
                    LazyVStack(spacing: 0) {
                        ForEach(matchingArtists) { artist in
                            NavigationLink(value: LibraryRoute.artist(artist.id)) {
                                HStack(spacing: 12) {
                                    ArtworkView(url: model.artistImage(artist.id), artworkKey: artist.id, glyph: "music.mic", cornerRadius: 26)
                                        .frame(width: 52, height: 52)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                                        Text("\(artist.albumCount) albums · \(artist.trackCount) songs")
                                            .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(DesignTokens.textTertiary)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { recordOnResultTap() })
                            Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                        }
                    }
                }
                if !matchingAlbums.isEmpty {
                    SectionHeader(title: "Albums")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
                        ForEach(matchingAlbums) { album in
                            NavigationLink(value: LibraryRoute.album(album.id)) {
                                AlbumGridCellStatic(album: album)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { recordOnResultTap() })
                        }
                    }
                }
                if !results.isEmpty {
                    SectionHeader(title: "Songs")
                    LazyVStack(spacing: 0) {
                        ForEach(results) { track in
                            TrackRowView(track: track, context: results)
                                .simultaneousGesture(TapGesture().onEnded { recordOnResultTap() })
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
                            Button { path.append(.genre(genre)) } label: {
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
