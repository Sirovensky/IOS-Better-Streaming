import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    categoryList
                    Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
                    recentlyAdded
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 120)
            }
            .appScreenBackground()
            .navigationTitle("Library")
            // No SMB setup buttons here (moved to Sources / Home settings).
            .libraryDestinations()
            .libraryNavigation($path)
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            categoryRow("Playlists", icon: "music.note.list", route: .allPlaylists)
            divider
            categoryRow("Favourites", icon: "star", route: .favorites)
            divider
            categoryRow("Artists", icon: "music.mic", route: .allArtists)
            divider
            categoryRow("Albums", icon: "square.stack", route: .allAlbums)
            divider
            categoryRow("Songs", icon: "music.note", route: .allSongs)
            divider
            categoryRow("Offline", icon: "arrow.down.circle", route: .offline)
        }
    }

    private func categoryRow(_ title: String, icon: String, route: LibraryRoute) -> some View {
        NavigationLink(value: route) {
            LibraryCategoryRow(title: title, systemImage: icon)
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08))
    }

    private var recentlyAdded: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recently Added")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
                ForEach(model.recentlyAddedAlbums) { album in
                    NavigationLink(value: LibraryRoute.album(album.id)) {
                        AlbumGridCellStatic(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
