import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var model
    /// Live expand fraction (0 = mini, 1 = full); nil when settled. Drives the
    /// finger-tracking player transition: the full player is offset by
    /// `(1 - fraction) · height`, so it tracks the finger up from / down to the bar.
    @State private var dragFraction: CGFloat? = nil

    var body: some View {
        @Bindable var model = model

        GeometryReader { proxy in
            // Full travel distance: screen height + safe-area insets, so the player
            // parks fully off-screen at fraction 0 and fills the screen at 1.
            let height = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let settled: CGFloat = model.isNowPlayingPresented ? 1 : 0
            let p = min(max(dragFraction ?? settled, 0), 1)

            ZStack(alignment: .bottom) {
                TabView {
                    HomeView()
                        .tabItem { Label("Home", systemImage: "house.fill") }

                    RadioView()
                        .tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }

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
                        // Fade the bar out as the full player rises over it.
                        .opacity(1 - Double(min(p * 1.6, 1)))
                        .allowsHitTesting(p < 0.02)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // Interactive up-drag-to-expand (tracks the finger live).
                        // `.gesture` (not high-priority) so the bar's own buttons
                        // still win taps; the drag only starts after real movement.
                        .gesture(expandDrag(height: height))
                        // Keep the bar pinned above the tab bar — don't let the
                        // keyboard shove it up (it used to float over the keyboard
                        // with the tab-bar padding still attached).
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .overlay {
                if model.engine.currentTrack != nil {
                    NowPlayingView(
                        dragFraction: $dragFraction,
                        presented: $model.isNowPlayingPresented,
                        containerHeight: height
                    )
                    .environment(model)
                    .offset(y: (1 - p) * height)
                    .opacity(p < 0.001 ? 0 : 1)
                    .allowsHitTesting(p > 0.5)
                    .ignoresSafeArea()
                }
            }
            // Animate only the settled tap-open/close; a live drag already moves
            // the offset continuously via `dragFraction`, so it needs no animation.
            .animation(dragFraction == nil ? .interpolatingSpring(stiffness: 320, damping: 30) : nil,
                       value: model.isNowPlayingPresented)
            .animation(.snappy(duration: 0.25), value: model.engine.currentTrack)
        }
        .fullScreenCover(isPresented: Binding(get: { model.needsOnboarding }, set: { _ in })) {
            OnboardingView()
                .environment(model)
        }
    }

    /// Up-drag on the mini bar raises the expand fraction live; release snaps to
    /// full or mini by drag distance + fling velocity.
    private func expandDrag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only react to upward movement; let downward fall through.
                guard value.translation.height < 0 else { return }
                let f = -value.translation.height / max(height, 1)
                dragFraction = min(max(f, 0), 1)
            }
            .onEnded { value in
                let f = min(max(-value.translation.height / max(height, 1), 0), 1)
                let flungUp = value.predictedEndTranslation.height < -220
                let open = f > 0.25 || flungUp
                withAnimation(.interpolatingSpring(stiffness: 320, damping: 30)) {
                    model.isNowPlayingPresented = open
                    dragFraction = nil
                }
            }
    }
}
