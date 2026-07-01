import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(AppModel.self) private var model
    /// Live morph fraction (0 = mini bar, 1 = full screen); nil when settled. The
    /// player is ONE element whose glass surface grows from the mini-bar frame to
    /// fill the screen by this fraction — it fills up as you drag up and drains
    /// down as you drag down. See `MorphingPlayer`.
    @State private var dragFraction: CGFloat? = nil
    /// Strength (in points) of the strong backdrop refraction applied to the app
    /// behind the player at FULL open. Fades in only after the morph settles (so the
    /// glass already covers the screen — no un-glassed strip shows) and fades out
    /// immediately on collapse. 0 while collapsed → the effect is a no-op passthrough.
    @State private var refractStrength: CGFloat = 0
    /// A frozen snapshot of the app behind the player, captured when it opens. The
    /// refraction shader runs on THIS rasterizable image — never the live UIKit-backed
    /// TabView, which can't be rasterized into a layer and would render as SwiftUI's
    /// red "unrenderable" placeholder. nil ⇒ fall back to plain clear glass over the
    /// real backdrop (subtler refraction, but never broken).
    @State private var backdropImage: UIImage?
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
            }
            // NOTE: do NOT apply the refraction shader to the TabView — a UIKit-backed
            // TabView cannot be rasterized for a layerEffect and renders as the red
            // "unrenderable" placeholder. The refraction runs on a snapshot Image
            // inside the player overlay instead (see `backdropImage` + MorphingPlayer).
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
                        backdrop: $backdropImage,
                        refractStrength: refractStrength,
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
                if gone { dragFraction = nil; model.isNowPlayingPresented = false }
            }
            // (Frosted glass samples the live backdrop itself — no snapshot capture or
            // refraction fade needed anymore.)
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
                refractStrength = RefractionStrength.full
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

/// Backdrop refraction tuning. Calm, edge-weighted Liquid Glass: keep the center
/// readable and let the rim do the optical work. Per the design advice, if it feels
/// weak, raise the rim/highlight opacity (GlassRimOverlay) FIRST — not `full`.
enum RefractionStrength {
    static let full: CGFloat = 11     // peak displacement, points (gentle lensing)
    static let chroma: CGFloat = 3.0  // edge-only chromatic aberration (prismatic rim)
    static let noise: CGFloat = 0.28  // procedural glass irregularity (0.15...0.45)
    /// Must cover the shader's peak sample offset (~8pt here). 24 if edges clip.
    static let maxOffset: CGFloat = 40
}

/// Applies the calm, edge-weighted Liquid-Glass backdrop refraction (the
/// `backdropRefract` Metal shader in LiquidGlass.metal). It MUST be applied to a
/// rasterizable view — the snapshot `Image` of the app behind the player — NOT the
/// live UIKit-backed TabView, which can't be rasterized into a layer and renders as
/// SwiftUI's red "unrenderable" placeholder. `Animatable` on `strength`, so the
/// refraction fades smoothly on the GPU (the shader argument interpolates per frame).
struct BackdropRefraction: ViewModifier, Animatable {
    var strength: CGFloat
    var chroma: CGFloat
    var noise: CGFloat
    var cornerRadius: CGFloat
    var size: CGSize

    // `nonisolated`: SwiftUI drives `animatableData` off the main actor during an
    // animation; without this, the Animatable conformance on a @MainActor
    // ViewModifier is a Swift 6 isolation error. Safe — it only touches this value
    // type's own `CGFloat`.
    nonisolated var animatableData: CGFloat {
        get { strength }
        set { strength = newValue }
    }

    func body(content: Content) -> some View {
        // `isEnabled` is safe now: the source is a rasterizable Image, so disabling
        // it just skips the shader (no red-X), and keeping the modifier in the tree
        // lets the Animatable strength fade stay smooth.
        content.layerEffect(
            ShaderLibrary.backdropRefract(
                .float2(size),
                .float(strength),
                .float(chroma),
                .float(noise),
                .float(cornerRadius)
            ),
            maxSampleOffset: CGSize(width: RefractionStrength.maxOffset,
                                    height: RefractionStrength.maxOffset),
            isEnabled: strength > 0.05
        )
    }
}

/// Captures the app currently on screen (the collapsed state behind the player) as
/// a rasterizable image for the refraction shader. A UIKit window snapshot — robust
/// for UIKit-hosted content (TabView / tab bar) that `ImageRenderer` and
/// `layerEffect` choke on. Returns nil if there is no key window (→ clear-glass
/// fallback). Captured while collapsed (on tap / drag-start), so it never includes
/// the expanding player itself.
enum BackdropCapture {
    @MainActor
    static func snapshot() -> UIImage? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2          // refracted view doesn't need @3x; halves memory
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { ctx in
            #if targetEnvironment(simulator)
            // `drawHierarchy` returns a BLACK image on the Simulator; `layer.render`
            // captures standard SwiftUI content fine there (used only to visually
            // validate the glass over real app content on the sim).
            window.layer.render(in: ctx.cgContext)
            #else
            // Device: drawHierarchy(afterScreenUpdates:false) captures the live frame
            // including visual effects, and is proven on device.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            #endif
        }
    }
}

#if DEBUG
/// Synthetic backdrop for Simulator visual iteration. The live window snapshot comes
/// back black on the Simulator (a `drawHierarchy` limitation; the real capture is
/// proven on device), so `-uiPreview` injects this instead. Mimics an app screen —
/// gradient, a title, text rows, and colour blobs — so the refraction, chromatic
/// aberration and rim are all visible to evaluate.
enum DebugBackdrop {
    @MainActor
    static func testImage(size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: cs, colors: [
                UIColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 1).cgColor,
                UIColor(red: 0.30, green: 0.10, blue: 0.45, alpha: 1).cgColor,
                UIColor.black.cgColor] as CFArray, locations: [0, 0.5, 1])!
            c.drawLinearGradient(grad, start: .zero,
                                 end: CGPoint(x: size.width, y: size.height), options: [])
            ("Good evening" as NSString).draw(at: CGPoint(x: 28, y: size.height * 0.10),
                withAttributes: [.font: UIFont.systemFont(ofSize: 40, weight: .bold),
                                 .foregroundColor: UIColor.white])
            UIColor(white: 1, alpha: 0.85).setFill()
            for i in 0..<16 {
                let y = size.height * 0.26 + CGFloat(i) * 34
                let w = size.width * (i % 3 == 0 ? 0.72 : 0.48)
                UIBezierPath(roundedRect: CGRect(x: 28, y: y, width: w, height: 12),
                             cornerRadius: 6).fill()
            }
            UIColor.systemTeal.setFill()
            c.fillEllipse(in: CGRect(x: size.width*0.58, y: size.height*0.46, width: 130, height: 130))
            UIColor.systemPink.setFill()
            c.fillEllipse(in: CGRect(x: size.width*0.70, y: size.height*0.62, width: 96, height: 96))
            UIColor.systemYellow.setFill()
            c.fillEllipse(in: CGRect(x: size.width*0.40, y: size.height*0.70, width: 78, height: 78))
        }
    }
}
#endif
