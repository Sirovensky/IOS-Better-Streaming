import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            AutoplayView()
                .tabItem {
                    Label("Autoplay", systemImage: "infinity")
                }

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
        .tint(DesignTokens.brandPrimary)
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppEnvironment())
}
