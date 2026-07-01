import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Mini player content (the collapsed-state row)

/// The collapsed-state content only: artwork + title/artist + transport (or an
/// error row). It carries NO background, shadow or gesture — those belong to the
/// single `MorphingPlayer` surface, so the SAME glass element flows from bar to
/// full screen. Sized to ~`MorphingPlayer.barHeight`.
struct MiniPlayerContent: View {
    @Environment(AppModel.self) private var model
    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        if let message = engine.lastErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.warning)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can’t play this track")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Playback error. \(message)")
                Spacer(minLength: 8)
                // Skip past the failed track instead of only offering "clear the whole
                // queue" — one bad file shouldn't force a restart of a long queue.
                if engine.hasNext {
                    Button {
                        engine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip to next track")
                }
                Button {
                    engine.clearQueue()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else if let track = engine.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 6)
                        .frame(width: 40, height: 40)
                        .overlay {
                            if engine.isBuffering {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                    .frame(width: 40, height: 40)
                                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Now playing \(track.title) by \(track.artist)")

                    Spacer(minLength: 8)

                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

                    Button {
                        engine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundStyle(engine.hasNext ? DesignTokens.textPrimary : DesignTokens.textTertiary)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!engine.hasNext)
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                ProgressBar(value: engine.progressFraction)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Morphing player (ONE element: mini bar ⇄ full Now Playing)

/// The single player element. At `p == 0` it IS the floating mini bar; at `p == 1`
/// it IS the full Now Playing screen. The SAME Liquid Glass surface grows out of
/// the bar's frame and fills the screen (and drains back) as `p` tracks the finger
/// — so there is no separate bar plus a pop-in overlay. The glass starts clean and
/// clear (real refraction of the app behind it stays visible) and tints lightly
/// toward the album colour only as it commits. Tap or drag up opens; the full
/// screen's own chevron / drag-down closes.
struct MorphingPlayer: View {
    @Environment(AppModel.self) private var model
    let p: CGFloat              // 0 = mini, 1 = full (live, finger-tracking)
    let screenSize: CGSize      // full screen incl. safe areas
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let tint: Color             // album palette colour the glass tints toward
    /// Frozen snapshot of the app behind, refracted at full open (nil ⇒ no snapshot;
    /// the clear glass still shows the real backdrop, just with subtler refraction).
    /// A binding so the open gestures can grab a CLEAN collapsed frame the instant
    /// they begin (and drop it on a snap-back), avoiding a snapshot of the player.
    @Binding var backdrop: UIImage?
    /// Strength of the snapshot refraction (points).
    let refractStrength: CGFloat
    @Binding var dragFraction: CGFloat?
    @Binding var presented: Bool

    private var engine: PlaybackEngine { model.engine }

    /// Collapsed-bar metrics. Knob: `bottomGap` floats the bar above the tab bar;
    /// `barHeight` matches `MiniPlayerContent` (row 56 + progress strip 8).
    static let barHeight: CGFloat = 64
    private let sideInset: CGFloat = 8
    // ~15pt clear of the tab bar (whose content is ~49pt tall above the home
    // indicator); at 50 the bar sat almost flush on top of the tab icons.
    private let bottomGap: CGFloat = 64

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    /// Clamped 0→1 ramp of `x` across [lo, hi]; used to time the cross-fades.
    private func ramp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max((x - lo) / (hi - lo), 0), 1)
    }

    var body: some View {
        let W = screenSize.width
        let H = screenSize.height
        let pc = min(max(p, 0), 1)
        // Live finger-drag in progress (vs settled / mid-settle-animation). During a
        // drag `p` changes every frame, so the per-frame Liquid-Glass lensing + the
        // screen-blended rim recompute over a resizing shape each frame — that is the
        // morph lag. So drag uses a cheap static material with no rim; the real glass
        // and rim resolve on settle (a short spring, where the per-frame cost is fine).
        let dragging = dragFraction != nil

        // Source = the floating mini bar's frame, COMPUTED (not measured). Because
        // there is only this one element, there is nothing to match against, so the
        // morph can never be "slightly mis-sized". Destination = the full screen.
        let barMaxY = H - safeBottom - bottomGap
        let src = CGRect(x: sideInset, y: barMaxY - Self.barHeight,
                         width: W - sideInset * 2, height: Self.barHeight)

        let left   = lerp(src.minX, 0, pc)
        let right  = lerp(src.maxX, W, pc)
        let top    = lerp(src.minY, 0, pc)
        let bottom = lerp(src.maxY, H, pc)
        let w = max(right - left, 1)
        let h = max(bottom - top, 1)

        // Liquid surface: corners stay cohesive/blobby mid-morph, but the TOP edge
        // is a flat straight line (the meniscus dome was removed — it read badly).
        // Knob: `* 18` corner bulge.
        let inTransit = CGFloat(sin(Double(pc) * .pi))   // 0 at rest, 1 mid-morph
        let radius = lerp(14, 0, pc) + inTransit * 18
        let meniscus: CGFloat = 0   // flat top (dome removed per feedback)
        let shape = LiquidShape(cornerRadius: radius, meniscus: meniscus)

        // No album tint — stays clean clear glass so the real background (and its
        // colour drops) refracts through, instead of being masked by the cover
        // colour. (Raise this if a faint album tint is ever wanted.)
        let tintAmount = 0.0
        // Full (opaque) content resolves only in the last stretch, so the glass
        // reads as clear/translucent through most of the morph. Knob: [0.6, 1].
        let fullOpacity = Double(ramp(pc, 0.6, 1.0))
        // Mini row fades out almost immediately so the glass spreads clean. Knob: 0.22.
        let miniOpacity = Double(1 - ramp(pc, 0.0, 0.22))

        // The morph frame in screen coords (the moving "window" into the snapshot).
        let currentFrame = CGRect(x: left, y: top, width: w, height: h)

        return ZStack {
            // (1) FROSTED Liquid Glass surface. `Glass.regular` blurs the LIVE app behind
            // the player natively on the GPU. But recomputing the interactive lensing
            // glass over a shape that resizes every frame is what makes a live DRAG lag,
            // so while dragging we swap in a plain static material (no lensing, no
            // interactive wobble); the real glass resolves the instant the drag settles.
            if dragging {
                Color.clear.background(.ultraThinMaterial, in: shape)
                    .allowsHitTesting(false)
            } else {
                Color.clear.glassSurface(shape, tint: tint, amount: tintAmount, interactive: presented)
                    // Decorative surface: only intercept touches when it IS the full
                    // screen. Otherwise (bar / mid-collapse) it must pass touches through,
                    // else the large morph frame blocks the list behind for the whole
                    // settle — the "can't scroll for ~1s after collapsing" bug.
                    .allowsHitTesting(presented)
            }

            // (3) Content: full Now Playing (cropped from the bottom up, fades in) +
            // the mini row (fades out; owns the open gestures).
            ZStack(alignment: .bottom) {
                // Skip rendering the heavy full Now Playing view until it actually starts
                // fading in (it's opacity 0 below pc 0.6 anyway). Laying out this complex
                // view every frame through the whole morph was a chunk of the lag.
                // BUT keep it mounted for the whole collapse (while `presented`): the
                // collapse drag lives on this view's children, so unmounting it as a SLOW
                // drag crosses pc 0.55 killed the active gesture before `.onEnded` fired,
                // freezing dragFraction mid-screen (stuck half-view, app needed a restart).
                // Expand stays gated by pc alone (presented is false until release), so the
                // expand-drag perf path is unchanged.
                if pc > 0.55 || presented {
                    NowPlayingView(
                        dragFraction: $dragFraction,
                        presented: $presented,
                        containerHeight: H,
                        safeTop: safeTop,
                        safeBottom: safeBottom
                    )
                    .environment(model)
                    .frame(width: W, height: H, alignment: .top)
                    .opacity(fullOpacity)
                    .frame(width: w, height: h, alignment: .bottom)
                    // Only live when settled open: keeps its gestures off during an expand
                    // drag and lets the bar own taps while collapsed. `presented` never flips
                    // mid-drag, so an in-progress gesture is never cut.
                    .allowsHitTesting(presented)
                }

                // Mini row, anchored to the bottom (where the bar lives), fading out.
                MiniPlayerContent()
                    .environment(model)
                    // The bar height is fixed (the morph geometry depends on it), so
                    // cap Dynamic Type here — past xxLarge the text would clip the
                    // compact bar. The full player above has no such cap.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .frame(width: w, height: Self.barHeight)
                    .opacity(miniOpacity)
                    .contentShape(Rectangle())
                    // Tap to open + drag up to expand. Each grabs a CLEAN collapsed
                    // snapshot the instant it begins (before the player expands), so the
                    // refracted backdrop never contains the player itself. Buttons inside
                    // the row still win their taps (drag needs real movement).
                    .onTapGesture {
                        guard engine.lastErrorMessage == nil, !model.isPlayerMorphSettling else { return }
                        withAnimation(PlayerMorph.settle) { presented = true }
                    }
                    .gesture(expandDrag(height: H))
                    .allowsHitTesting(!presented)
            }

            // (4) The glass EDGE: white bevel + prismatic rim + soft top light. Scaled
            // by morph progress AND faded back out as it reaches full screen — at p==1
            // the player IS the whole screen, so a rim there reads as an ugly lighter
            // "cut-off" border around the display. So the edge only shows mid-morph
            // (where it sells the glass CARD) and vanishes when fully open. Skipped
            // during a live drag — its three screen-blended overlays were a chunk of
            // the per-frame morph cost; it returns on settle with the real glass.
            if !dragging {
                GlassRimOverlay(shape: shape,
                                intensity: Double(pc) * Double(1 - ramp(pc, 0.82, 1.0)))
            }
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .compositingGroup()
        // Fixed radius (an animating shadow radius re-rasterizes every frame → morph
        // lag); opacity still eases in. Smaller radius is cheaper to blur each frame.
        .shadow(color: .black.opacity(0.1 + 0.22 * Double(pc)), radius: 9, y: 5)
        .position(x: currentFrame.midX, y: currentFrame.midY)
        .frame(width: W, height: H)
        .ignoresSafeArea()
    }

    /// Up-drag on the collapsed bar raises the morph fraction live; release settles
    /// to full or mini by drag distance + fling velocity (viscous, no-bounce settle;
    /// the velocity only picks the target, it is never fed to the animation).
    private func expandDrag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard engine.lastErrorMessage == nil, !model.isPlayerMorphSettling, value.translation.height < 0 else { return }
                dragFraction = min(max(-value.translation.height / max(height, 1), 0), 1)
            }
            .onEnded { value in
                guard engine.lastErrorMessage == nil, !model.isPlayerMorphSettling else { return }
                let f = min(max(-value.translation.height / max(height, 1), 0), 1)
                let flungUp = value.predictedEndTranslation.height < -220
                let open = f > 0.25 || flungUp   // open if dragged past a quarter (or flung)
                withAnimation(PlayerMorph.settle) {
                    presented = open
                    dragFraction = nil
                }
            }
    }
}

extension View {
    /// Liquid Glass (iOS 26+) container background, falling back to the system
    /// thin material on earlier OSes. Used for the floating player surfaces.
    @ViewBuilder
    func playerGlassBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// The morphing player's Liquid Glass (iOS 26+) surface filling `shape`. Uses the
    /// CLEAR glass variant (not `.regular`) so the surface stays see-through — the app
    /// behind it (strongly refracted by `BackdropRefraction` at full open) shows
    /// through instead of reading as flat frosted black. `.interactive()` adds the
    /// touch-responsive liquid wobble; `amount` is a light optional album tint
    /// (currently 0). Takes any `Shape`. Thin-material fallback below iOS 26.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color, amount: Double, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            // `.interactive()` hit-tests its whole area and re-composites per frame; keep it
            // only while the player is the settled full screen. During the morph/bar it would
            // cover the screen and starve touches to the app behind while the settle spring
            // runs (the ~0.5-1s "can't scroll right after collapsing" hitch).
            let glass = Glass.regular.tint(tint.opacity(amount))
            self.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint.opacity(amount * 0.5)))
        }
    }
}

/// The morphing player's surface outline: a rounded rectangle whose TOP edge bows
/// up into a convex **meniscus** while the glass is filling, then settles flat —
/// so the leading edge reads as a real liquid surface held by surface tension, not
/// a rectangle resizing. The corners stay cohesive/blobby through the morph.
/// `meniscus` is the dome height (0 = flat); both params interpolate via
/// `animatableData` so the settle is smooth.
struct LiquidShape: InsettableShape {
    var cornerRadius: CGFloat
    var meniscus: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, meniscus) }
        set { cornerRadius = newValue.first; meniscus = newValue.second }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { return Path() }
        let r = max(0, min(cornerRadius - insetAmount, min(w, h) / 2))
        // Keep the domed shoulders inside the rect even at large radii.
        let m = max(0, min(meniscus, max(0, h - 2 * r)))
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let shoulderY = minY + m          // where the dome meets the side corners

        var path = Path()
        // Left shoulder → meniscus dome across the top → right shoulder. The control
        // point sits `m` above the rect so the curve PEAKS exactly at the top edge.
        path.move(to: CGPoint(x: minX + r, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: maxX - r, y: shoulderY),
                          control: CGPoint(x: rect.midX, y: minY - m))
        // Top-right corner
        path.addQuadCurve(to: CGPoint(x: maxX, y: shoulderY + r),
                          control: CGPoint(x: maxX, y: shoulderY))
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        // Bottom-right corner
        path.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY),
                          control: CGPoint(x: maxX, y: maxY))
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        // Bottom-left corner
        path.addQuadCurve(to: CGPoint(x: minX, y: maxY - r),
                          control: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: shoulderY + r))
        // Top-left corner
        path.addQuadCurve(to: CGPoint(x: minX + r, y: shoulderY),
                          control: CGPoint(x: minX, y: shoulderY))
        path.closeSubpath()
        return path
    }
}

/// The glass EDGE: a white bevel, a prismatic angular-gradient rim, a soft top-light
/// highlight, and an inner bevel — all `.screen`-blended so they read as light on
/// glass. `intensity` (0...1) scales every layer, so the edge fades in with the morph
/// progress. Per the design advice this sells the Liquid-Glass "object" more than the
/// refraction does — raise these opacities first if the look feels weak.
struct GlassRimOverlay<S: InsettableShape>: View {
    var shape: S
    var intensity: Double

    var body: some View {
        shape
            // Crisp white bevel edge.
            .strokeBorder(.white.opacity(0.5 * intensity), lineWidth: 0.8)
            .blendMode(.screen)
            // Prismatic chromatic edge — no blur (blur per-frame was the morph-lag
            // culprit); a crisp thin stroke reads as the glass edge and is cheap.
            .overlay {
                shape
                    .strokeBorder(
                        AngularGradient(colors: [
                            .cyan, .blue, .white, .pink, .yellow, .mint, .cyan
                        ], center: .center),
                        lineWidth: 2.0
                    )
                    .opacity(0.55 * intensity)
                    .blendMode(.screen)
            }
            // Soft top "global light".
            .overlay {
                shape.fill(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.16 * intensity), location: 0.0),
                        .init(color: .clear, location: 0.35)
                    ], startPoint: .top, endPoint: .center)
                )
                .blendMode(.screen)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Full Now Playing screen

/// Full-screen host for artist/album navigation triggered from the full player.
/// Presented as a `fullScreenCover`, NOT a sheet: an artist can have hundreds of
/// tracks, and a sheet's swipe-down-to-dismiss would close the whole screen on an
/// accidental down-swipe deep in the list. A cover only dismisses via the explicit
/// Close button. It owns a NavigationStack (standard opaque background) so the
/// player's own root can stay transparent for the Liquid-Glass backdrop; supports
/// nested navigation (e.g. album → artist) via its local path.
private struct PlayerNavCover: View {
    let route: LibraryRoute
    @Environment(\.dismiss) private var dismiss
    @State private var path: [LibraryRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            routeView
                .libraryDestinations()
                .libraryNavigation($path)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var routeView: some View {
        switch route {
        case .album(let id): AlbumDetailView(albumID: id)
        case .artist(let id): ArtistDetailView(artistID: id)
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        default: EmptyView()
        }
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var showQueue = false
    @State private var showLyrics = false
    /// Artist/album navigation from the player opens a full-screen cover (its own
    /// NavigationStack + opaque background), NOT a sheet — a long artist list must not
    /// close on an accidental swipe-down, and the player root must stay transparent for
    /// the Liquid-Glass backdrop (a NavigationStack as the player's root paints an opaque
    /// system background that covered the glass at full open). See `PlayerNavCover`.
    @State private var navRoute: LibraryRoute?

    /// Live downward-drag fraction (1 = full, 0 = mini); nil when settled. Owned
    /// by the host (RootTabView), which positions this view by it for a
    /// finger-tracking collapse. Defaulted so previews/other callers still work.
    var dragFraction: Binding<CGFloat?> = .constant(nil)
    /// Settled presentation flag, flipped to false on a completed collapse.
    var presented: Binding<Bool> = .constant(true)
    /// Full container height, to translate a downward drag into a fraction.
    var containerHeight: CGFloat = 1
    /// Safe-area insets re-injected by the morph host (its surface ignores the
    /// safe area so the glass can fill the screen), so the controls stay clear of
    /// the Dynamic Island / home indicator.
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        // NO NavigationStack here: it paints an opaque system background that covers
        // the Liquid-Glass backdrop behind the player at full open. The player root
        // stays transparent; artist/album navigation opens as a full-screen cover.
        playerContent
            .fullScreenCover(item: $navRoute) { route in
                PlayerNavCover(route: route)
                    .environment(model)
            }
    }

    private var playerContent: some View {
        GeometryReader { proxy in
            let artSize = min(proxy.size.width - 56, proxy.size.height * 0.42)
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    grabber

                    if let track = engine.currentTrack {
                        Spacer(minLength: 8)

                        ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 14, maxPixel: 800)
                            .frame(width: artSize, height: artSize)
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
                            .scaleEffect(engine.isPlaying ? 1.0 : 0.84)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: engine.isPlaying)
                            .gesture(collapseDrag)

                        Spacer(minLength: 16)

                        trackHeader(track)
                            .padding(.horizontal, 28)
                            .contentShape(Rectangle())
                            .gesture(collapseDrag)

                        scrubber
                            .padding(.horizontal, 28)
                            .padding(.top, 18)

                        formatChip(track)
                            .padding(.top, 10)

                        transport
                            .padding(.top, 12)

                        volumeRow
                            .padding(.horizontal, 28)
                            .padding(.top, 18)

                        bottomBar
                            .padding(.horizontal, 36)
                            .padding(.top, 22)
                            .padding(.bottom, 8)

                        Spacer(minLength: 8)
                    } else {
                        Spacer()
                        Text("Nothing playing")
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                    }
                }
                // The morph host ignores the safe area (so the glass fills the screen)
                // and there's no NavigationStack here to inset, so the grabber pads by
                // safeTop itself to clear the Dynamic Island / camera cutout. The
                // gradient still fills edge to edge via ignoresSafeArea.
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showQueue) {
            NowPlayingQueueView()
                .environment(model)
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLyrics) {
            if let track = engine.currentTrack {
                LyricsSheet(track: track)
                    .environment(model)
                    .presentationDetents([.large, .medium])
                    .presentationDragIndicator(.visible)
            } else {
                ContentUnavailableView("No track playing", systemImage: "music.note")
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var backgroundGradient: some View {
        // A dimming scrim over the refracted backdrop. The glass stays see-through, but
        // the app behind it is darkened enough that its content (esp. large text) recedes
        // and the player's own controls read as the foreground — the raw refraction alone
        // left the backdrop too legible/distracting. Fades in with the content opacity, so
        // it only dims once the player is actually open. (Light mode: lighten instead.)
        // A light wash that LIFTS the frosted backdrop's brightness (the heavy blur is
        // the glass itself, untouched — so it stays very blurry, just brighter). Less at
        // the bottom so the transport controls keep contrast against it.
        LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.13), .white.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Swipe down anywhere in the top area (artwork / title) to dismiss.
    /// Finger-tracking collapse: a downward drag lowers the presentation fraction
    /// live (the host offsets the whole view by it), and on release it snaps to
    /// full or mini by position + fling velocity.
    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                let f = 1 - (value.translation.height / max(containerHeight, 1))
                dragFraction.wrappedValue = min(max(f, 0), 1)
            }
            .onEnded { value in
                let f = 1 - (max(value.translation.height, 0) / max(containerHeight, 1))
                let flungDown = value.predictedEndTranslation.height > 280
                let stayOpen = f > 0.72 && !flungDown
                model.isPlayerMorphSettling = true
                withAnimation(PlayerMorph.settle) {
                    presented.wrappedValue = stayOpen
                    dragFraction.wrappedValue = nil
                } completion: {
                    model.isPlayerMorphSettling = false
                }
            }
    }

    private func collapse() {
        model.isPlayerMorphSettling = true
        withAnimation(PlayerMorph.settle) {
            presented.wrappedValue = false
            dragFraction.wrappedValue = nil
        } completion: {
            model.isPlayerMorphSettling = false
        }
    }

    private var grabber: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, safeTop + 6)
            HStack {
                Button { collapse() } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Text(engine.currentTrack?.sourceName ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
        }
        .contentShape(Rectangle())
        .gesture(collapseDrag)
    }

    private func trackHeader(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button {
                    navRoute = .artist(track.artistID)
                } label: {
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                if let summary = model.classicalCredits(for: track.id)?.playerSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Button {
                model.toggleFavorite(track.id)
            } label: {
                Image(systemName: model.isFavorite(track.id) ? "star.fill" : "star")
                    .font(.headline)
                    .foregroundStyle(model.isFavorite(track.id) ? DesignTokens.brandPrimary : .white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.14), in: Circle())
            }

            Menu {
                trackMenu(track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.14), in: Circle())
            }
        }
    }

    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        if model.canManageDownload(track.id) {
            if model.cacheState(track.id) == .cached {
                Button("Remove Download", systemImage: "trash") { model.removeDownload(track.id) }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { model.download(track.id) }
            }
        }
        Button("Go to Album", systemImage: "square.stack") { navRoute = .album(track.albumID) }
        Button("Edit Info", systemImage: "pencil") { model.metadataEditTarget = .track(track.id) }
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist", systemImage: "plus") {
                model.createPlaylist(name: "New Playlist", trackIDs: [track.id])
            }
            if !model.playlists.isEmpty { Divider() }
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { model.addToPlaylist(playlist.id, trackIDs: [track.id]) }
            }
        }
        Button("Lyrics", systemImage: "quote.bubble") { showLyrics = true }
        Button("View Queue", systemImage: "list.bullet") { showQueue = true }
        Menu("Sleep Timer", systemImage: model.sleepTimerArmed ? "moon.zzz.fill" : "moon.zzz") {
            if model.sleepTimerArmed {
                Button("Turn Off", systemImage: "xmark") { model.cancelSleepTimer() }
            }
            Button("End of Track") { model.sleepAtEndOfTrack() }
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { model.startSleepTimer(minutes: minutes) }
            }
        }
    }

    private var scrubber: some View {
        Scrubber()   // reads the engine itself; keeps per-tick redraw off this view
    }

    @ViewBuilder
    private func formatChip(_ track: Track) -> some View {
        if engine.isBuffering {
            // Show activity while waiting on the network so it never looks frozen.
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Buffering…").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
        } else if !track.formatLabel.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: track.isLossless ? "seal.fill" : "waveform")
                    .font(.caption2)
                Text(engine.currentFormatDetail ?? track.formatLabel)
                    .font(.caption2.weight(.semibold))
                if model.cacheState(track.id) == .cached || model.cacheState(track.id) == .prefetched {
                    Text("· Downloaded").font(.caption2)
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityElement(children: .combine)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            .foregroundStyle(.white)

            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 72, height: 72)
            }
            .foregroundStyle(.white)

            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            .foregroundStyle(.white.opacity(engine.hasNext ? 1 : 0.4))
            .disabled(!engine.hasNext)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.footnote).foregroundStyle(.white.opacity(0.6))
            SystemVolumeSlider()
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill").font(.footnote).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { showLyrics = true } label: {
                Image(systemName: "quote.bubble")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            RoutePickerButton()
                .frame(width: 44, height: 44)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Playing Next (queue) sheet

struct NowPlayingQueueView: View {
    @Environment(AppModel.self) private var model
    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        NavigationStack {
            List {
                if let track = engine.currentTrack {
                    Section {
                        QueueRow(track: track, isCurrent: true)
                    } header: {
                        Text("Now Playing")
                    }
                }

                Section {
                    let upcoming = Array(engine.queue.enumerated())
                        .filter { $0.offset > engine.currentIndex }
                    if upcoming.isEmpty {
                        Text("Nothing up next")
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    ForEach(upcoming, id: \.offset) { _, track in
                        QueueRow(track: track, isCurrent: false)
                    }
                    .onDelete { offsets in
                        // Map filtered offsets back to absolute queue indices.
                        let base = engine.currentIndex + 1
                        engine.removeFromQueue(at: IndexSet(offsets.map { $0 + base }))
                    }
                    .onMove { source, destination in
                        let base = engine.currentIndex + 1
                        engine.moveQueueItem(
                            fromOffsets: IndexSet(source.map { $0 + base }),
                            toOffset: destination + base
                        )
                    }
                } header: {
                    HStack {
                        Text("Playing Next")
                        Spacer()
                        Button {
                            engine.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(engine.shuffleEnabled ? DesignTokens.brandPrimary : DesignTokens.textSecondary)
                        }
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(engine.shuffleEnabled ? "On" : "Off")
                        Button {
                            engine.cycleRepeat()
                        } label: {
                            Image(systemName: engine.repeatMode.systemImage)
                                .foregroundStyle(engine.repeatMode != .off ? DesignTokens.brandPrimary : DesignTokens.textSecondary)
                        }
                        .accessibilityLabel("Repeat")
                        .accessibilityValue(engine.repeatMode == .off ? "Off" : engine.repeatMode == .one ? "One song" : "All songs")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
        }
    }
}

private struct QueueRow: View {
    var track: Track
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(isCurrent ? .bold : .semibold))
                    .foregroundStyle(isCurrent ? DesignTokens.brandPrimary : DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(DesignTokens.brandPrimary)
            }
        }
    }
}

// MARK: - Interactive scrubber

struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var dragFraction: Double?

    private var engine: PlaybackEngine { model.engine }

    // Reading engine.elapsed/duration HERE (not in the parent) keeps the
    // per-tick re-render scoped to the scrubber, so the Now Playing menu and
    // the rest of the screen don't pulse every 0.5s.
    private var liveFraction: Double {
        if let dragFraction { return dragFraction }
        guard engine.duration > 0 else { return 0 }
        return min(max(engine.elapsed / engine.duration, 0), 1)
    }

    private var elapsedSeconds: Double {
        if let dragFraction { return dragFraction * engine.duration }
        return engine.elapsed
    }

    private var elapsedLabel: String { TimeFormat.clock(elapsedSeconds) }

    private var remainingLabel: String {
        guard engine.duration > 0 else { return "-0:00" }
        return "-" + TimeFormat.clock(max(engine.duration - elapsedSeconds, 0))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 6)
                    Capsule().fill(.white.opacity(0.9)).frame(width: width * liveFraction, height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, width * liveFraction - 7))
                        .shadow(radius: 2)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            let frac = min(max(value.location.x / width, 0), 1)
                            dragFraction = nil
                            engine.seek(toSeconds: frac * engine.duration)
                        }
                )
            }
            .frame(height: 24)

            HStack {
                Text(elapsedLabel)
                Spacer()
                Text(remainingLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// MARK: - System volume + AirPlay (UIKit bridges)

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.85)
        view.activeTintColor = UIColor(DesignTokens.brandPrimary)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Lyrics

struct LyricsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var lines: [LyricsLine]?
    @State private var loading = true

    private var engine: PlaybackEngine { model.engine }
    private var synced: Bool { lines?.contains { $0.time != nil } ?? false }

    /// Index of the current synced line for `engine.elapsed`.
    private var currentIndex: Int? {
        guard synced, let lines else { return nil }
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if let t = line.time, t <= engine.elapsed { idx = i } else if line.time != nil { break }
        }
        return idx
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let lines, !lines.isEmpty {
                    lyricsScroll(lines)
                } else {
                    ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                                           description: Text("No .lrc lyrics found next to this track."))
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            lines = await model.lyrics(for: track)
            loading = false
        }
    }

    private func lyricsScroll(_ lines: [LyricsLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(index == currentIndex ? .bold : .regular))
                            .foregroundStyle(index == currentIndex ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 80)
            }
            .onChange(of: currentIndex) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}
