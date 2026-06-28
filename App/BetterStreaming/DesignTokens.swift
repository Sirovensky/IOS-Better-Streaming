import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum DesignTokens {
    static let surfaceCanvas = adaptiveColor(dark: 0x050403, light: 0xFAF8F5)
    static let surfaceBase = adaptiveColor(dark: 0x0C0B09, light: 0xF5F2ED)
    static let surfaceCard = adaptiveColor(dark: 0x141211, light: 0xFFFEFA)
    static let surfaceRaised = adaptiveColor(dark: 0x1B1917, light: 0xFAF7F2)
    static let surfaceChromeGlass = adaptiveColor(dark: 0x1C1916, light: 0xFFFAF5)

    static let borderSubtle = adaptiveColor(dark: 0xFFFAF0, light: 0x1E1810)
    static let borderStrong = adaptiveColor(dark: 0xFFFAF0, light: 0x1E1810)

    static let textPrimary = adaptiveColor(dark: 0xF2EEF9, light: 0x1A1816)
    static let textSecondary = adaptiveColor(dark: 0xA8A4A0, light: 0x5A5550)
    static let textTertiary = adaptiveColor(dark: 0x7E7A76, light: 0x8A847C)

    static let brandPrimary = adaptiveColor(dark: 0xFDEED0, light: 0xA66D1F)
    static let brandPrimaryStrong = adaptiveColor(dark: 0xFFF7E0, light: 0xC2410C)
    static let onBrandPrimary = adaptiveColor(dark: 0x2B1400, light: 0xFFFFFF)

    static let connectionTeal = adaptiveColor(dark: 0x4DB8C9, light: 0x0E7A8A)
    static let favoriteWine = adaptiveColor(dark: 0xC5566D, light: 0x8E2D40)
    static let success = adaptiveColor(dark: 0x34C47E, light: 0x1F7A4A)
    static let warning = adaptiveColor(dark: 0xE8A33D, light: 0x8A5200)
    static let error = adaptiveColor(dark: 0xE2526C, light: 0xBA1A2E)

    static let background = surfaceCanvas
    static let surface = surfaceCard
    static let elevated = surfaceRaised
    static let primaryText = textPrimary
    static let secondaryText = textSecondary
    static let accent = brandPrimary
    static let warmAccent = brandPrimary
    static let danger = error

    static let phonePadding: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let compactRowHeight: CGFloat = 48
    static let cardRadius: CGFloat = 8
    static let artworkRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8

    static let borderSubtleOpacity = 0.08
    static let borderStrongOpacity = 0.16
    static let chromeOpacity = 0.72

    #if canImport(UIKit)
    private static func adaptiveColor(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? uiColor(hex: light) : uiColor(hex: dark)
        })
    }

    private static func uiColor(hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
    #else
    private static func adaptiveColor(dark: UInt32, light: UInt32) -> Color {
        Color(
            red: Double((dark >> 16) & 0xFF) / 255,
            green: Double((dark >> 8) & 0xFF) / 255,
            blue: Double(dark & 0xFF) / 255
        )
    }
    #endif
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DesignTokens.onBrandPrimary)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .fill(DesignTokens.brandPrimary.opacity(buttonOpacity(configuration: configuration)))
            )
            .appLiquidGlass(
                cornerRadius: DesignTokens.controlRadius,
                tint: DesignTokens.brandPrimary.opacity(0.28),
                interactive: true
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    private func buttonOpacity(configuration: Configuration) -> Double {
        guard isEnabled else { return 0.42 }
        return configuration.isPressed ? 0.78 : 1
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? DesignTokens.textPrimary : DesignTokens.textTertiary)
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .fill(DesignTokens.surfaceRaised.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .appLiquidGlass(
                cornerRadius: DesignTokens.controlRadius,
                tint: DesignTokens.surfaceRaised.opacity(0.24),
                interactive: true
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct SurfaceCardModifier: ViewModifier {
    var fill: Color = DesignTokens.surfaceCard
    var borderOpacity: Double = DesignTokens.borderSubtleOpacity

    func body(content: Content) -> some View {
        content
            .background(cardBackground)
            .appLiquidGlass(cornerRadius: DesignTokens.cardRadius, tint: fill.opacity(0.20))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(borderOpacity), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .fill(fill.opacity(0.42))
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .fill(fill)
        }
    }
}

extension View {
    func surfaceCard(
        fill: Color = DesignTokens.surfaceCard,
        borderOpacity: Double = DesignTokens.borderSubtleOpacity
    ) -> some View {
        modifier(SurfaceCardModifier(fill: fill, borderOpacity: borderOpacity))
    }

    func appScreenBackground() -> some View {
        background(DesignTokens.surfaceCanvas.ignoresSafeArea())
    }

    @ViewBuilder
    func appLiquidGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
        }
    }
}

struct SectionHeader: View {
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.brandPrimary)
            }
        }
    }
}

struct StatusPill: View {
    var label: String
    var systemImage: String
    var tint: Color
    var fillOpacity: Double = 0.14

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(tint.opacity(fillOpacity), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    var value: String
    var label: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.brandPrimary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(DesignTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .surfaceCard(fill: DesignTokens.surfaceRaised)
    }
}

struct AppEmptyState: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(DesignTokens.brandPrimary)
                .frame(width: 44, height: 44)
                .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.headline)
                .foregroundStyle(DesignTokens.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surfaceCard(fill: DesignTokens.surfaceCard)
    }
}

struct MediaArtwork: View {
    var symbol: String
    var status: CacheStatus
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.artworkRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(0.24),
                        DesignTokens.surfaceRaised,
                        DesignTokens.brandPrimary.opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: max(16, size * 0.34), weight: .semibold))
                    .foregroundStyle(tint)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: status.systemImage)
                    .font(.system(size: max(10, size * 0.20), weight: .bold))
                    .foregroundStyle(statusTint)
                    .padding(3)
                    .background(DesignTokens.surfaceCanvas, in: Circle())
                    .offset(x: 4, y: 4)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch status {
        case .cached, .prefetched:
            DesignTokens.brandPrimary
        case .downloading, .remoteOnly, .queued:
            DesignTokens.connectionTeal
        case .stale:
            DesignTokens.warning
        case .missingSource, .failed:
            DesignTokens.error
        }
    }

    private var statusTint: Color {
        switch status {
        case .cached, .prefetched:
            DesignTokens.success
        case .downloading, .remoteOnly, .queued:
            DesignTokens.connectionTeal
        case .stale:
            DesignTokens.warning
        case .missingSource, .failed:
            DesignTokens.error
        }
    }
}

struct CacheStatusPill: View {
    var status: CacheStatus

    var body: some View {
        StatusPill(label: status.label, systemImage: status.systemImage, tint: tint)
    }

    private var tint: Color {
        switch status {
        case .cached:
            DesignTokens.success
        case .downloading, .remoteOnly, .queued:
            DesignTokens.connectionTeal
        case .prefetched:
            DesignTokens.brandPrimary
        case .stale:
            DesignTokens.warning
        case .missingSource, .failed:
            DesignTokens.error
        }
    }
}

struct SourceHealthPill: View {
    var health: SourceHealth

    var body: some View {
        StatusPill(label: health.rawValue, systemImage: health.systemImage, tint: tint)
    }

    private var tint: Color {
        switch health {
        case .online:
            DesignTokens.connectionTeal
        case .degraded, .asleep:
            DesignTokens.warning
        case .authFailed, .localNetworkBlocked, .unreachable:
            DesignTokens.error
        }
    }
}

struct TrackRow: View {
    var track: MediaTrack
    var playAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(symbol: track.kind == .video ? "film" : "music.note", status: track.cacheStatus, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineLimit(1)
                    if track.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.favoriteWine)
                    }
                }

                Text("\(track.artist) - \(track.album)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)

                Text(track.folderPath.middleTruncated(maxLength: 44))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                Text(track.duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesignTokens.textTertiary)
                CacheStatusPill(status: track.cacheStatus)
                    .fixedSize()
            }

            Menu {
                Button("Play Now", systemImage: "play.fill", action: playAction)
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {}
                Button("Add to Queue", systemImage: "text.badge.plus") {}
                Button("Download", systemImage: "arrow.down.circle") {}
                Button("Reveal in Folder", systemImage: "folder") {}
                Button("Info", systemImage: "info.circle") {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .frame(width: 32, height: 44)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: playAction)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.cacheStatus.label)")
    }
}

struct FolderRow: View {
    var folder: LibraryFolder
    var playAction: () -> Void
    var shuffleAction: () -> Void
    var recursiveAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: folder.isPlayable ? "folder.fill" : "folder")
                    .font(.title3)
                    .foregroundStyle(folder.isPlayable ? DesignTokens.brandPrimary : DesignTokens.textTertiary)
                    .frame(width: 48, height: 48)
                    .background(DesignTokens.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if folder.isScanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DesignTokens.connectionTeal)
                        .padding(4)
                        .background(DesignTokens.surfaceCanvas, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(folder.isPlayable ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                Text("\(folder.sourceName) - \(folder.childSummary)")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                Text(folder.path.middleTruncated(maxLength: 48))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                StatusPill(
                    label: folder.scanState,
                    systemImage: folder.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle",
                    tint: folder.isScanning ? DesignTokens.connectionTeal : DesignTokens.textSecondary
                )
                CacheStatusPill(status: folder.cacheStatus)
            }
            .fixedSize()

            Menu {
                Button("Play Folder", systemImage: "play.fill", action: playAction)
                    .disabled(!folder.isPlayable)
                Button("Shuffle Folder", systemImage: "shuffle", action: shuffleAction)
                    .disabled(!folder.isPlayable)
                Button("Play Recursively - \(folder.recursiveCount)", systemImage: "folder.badge.plus", action: recursiveAction)
                Button("Shuffle Recursively", systemImage: "arrow.triangle.2.circlepath") {}
                Button("Add Recursively to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") {}
                Button("Download Recursively", systemImage: "arrow.down.circle") {}
                Button("Save as Live Playlist", systemImage: "rectangle.stack.badge.plus") {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .frame(width: 32, height: 44)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(folder.scanState), \(folder.cacheStatus.label)")
    }
}

struct ProgressBar: View {
    var value: Double
    var tint: Color = DesignTokens.brandPrimary

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Progress \(Int(value * 100)) percent")
    }
}

extension String {
    func middleTruncated(maxLength: Int) -> String {
        guard count > maxLength, maxLength > 8 else { return self }
        let sideCount = (maxLength - 3) / 2
        let start = prefix(sideCount)
        let end = suffix(maxLength - sideCount - 3)
        return "\(start)...\(end)"
    }
}
