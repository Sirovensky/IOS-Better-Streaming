import SwiftUI
import UIKit

/// Deterministic warm placeholder artwork derived from a stable key (album id,
/// playlist id, …). Per creative-direction.md: missing art uses a generated warm
/// graphite gradient, never blank grey. The same palette feeds both the SwiftUI
/// views and the lock-screen `UIImage` so they match.
enum Artwork {
    static func palette(for key: String) -> (top: Color, bottom: Color) {
        let (a, b) = uiPalette(for: key)
        return (Color(uiColor: a), Color(uiColor: b))
    }

    static func uiPalette(for key: String) -> (UIColor, UIColor) {
        let hash = stableHash(key)
        // Warm-biased hue wheel: caramels, wines, teals, dusk blues.
        let hue = Double(hash % 360) / 360.0
        let top = UIColor(hue: CGFloat(hue), saturation: 0.45, brightness: 0.52, alpha: 1)
        let bottom = UIColor(hue: CGFloat((hue + 0.08).truncatingRemainder(dividingBy: 1)), saturation: 0.55, brightness: 0.30, alpha: 1)
        return (top, bottom)
    }

    /// Render the placeholder to a UIImage for MPNowPlayingInfoCenter / lock screen.
    static func image(for key: String, glyph: String = "music.note", size: CGFloat = 600) -> UIImage {
        let (top, bottom) = uiPalette(for: key)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { ctx in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size, y: size),
                    options: []
                )
            }
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.32, weight: .semibold)
            if let symbol = UIImage(systemName: glyph, withConfiguration: config)?
                .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
    }

    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }
}

/// Reusable artwork tile. Loads `url` when present, otherwise draws the warm
/// placeholder gradient with a media glyph.
struct ArtworkView: View {
    var url: URL?
    var artworkKey: String
    var glyph: String = "music.note"
    var cornerRadius: CGFloat = 8

    var body: some View {
        let palette = Artwork.palette(for: artworkKey)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [palette.top, palette.bottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if let url {
                    if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Image(systemName: glyph)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
