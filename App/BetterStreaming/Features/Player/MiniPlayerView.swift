import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var environment: AppEnvironment
    var state: MiniPlayerState

    @State private var isShowingPlayer = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressBar(value: state.progress, tint: DesignTokens.brandPrimary)
                .frame(height: 2)

            HStack(spacing: 12) {
                MediaArtwork(symbol: state.artworkSymbol, status: state.status, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                    Text(state.subtitle)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                StatusPill(
                    label: state.statusLabel,
                    systemImage: state.status.systemImage,
                    tint: state.status == .missingSource ? DesignTokens.error : DesignTokens.connectionTeal
                )
                .fixedSize()

                Button {
                    environment.togglePlayback()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.textPrimary)

                Button {
                    isShowingPlayer = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
        .background(DesignTokens.surfaceChromeGlass.opacity(DesignTokens.chromeOpacity))
        .contentShape(Rectangle())
        .onTapGesture {
            isShowingPlayer = true
        }
        .gesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width < -40 {
                        environment.skipForward()
                    }
                }
        )
        .sheet(isPresented: $isShowingPlayer) {
            NowPlayingView()
                .environmentObject(environment)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mini player, \(state.title), \(state.statusLabel)")
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 18) {
                    MediaArtwork(
                        symbol: environment.nowPlaying.artworkSymbol,
                        status: environment.nowPlaying.status,
                        size: 280
                    )
                    .shadow(color: DesignTokens.brandPrimary.opacity(0.12), radius: 28, y: 16)

                    VStack(spacing: 5) {
                        Text(environment.nowPlaying.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text("\(environment.nowPlaying.artist) - \(environment.nowPlaying.album)")
                            .font(.subheadline)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                }

                VStack(spacing: 8) {
                    ProgressBar(value: environment.miniPlayer.progress, tint: DesignTokens.brandPrimary)
                    HStack {
                        Text(environment.nowPlaying.elapsed)
                        Spacer()
                        Text(environment.nowPlaying.duration)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignTokens.textTertiary)
                }

                HStack(spacing: 14) {
                    Button {} label: {
                        Image(systemName: "shuffle")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {} label: {
                        Image(systemName: "backward.fill")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {
                        environment.togglePlayback()
                    } label: {
                        Image(systemName: environment.nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.bold))
                            .frame(width: 66, height: 66)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())

                    Button {
                        environment.skipForward()
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {} label: {
                        Image(systemName: "repeat")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }

                HStack(spacing: 8) {
                    StatusPill(label: environment.nowPlaying.sourceName, systemImage: "server.rack", tint: DesignTokens.connectionTeal)
                    CacheStatusPill(status: environment.nowPlaying.status)
                    StatusPill(label: "Queue \(environment.queue.count)", systemImage: "list.bullet", tint: DesignTokens.brandPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                QueuePanel(queue: environment.queue)
            }
            .padding(DesignTokens.phonePadding)
        }
        .background(
            ZStack {
                DesignTokens.surfaceCanvas.ignoresSafeArea()
                RadialGradient(
                    colors: [DesignTokens.brandPrimary.opacity(0.14), .clear],
                    center: .top,
                    startRadius: 40,
                    endRadius: 420
                )
                .ignoresSafeArea()
            }
        )
    }
}

private struct QueuePanel: View {
    var queue: [QueueEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Up Next", detail: "Queue state is shown locally for this MVP shell")

            VStack(spacing: 0) {
                ForEach(Array(queue.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(index == 0 ? DesignTokens.brandPrimary : DesignTokens.textTertiary)
                            .frame(width: 22, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignTokens.textPrimary)
                                .lineLimit(1)
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(entry.duration)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    .padding(.vertical, 9)

                    if entry.id != queue.last?.id {
                        Divider()
                            .overlay(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                    }
                }
            }
            .padding(.horizontal, 12)
            .surfaceCard(fill: DesignTokens.surfaceCard)
        }
    }
}

#Preview {
    MiniPlayerView(state: MiniPlayerState.placeholder)
        .environmentObject(AppEnvironment())
}
