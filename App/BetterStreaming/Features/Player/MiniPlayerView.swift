import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Mini player bar (mounted above the tab bar)

struct MiniPlayerBar: View {
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
                Spacer(minLength: 8)
                Button {
                    engine.clearQueue()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playback error. \(message)")
        } else if let track = engine.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 6)
                        .frame(width: 40, height: 40)

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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                ProgressBar(value: engine.progressFraction)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .contentShape(Rectangle())
            .onTapGesture { model.isNowPlayingPresented = true }
            .highPriorityGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.height < -30 {
                            model.isNowPlayingPresented = true
                        } else if value.translation.width < -40 {
                            engine.next()
                        } else if value.translation.width > 40 {
                            engine.previous()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing \(track.title) by \(track.artist)")
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Full Now Playing screen

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var detail: NowPlayingDetail?

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        GeometryReader { proxy in
            let artSize = min(proxy.size.width - 56, proxy.size.height * 0.42)
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    grabber

                    if let track = engine.currentTrack {
                        Spacer(minLength: 8)

                        ArtworkView(url: track.artworkURL, artworkKey: track.albumID, cornerRadius: 14)
                            .frame(width: artSize, height: artSize)
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
                            .scaleEffect(engine.isPlaying ? 1.0 : 0.84)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: engine.isPlaying)
                            .gesture(dismissDrag)

                        Spacer(minLength: 16)

                        trackHeader(track)
                            .padding(.horizontal, 28)
                            .contentShape(Rectangle())
                            .gesture(dismissDrag)

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
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showQueue) {
            NowPlayingQueueView()
                .environment(model)
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $detail) { item in
            NavigationStack {
                switch item {
                case .album(let id): AlbumDetailView(albumID: id)
                case .artist(let id): ArtistDetailView(artistID: id)
                }
            }
            .libraryDestinations()
            .environment(model)
        }
    }

    private var backgroundGradient: some View {
        let key = engine.currentTrack?.albumID ?? "placeholder"
        let palette = Artwork.palette(for: key)
        return LinearGradient(
            colors: [palette.top, palette.bottom, .black],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(Color.black.opacity(0.18))
    }

    /// Swipe down anywhere in the top area (artwork / title) to dismiss.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                if value.translation.height > 60, abs(value.translation.width) < value.translation.height {
                    dismiss()
                }
            }
    }

    private var grabber: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
            HStack {
                Button { dismiss() } label: {
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
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 60 { dismiss() }
            }
        )
    }

    private func trackHeader(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
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
        Button("Go to Album", systemImage: "square.stack") { detail = .album(track.albumID) }
        Button("Go to Artist", systemImage: "music.mic") { detail = .artist(track.artistID) }
        Button("View Queue", systemImage: "list.bullet") { showQueue = true }
    }

    private var scrubber: some View {
        Scrubber()   // reads the engine itself; keeps per-tick redraw off this view
    }

    @ViewBuilder
    private func formatChip(_ track: Track) -> some View {
        if !track.formatLabel.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: track.isLossless ? "seal.fill" : "waveform")
                    .font(.caption2)
                Text(track.formatLabel)
                    .font(.caption2.weight(.semibold))
                if model.cacheState(track.id) == .cached || model.cacheState(track.id) == .prefetched {
                    Text("· Downloaded").font(.caption2)
                }
            }
            .foregroundStyle(.white.opacity(0.6))
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
            Button {} label: {
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

enum NowPlayingDetail: Identifiable {
    case album(String)
    case artist(String)
    var id: String {
        switch self {
        case .album(let s): "album-\(s)"
        case .artist(let s): "artist-\(s)"
        }
    }
}

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
                    ForEach(upcoming, id: \.element.id) { _, track in
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
                        Button {
                            engine.cycleRepeat()
                        } label: {
                            Image(systemName: engine.repeatMode.systemImage)
                                .foregroundStyle(engine.repeatMode != .off ? DesignTokens.brandPrimary : DesignTokens.textSecondary)
                        }
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
