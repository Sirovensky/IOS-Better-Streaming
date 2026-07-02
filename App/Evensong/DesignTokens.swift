import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Semantic design tokens. Per creative-direction.md: warm graphite surfaces,
/// cream/caramel primary, teal for connectivity, wine for favourites. Never
/// hard-code hex in views — go through these.
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

    static let phonePadding: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let cardRadius: CGFloat = 10
    static let artworkRadius: CGFloat = 8
    static let controlRadius: CGFloat = 10

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

// MARK: - Cache state / source health presentation

extension CacheState {
    var tint: Color {
        switch self {
        case .cached, .prefetched: DesignTokens.success
        case .downloading, .queued, .remoteOnly: DesignTokens.connectionTeal
        case .stale: DesignTokens.warning
        case .missingSource, .failed: DesignTokens.error
        }
    }
}

extension SourceHealth {
    var tint: Color {
        switch self {
        case .online: DesignTokens.success
        case .degraded, .asleep: DesignTokens.warning
        case .authFailed, .localNetworkBlocked, .unreachable: DesignTokens.error
        }
    }
}

// MARK: - Button styles

/// On-brand switch: cream track with a warm-INK thumb when on (the Play-button
/// pairing), raised gray with a light thumb when off. The system style tinted
/// cream turned the switch into a solid pill — the white thumb vanished — and
/// a gold tint read as off-palette caramel.
struct EvensongToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? DesignTokens.brandPrimary : DesignTokens.surfaceRaised)
                .overlay(
                    Capsule().strokeBorder(
                        DesignTokens.borderSubtle.opacity(configuration.isOn ? 0 : 0.18), lineWidth: 1)
                )
                .frame(width: 51, height: 31)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? DesignTokens.onBrandPrimary : Color.white.opacity(0.92))
                        .padding(3)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityRepresentation {
            Toggle(configuration.isOn ? "On" : "Off", isOn: configuration.$isOn)
        }
    }
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
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(DesignTokens.borderSubtleOpacity), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Surfaces

struct SurfaceCardModifier: ViewModifier {
    var fill: Color = DesignTokens.surfaceCard
    var borderOpacity: Double = DesignTokens.borderSubtleOpacity

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                    .stroke(DesignTokens.borderSubtle.opacity(borderOpacity), lineWidth: 1)
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
}

// MARK: - Shared components

struct SectionHeader: View {
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
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
                    .font(.subheadline.weight(.semibold))
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
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(tint.opacity(fillOpacity), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Pairs availability colour WITH an icon and label (never colour alone).
struct AvailabilityPill: View {
    var state: CacheState
    var body: some View {
        StatusPill(label: state.label, systemImage: state.systemImage, tint: state.tint)
    }
}

struct SourceHealthPill: View {
    var health: SourceHealth
    var body: some View {
        StatusPill(label: health.rawValue, systemImage: health.systemImage, tint: health.tint)
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
                .font(.title3.weight(.bold).monospacedDigit())
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

/// Thin scrub/progress line.
struct ProgressBar: View {
    var value: Double
    var tint: Color = DesignTokens.brandPrimary

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.borderSubtle.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Progress \(Int(value * 100)) percent")
    }
}
