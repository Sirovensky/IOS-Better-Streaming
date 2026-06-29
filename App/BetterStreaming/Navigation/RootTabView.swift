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
                }
            }
            // Pin the whole stack to the real screen bottom so the keyboard never
            // shoves the floating mini bar up above it. Must live on the ZStack,
            // not the bar: the bar is bottom-aligned, so when the keyboard shrank
            // the stack's safe area the bar reflowed up regardless of its own
            // .ignoresSafeArea. The search field sits at the top, so the list
            // under the keyboard just scrolls as usual.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay {
                if model.engine.currentTrack != nil {
                    // Bloom OUT of the mini bar instead of sliding the whole sheet
                    // up from the screen bottom: scale + corner-radius + opacity all
                    // grow from a low anchor (where the bar floats), giving a
                    // liquid-glass zoom that still tracks the finger via `p`.
                    let anchorY = min(max(1 - 86 / max(proxy.size.height, 1), 0), 1)
                    let miniAnchor = UnitPoint(x: 0.5, y: anchorY)
                    NowPlayingView(
                        dragFraction: $dragFraction,
                        presented: $model.isNowPlayingPresented,
                        containerHeight: height
                    )
                    .environment(model)
                    .ignoresSafeArea()
                    .scaleEffect(0.6 + 0.4 * p, anchor: miniAnchor)
                    .clipShape(RoundedRectangle(cornerRadius: (1 - p) * 30, style: .continuous))
                    .opacity(Double(min(p * 1.3, 1)))
                    .allowsHitTesting(p > 0.5)
                }
            }
            // Animate only the settled tap-open/close; a live drag already moves
            // the offset continuously via `dragFraction`, so it needs no animation.
            .animation(dragFraction == nil ? .interpolatingSpring(stiffness: 320, damping: 30) : nil,
                       value: model.isNowPlayingPresented)
            .animation(.snappy(duration: 0.25), value: model.engine.currentTrack)
            // If the track vanishes mid-drag (queue cleared / source removed), the
            // gesture-holding bar is torn down and .onEnded never fires — reset so
            // the next track can't mount the player at a stale partial fraction.
            .onChange(of: model.engine.currentTrack == nil) { _, gone in
                if gone { dragFraction = nil; model.isNowPlayingPresented = false }
            }
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
