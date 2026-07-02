import SwiftUI

// MARK: - Track row (Apple Music density)

struct TrackRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.libraryNavigate) private var libraryNavigate
    var track: Track
    var context: [Track]
    /// Show the leading artwork tile (off for tight album track lists).
    var showArtwork: Bool = true
    /// Optional leading number for album track lists.
    var index: Int?

    private var isCurrent: Bool { model.engine.currentTrack?.id == track.id }
    /// In Offline Mode, a track that isn't downloaded can't play — dim it (Apple-Music
    /// style) so it reads as unavailable rather than looking tappable-but-dead.
    private var isUnavailableOffline: Bool {
        model.offlineMode && !track.cacheState.isPlayableOffline
    }

    var body: some View {
        Button {
            #if DEBUG
            AppLog.ui.debug("BETTERSTREAMING_UI track_tap title=\(track.title) ext=\(track.fileExtension, privacy: .public) source=\(track.sourceID, privacy: .public)")
            #endif
            // Tapping the row that's already playing opens the player (Apple Music
            // behaviour) instead of restarting the track.
            if isCurrent {
                model.isNowPlayingPresented = true
            } else {
                model.play(track, in: context)
            }
        } label: {
            HStack(spacing: 12) {
                if let index {
                    Text("\(index)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(isCurrent ? DesignTokens.brandPrimary : DesignTokens.textTertiary)
                        .frame(width: 24, alignment: .center)
                } else if showArtwork {
                    ArtworkView(url: track.artworkURL, artworkKey: track.albumID,
                                glyph: track.kind == .video ? "film" : "music.note", cornerRadius: 6)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .center) {
                            if isCurrent {
                                Image(systemName: "waveform")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrent ? DesignTokens.brandPrimary : DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text(showArtwork ? "\(track.artist) · \(track.album)" : track.artist)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if track.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.brandPrimary)
                }
                availabilityGlyph

                Menu {
                    trackMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 30, height: 44)
                }
            }
            .padding(.vertical, 3)
            .opacity(isUnavailableOffline ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.cacheState.label)")
        // Combining the row hides the ellipsis Menu from VoiceOver, so surface the
        // same actions as rotor custom actions (else they're unreachable).
        .accessibilityActions {
            Button("Play Next") { model.engine.playNext(track) }
            Button("Add to Queue") { model.engine.addToQueue(track) }
            Button(model.isFavorite(track.id) ? "Remove Favourite" : "Favourite") {
                model.toggleFavorite(track.id)
            }
            if let first = model.playlists.first {
                Button("Add to \(first.name)") { model.addToPlaylist(first.id, trackIDs: [track.id]) }
            }
            if model.canManageDownload(track.id) {
                if model.cacheState(track.id) == .cached {
                    Button("Remove Download") { model.removeDownload(track.id) }
                } else {
                    Button("Download") { model.download(track.id) }
                }
            }
            if let libraryNavigate {
                Button("Go to Album") { libraryNavigate(.album(track.albumID)) }
                Button("Go to Artist") { libraryNavigate(.artist(track.artistID)) }
            }
        }
    }

    @ViewBuilder
    private var availabilityGlyph: some View {
        switch track.cacheState {
        case .downloading:
            // Live feedback while an album/track download runs.
            ProgressView().controlSize(.mini).tint(DesignTokens.connectionTeal)
        case .queued:
            Image(systemName: "clock").font(.caption).foregroundStyle(DesignTokens.connectionTeal)
        case .cached, .prefetched, .missingSource, .failed, .stale:
            let state = track.cacheState
            Image(systemName: state.systemImage).font(.caption).foregroundStyle(state.tint)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trackMenu: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            model.engine.playNext(track)
        }
        Button("Add to Queue", systemImage: "text.badge.plus") {
            model.engine.addToQueue(track)
        }
        Button(model.isFavorite(track.id) ? "Remove Favourite" : "Favourite",
               systemImage: model.isFavorite(track.id) ? "star.slash" : "star") {
            model.toggleFavorite(track.id)
        }
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist", systemImage: "plus") {
                model.createPlaylist(name: "New Playlist", trackIDs: [track.id])
            }
            if !model.playlists.isEmpty { Divider() }
            ForEach(model.playlists) { playlist in
                Button(playlist.name) { model.addToPlaylist(playlist.id, trackIDs: [track.id]) }
            }
        }
        if model.canManageDownload(track.id) {
            if model.cacheState(track.id) == .cached {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    model.removeDownload(track.id)
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    model.download(track.id)
                }
            }
        }
        // Navigation only where a host stack exists (nil inside the player) — a
        // NavigationLink can't live in a detached menu platter, so we push via the env.
        if let libraryNavigate {
            Divider()
            Button("Go to Album", systemImage: "square.stack") { libraryNavigate(.album(track.albumID)) }
            Button("Go to Artist", systemImage: "music.mic") { libraryNavigate(.artist(track.artistID)) }
        }
    }
}

// MARK: - Square artwork tile (horizontal rails)

struct SquareArtTile: View {
    var artworkKey: String
    var url: URL?
    var title: String
    var subtitle: String
    var glyph: String = "music.note"
    var size: CGFloat = 156
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(url: url, artworkKey: artworkKey, glyph: glyph, cornerRadius: 10)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Album grid cell (2-up grid)

struct AlbumGridCell: View {
    var album: Album
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(url: album.artworkURL, artworkKey: album.id, cornerRadius: 10)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Alphabetical sectioning + fast-scroll index (Apple Music style)

/// One A–Z section of a list. `letter` is the section key ("A"…"Z", a Cyrillic
/// letter, or "#" for digits/symbols) and doubles as the scroll anchor id.
struct LetterSection<Item>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }
}

enum LibraryIndex {
    /// Section key for a name. Latin/Cyrillic/Greek fold to one shared Latin A–Z
    /// index (so "Эпидемия" → E, "Король" → K — П=P, Г=G as requested). Scripts
    /// that don't romanize to a Latin letter (CJK, Japanese, Korean, Arabic…)
    /// keep their own character as the key and sort to the bottom. Digits/symbols
    /// → "#".
    static func sectionKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        if first.isNumber { return "#" }
        if let scalar = first.unicodeScalars.first, isLatinReconcilable(scalar) {
            // Romanize + strip diacritics → a plain A–Z letter.
            if let folded = String(first)
                .applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?
                .uppercased()
                .first(where: { $0.isLetter && $0.isASCII }) {
                return String(folded)
            }
            if let c = String(first).uppercased().first, c.isASCII, c.isLetter { return String(c) }
            return "#"
        }
        // Non-romanizable script: own group (sorts after Latin, before "#").
        return String(first).uppercased()
    }

    /// Latin (+ extended), Cyrillic, and Greek romanize cleanly to Latin letters;
    /// CJK/Hangul/Kana/etc. romanize to whole syllables, so we exclude them here
    /// and keep them as their own index groups instead.
    private static func isLatinReconcilable(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x0041...0x024F).contains(v)   // Latin: Basic + Latin-1 + Extended-A/B
            || (0x0370...0x03FF).contains(v)   // Greek
            || (0x0400...0x052F).contains(v)   // Cyrillic + Supplement
            || (0x1E00...0x1EFF).contains(v)   // Latin Extended Additional
    }

    /// Group already-sorted items into A–Z sections, "#" last. Items must already
    /// be in display order; sectioning preserves it.
    static func sections<Item>(_ items: [Item], key: (Item) -> String) -> [LetterSection<Item>] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let letter = sectionKey(key(item))
            if buckets[letter] == nil { order.append(letter) }
            buckets[letter, default: []].append(item)
        }
        let sorted = order.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sorted.map { LetterSection(letter: $0, items: buckets[$0] ?? []) }
    }
}

/// Vertical A–Z strip pinned to the trailing edge. Tapping or dragging reports
/// the focused letter so the host can `scrollTo` it. Shows only the letters that
/// exist, so a Cyrillic library gets a Cyrillic index and an English one A–Z.
struct AlphabetIndexBar: View {
    let letters: [String]
    let onSelect: (String) -> Void

    /// The letter under the finger while dragging; nil when idle. Drives the
    /// selection haptic (on change) and the floating bubble overlay.
    @State private var focused: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignTokens.brandPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !letters.isEmpty, geo.size.height > 0 else { return }
                        let step = geo.size.height / CGFloat(letters.count)
                        let idx = min(letters.count - 1, max(0, Int(value.location.y / step)))
                        let letter = letters[idx]
                        if letter != focused { focused = letter }
                        onSelect(letter)
                    }
                    .onEnded { _ in focused = nil }
            )
            // Floating letter chip to the left of the bar, tracking the finger.
            .overlay(alignment: .trailing) {
                if let focused, let idx = letters.firstIndex(of: focused), geo.size.height > 0 {
                    let step = geo.size.height / CGFloat(letters.count)
                    let y = step * (CGFloat(idx) + 0.5)
                    Text(focused)
                        .font(.title.weight(.bold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(DesignTokens.brandPrimary.opacity(0.4), lineWidth: 1))
                        .offset(x: -44, y: y - geo.size.height / 2)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 18)
        .padding(.trailing, 2)
        // iOS 17 haptics: one selection tick each time the focused letter changes.
        .sensoryFeedback(.selection, trigger: focused)
    }
}

/// A vertically-scrolling list with A–Z sections and the fast-scroll index.
/// `content` builds the body for one section (header is added automatically).
struct AlphabetIndexedScroll<Item, Header: View, SectionContent: View>: View {
    let sections: [LetterSection<Item>]
    let header: Header
    let sectionContent: (LetterSection<Item>) -> SectionContent

    init(
        sections: [LetterSection<Item>],
        @ViewBuilder header: () -> Header,
        @ViewBuilder sectionContent: @escaping (LetterSection<Item>) -> SectionContent
    ) {
        self.sections = sections
        self.header = header()
        self.sectionContent = sectionContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    header
                    ForEach(sections) { section in
                        Section {
                            sectionContent(section)
                        } header: {
                            Text(section.letter)
                                .font(.headline)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(DesignTokens.surfaceCanvas.opacity(0.92))
                                .id(section.letter)
                        }
                    }
                }
                .padding(DesignTokens.phonePadding)
                .padding(.bottom, 120)
            }
            .overlay(alignment: .trailing) {
                if sections.count > 1 {
                    AlphabetIndexBar(letters: sections.map(\.letter)) { letter in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    }
                }
            }
        }
    }
}

extension AlphabetIndexedScroll where Header == EmptyView {
    init(
        sections: [LetterSection<Item>],
        @ViewBuilder sectionContent: @escaping (LetterSection<Item>) -> SectionContent
    ) {
        self.init(sections: sections, header: { EmptyView() }, sectionContent: sectionContent)
    }
}

// MARK: - Library category row (Playlists / Artists / Albums / Songs nav)

struct LibraryCategoryRow: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 30)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
