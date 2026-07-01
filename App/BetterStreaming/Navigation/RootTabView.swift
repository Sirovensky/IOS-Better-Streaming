import SwiftUI

struct RootTabView: View {
    @Environment(AppModel.self) private var model
    /// Live morph fraction (0 = mini bar, 1 = full screen); nil when settled. The
    /// player is ONE element whose glass surface grows from the mini-bar frame to
    /// fill the screen by this fraction — it fills up as you drag up and drains
    /// down as you drag down. See `MorphingPlayer`.
    @State private var dragFraction: CGFloat? = nil
    /// Selected tab index — drives the tab-switch selection haptic.
    @State private var selectedTab = 0
    #if DEBUG
    /// Sim-only: presents the source-share (QR) sheet for screenshotting (`-share`).
    @State private var debugShareConfig: SharedSourceConfig?
    #endif

    var body: some View {
        @Bindable var model = model

        GeometryReader { proxy in
            // Full screen including safe areas, so the player parks as the floating
            // bar at fraction 0 and fills the whole screen at 1.
            let W = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            let H = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let settled: CGFloat = model.isNowPlayingPresented ? 1 : 0
            let p = min(max(dragFraction ?? settled, 0), 1)

            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem { Label("Home", systemImage: "house.fill") }
                        .tag(0)

                    RadioView()
                        .tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                        .tag(1)

                    LibraryView()
                        .tabItem { Label("Library", systemImage: "square.stack.fill") }
                        .tag(2)

                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(3)
                }
                .tint(DesignTokens.brandPrimary)
                .sensoryFeedback(.selection, trigger: selectedTab)
            }
            // Pin the whole stack to the real screen bottom so the keyboard never
            // shoves the floating player up above it. Must live on the ZStack: the
            // player overlay positions itself by absolute geometry, but this also
            // keeps the tab content from reflowing under the keyboard oddly.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay {
                if model.engine.currentTrack != nil {
                    // The ONE player element. At p == 0 it is the mini bar; at p == 1
                    // it is the full Now Playing screen. Same glass, one surface.
                    MorphingPlayer(
                        p: p,
                        screenSize: CGSize(width: W, height: H),
                        safeTop: proxy.safeAreaInsets.top,
                        safeBottom: proxy.safeAreaInsets.bottom,
                        tint: Artwork.palette(for: model.engine.currentTrack?.albumID ?? "placeholder").top,
                        dragFraction: $dragFraction,
                        presented: $model.isNowPlayingPresented
                    )
                    .environment(model)
                    // Slide up from the bottom when a track first starts (only the
                    // bar is visible at p ≈ 0, so this reads as the bar appearing).
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Animate only the settled tap-open / chevron-close; a live drag already
            // moves `p` continuously. A springy spring gives the glass a liquid settle.
            .animation(dragFraction == nil ? PlayerMorph.settle : nil,
                       value: model.isNowPlayingPresented)
            .animation(.snappy(duration: 0.25), value: model.engine.currentTrack)
            // If the track vanishes mid-drag (queue cleared / source removed), the
            // gesture-holding surface is torn down and .onEnded never fires — reset
            // so the next track can't mount the player at a stale partial fraction.
            .onChange(of: model.engine.currentTrack == nil) { _, gone in
                // The settle's completion callback can't fire if the player is torn down
                // mid-collapse, so clear the settling flag here too — else the next
                // track's mini-bar would mount with its expand gesture permanently dead.
                if gone { dragFraction = nil; model.isNowPlayingPresented = false; model.isPlayerMorphSettling = false }
            }
        }
        // Keyboard-ignore must be on the GeometryReader itself, not just the inner
        // ZStack: the player overlay positions by `proxy.size.height`, and when the
        // Search keyboard opened, a keyboard-shrunk `proxy` floated the mini bar up
        // mid-screen. Ignoring it here keeps `proxy` full-screen so the bar stays
        // parked at the real bottom (tucked behind the keyboard while typing).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .fullScreenCover(isPresented: Binding(get: { model.needsOnboarding }, set: { _ in })) {
            OnboardingView()
                .environment(model)
        }
        // Metadata editor, presented at the root so it's reachable from the player,
        // context menus, and the Fix-Metadata review queue alike.
        .sheet(item: $model.metadataEditTarget) { target in
            MetadataEditorView(target: target)
                .environment(model)
        }
        #if DEBUG
        .sheet(item: $debugShareConfig) { config in
            SourceShareView(shared: config)
        }
        #endif
        .task {
            #if DEBUG
            // Simulator visual-iteration hook: with `-uiPreview`, bypass onboarding,
            // seed a mock track, let Home render, then open the player so the glass
            // can be screenshotted on the Simulator. No-op without the launch arg.
            guard CommandLine.arguments.contains("-uiPreview") else { return }
            // `-resume` seeds a RESTORABLE (restored-but-not-resumed) session so the
            // Home "Continue where you left off" hero can be screenshotted on Home.
            let restorable = CommandLine.arguments.contains("-resume")
            // `-settings` screenshots Settings with no mini-player covering the
            // bottom rows, so skip seeding a now-playing track in that case.
            if !CommandLine.arguments.contains("-settings") {
                model.debugPreviewNowPlaying(restorable: restorable)
            }
            // Let the REAL capture run on open (layer.render works on the sim now), so
            // the glass is validated over real app content — not a synthetic backdrop.
            try? await Task.sleep(for: .seconds(2.0))
            // `-resume`/`-bar` stay collapsed (Home); `-mid` holds the morph partway;
            // default opens the full player.
            if restorable || CommandLine.arguments.contains("-bar") || CommandLine.arguments.contains("-settings") {
                // leave collapsed on Home — show the hero / floating mini bar / a
                // pushed Settings screen (the `-settings` deep-link, see HomeView)
            } else if CommandLine.arguments.contains("-mid") {
                dragFraction = 0.62
            } else if CommandLine.arguments.contains("-share") {
                debugShareConfig = SharedSourceConfig(
                    name: "Home NAS", proto: "SMB", host: "192.168.1.50", port: 445,
                    share: "Music", username: "pavel", domain: nil, rootPath: "/Music/Library"
                )
            } else if CommandLine.arguments.contains("-editinfo") {
                // Wait for the saved library to load, then open the metadata editor
                // on a track that needs a fix so it can be screenshotted on the sim.
                for _ in 0..<24 where model.audioTracks.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let id = model.metadataNeedsAttention.first?.id ?? model.audioTracks.first?.id {
                    model.metadataEditTarget = .track(id)
                }
            } else {
                model.isNowPlayingPresented = true
            }
            #endif
        }
    }
}

/// Shared morph tuning so the bar↔full transition feels uniform everywhere it is
/// driven from (tap-open, drag-release, chevron-close).
enum PlayerMorph {
    /// Viscous liquid settle: a LIQUID surface has surface tension + viscosity — it
    /// glides to rest and NEVER bounces. `dampingFraction: 1.0` is critical damping
    /// (zero overshoot), and because `withAnimation` injects no gesture velocity the
    /// motion starts from rest, so it cannot overshoot in either direction — the
    /// drain settles smoothly instead of snapping back. Knob: `response` = settle
    /// speed (raise → slower / more viscous). Never drop `dampingFraction` below 1.0
    /// or it will bounce.
    static let settle: Animation = .spring(response: 0.26, dampingFraction: 1.0)
}
