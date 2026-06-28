import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .bottom) {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }

                LibraryView()
                    .tabItem { Label("Library", systemImage: "square.stack.fill") }

                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
            }
            .tint(DesignTokens.brandPrimary)

            if model.engine.currentTrack != nil {
                MiniPlayerBar()
                    .padding(.horizontal, 8)
                    // Float just above the standard tab bar.
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.engine.currentTrack)
        .fullScreenCover(isPresented: $model.isNowPlayingPresented) {
            NowPlayingView()
                .environment(model)
        }
        .fullScreenCover(isPresented: Binding(get: { model.needsOnboarding }, set: { _ in })) {
            OnboardingView()
                .environment(model)
        }
    }
}
