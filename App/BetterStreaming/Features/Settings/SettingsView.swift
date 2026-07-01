import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LibraryService.onlineArtworkKey) private var onlineArtwork = false
    @AppStorage(LibraryService.classicalCreditsKey) private var classicalCredits = false
    /// Debounces live re-apply of audio enhancements while the user drags sliders
    /// (one re-prep after they settle, not one per step).
    @State private var enhApplyTask: Task<Void, Never>?

    private func scheduleEnhancementsApply() {
        enhApplyTask?.cancel()
        enhApplyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            model.engine.enhancementsDidChange()
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                autoCacheSection
                audioSection
                artworkSection
                librarySection
                sourcesSection
                aboutSection
            }
            .padding(DesignTokens.phonePadding)
            .padding(.bottom, 120)
        }
        .appScreenBackground()
        .navigationTitle("Settings")
    }

    // MARK: Auto-cache (ask #7)

    private var autoCacheSection: some View {
        @Bindable var autoCache = model.autoCache

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Auto-cache", detail: "Keep the music you play most ready offline")

            VStack(spacing: 0) {
                Toggle(isOn: $autoCache.isEnabled) {
                    settingsLabel("Automatic downloads", "Quietly cache your most-played songs",
                                  icon: "bolt.badge.automatic")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                HStack(spacing: 12) {
                    settingsLabel("Maximum storage", "Auto-cache won’t grow past this",
                                  icon: "internaldrive")
                    Spacer()
                    Picker("Maximum storage", selection: $autoCache.budgetBytes) {
                        ForEach(AutoCacheController.budgetPresets, id: \.self) { bytes in
                            Text(AutoCacheController.byteLabel(bytes)).tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .tint(DesignTokens.brandPrimary)
                }
                .padding(12)

                rowDivider

                Toggle(isOn: $autoCache.wifiOnly) {
                    settingsLabel("Wi-Fi only", "Don’t auto-cache on cellular", icon: "wifi")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                Toggle(isOn: $autoCache.protectFavorites) {
                    settingsLabel("Always keep favourites", "Favourites are never auto-evicted", icon: "star")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)

            HStack {
                Text(autoCache.lastReconcileSummary)
                    .font(.caption).foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button("Clear history", role: .destructive) { autoCache.resetStats() }
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Audio (ReplayGain / preamp / EQ)

    private var audioSection: some View {
        @Bindable var enhancements = model.engine.enhancements

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Audio", detail: "Volume levelling and a 5-band EQ (off by default)")
            VStack(spacing: 0) {
                Toggle(isOn: $enhancements.gaplessEnabled) {
                    settingsLabel("Gapless playback", "No silence between downloaded tracks", icon: "arrow.right.to.line")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                Toggle(isOn: $enhancements.replayGainEnabled) {
                    settingsLabel("ReplayGain", "Even out loudness between tracks", icon: "speaker.wave.2")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                if enhancements.replayGainEnabled {
                    rowDivider
                    Toggle(isOn: $enhancements.replayGainAlbumMode) {
                        settingsLabel("Album gain", "Keep each album's track-to-track loudness", icon: "square.stack")
                    }
                    .tint(DesignTokens.brandPrimary)
                    .padding(12)
                }

                rowDivider

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingsLabel("Crossfade", "Fade between tracks", icon: "wave.3.forward")
                        Spacer()
                        Text(enhancements.crossfadeSeconds < 0.5 ? "Off" : "\(enhancements.crossfadeSeconds, specifier: "%.0f")s")
                            .font(.caption.monospacedDigit()).foregroundStyle(DesignTokens.textSecondary)
                    }
                    Slider(value: $enhancements.crossfadeSeconds, in: 0...12, step: 1)
                        .tint(DesignTokens.brandPrimary)
                }
                .padding(12)

                rowDivider

                // EQ toggle sits directly above its bands (below crossfade).
                Toggle(isOn: $enhancements.eqEnabled) {
                    settingsLabel("Equalizer", "5-band graphic EQ", icon: "slider.vertical.3")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                if enhancements.eqEnabled {
                    rowDivider
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Preamp").font(.subheadline).foregroundStyle(DesignTokens.textPrimary)
                            Spacer()
                            Text("\(enhancements.preampDB, specifier: "%+.0f") dB")
                                .font(.caption.monospacedDigit()).foregroundStyle(DesignTokens.textSecondary)
                        }
                        Slider(value: $enhancements.preampDB, in: -12...12, step: 1)
                            .tint(DesignTokens.brandPrimary)

                        ForEach(Array(AudioEnhancements.eqFrequencies.enumerated()), id: \.offset) { index, freq in
                            HStack(spacing: 12) {
                                Text(Self.bandLabel(freq))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .frame(width: 44, alignment: .leading)
                                Slider(value: $enhancements.eqBandsDB[index], in: -12...12, step: 1)
                                    .tint(DesignTokens.brandPrimary)
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)

            Text("EQ uses an audio processor on playback; toggle off if you notice issues.")
                .font(.caption).foregroundStyle(DesignTokens.textTertiary)
                .padding(.horizontal, 4)
        }
        // Apply audio-enhancement changes to the CURRENTLY playing track, not just
        // the next one (debounced so dragging a slider re-preps once on release).
        .onChange(of: enhancements.gaplessEnabled) { _, _ in model.engine.gaplessSettingChanged() }
        .onChange(of: enhancements.eqEnabled) { _, _ in scheduleEnhancementsApply() }
        .onChange(of: enhancements.eqBandsDB) { _, _ in scheduleEnhancementsApply() }
        .onChange(of: enhancements.preampDB) { _, _ in scheduleEnhancementsApply() }
        .onChange(of: enhancements.replayGainEnabled) { _, _ in scheduleEnhancementsApply() }
        .onChange(of: enhancements.replayGainAlbumMode) { _, _ in scheduleEnhancementsApply() }
        .onChange(of: enhancements.crossfadeSeconds) { _, _ in
            scheduleEnhancementsApply()
            // Crossfade and gapless are mutually exclusive on a single player; raising
            // crossfade above 0 must drop any already-staged gapless preload, else it
            // would hard-advance once instead of crossfading.
            model.engine.gaplessSettingChanged()
        }
    }

    private static func bandLabel(_ freq: Double) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    // MARK: Artwork

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Artwork", detail: "Fill in covers your files don’t carry")
            VStack(spacing: 0) {
                Toggle(isOn: $onlineArtwork) {
                    settingsLabel("Online cover art",
                                  "Fetch missing covers from MusicBrainz / Cover Art Archive",
                                  icon: "photo.on.rectangle.angled")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)

                rowDivider

                Button { model.refreshArtwork() } label: {
                    HStack(spacing: 12) {
                        settingsLabel("Fetch missing covers", artworkStatusDetail,
                                      icon: "arrow.triangle.2.circlepath")
                        if model.isFetchingArtwork {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isFetchingArtwork)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)

            Text("Artist photos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(ArtistImageSource.allCases.enumerated()), id: \.element.id) { idx, source in
                    if idx > 0 { rowDivider }
                    Toggle(isOn: artistSourceBinding(source)) {
                        settingsLabel(source.title, source.detail, icon: "person.crop.circle")
                    }
                    .tint(DesignTokens.brandPrimary)
                    .padding(12)
                }
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    /// Live status for the artwork backfill row: scanning, all-covered, or a count
    /// of albums still missing a cover.
    private var artworkStatusDetail: String {
        if model.isFetchingArtwork { return "Fetching covers…" }
        let missing = model.albumsMissingArtworkCount
        return missing == 0 ? "Every album has a cover" : "\(missing) albums still need one — tap to scan"
    }

    /// Read/write an artist-photo source toggle (per-source UserDefaults key).
    /// Enabling one clears this session's photo misses so artist pages re-fetch.
    private func artistSourceBinding(_ source: ArtistImageSource) -> Binding<Bool> {
        Binding(
            get: { ArtistImageSource.isOn(source) },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: source.defaultsKey)
                if newValue { model.resetArtistImageAttempts() }
            }
        )
    }

    // MARK: Library maintenance

    private var librarySection: some View {
        let needsFix = model.metadataNeedsAttention.count
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Library", detail: "Fix tags your files got wrong")
            VStack(spacing: 0) {
                NavigationLink(value: LibraryRoute.fixMetadata) {
                    HStack(spacing: 12) {
                        settingsLabel("Fix metadata",
                                      needsFix == 0 ? "Nothing needs attention" : "\(needsFix) tracks need attention",
                                      icon: "pencil.and.list.clipboard")
                        if needsFix > 0 {
                            Text("\(needsFix)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(DesignTokens.brandPrimary, in: Capsule())
                        }
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)

                rowDivider

                Toggle(isOn: $classicalCredits) {
                    settingsLabel("Classical credits",
                                  "Pull conductor, orchestra, soloists, and composer from MusicBrainz when you open a classical album",
                                  icon: "music.quarternote.3")
                }
                .tint(DesignTokens.brandPrimary)
                .padding(12)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sources")
            VStack(spacing: 0) {
                NavigationLink { SourceSetupView() } label: {
                    settingsLabel("Add music source", "Connect an SMB share or server", icon: "externaldrive.badge.plus")
                        .padding(12)
                }
                .buttonStyle(.plain)
                rowDivider
                NavigationLink(value: LibraryRoute.sources) {
                    settingsLabel("Manage sources", model.sources.isEmpty ? "No sources yet" : "\(model.sources.count) configured",
                                  icon: "server.rack")
                        .padding(12)
                }
                .buttonStyle(.plain)
            }
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")
            VStack(alignment: .leading, spacing: 6) {
                Text("Better Streaming")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Text("Your own music library from your NAS or server. Open source, private by design — nothing leaves your devices and your network.")
                    .font(.caption).foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }

    // MARK: Helpers

    private func settingsLabel(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.textPrimary)
                Text(detail).font(.caption).foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
    }

    private var rowDivider: some View {
        Divider().overlay(DesignTokens.borderSubtle.opacity(0.08)).padding(.leading, 52)
    }
}
