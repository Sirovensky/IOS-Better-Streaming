import ImageIO
import SwiftUI
import UIKit

/// Decoded, downsampled cover thumbnails keyed by path — so a scrolling list
/// never decodes a full-resolution cover on the main thread (the old
/// `UIImage(contentsOfFile:)` in `body` did exactly that, per visible row, which
/// caused the scroll lag on large result lists).
enum ThumbnailLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    static func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: "\(url.path)#\(Int(maxPixel))" as NSString)
    }

    /// Load a file-URL image downsampled to ~`maxPixel` px, off the main thread,
    /// cached. Returns nil on failure.
    static func thumbnail(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

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
    /// Downsample target in pixels. Default suits list rows; detail headers pass
    /// larger. Decode happens off the main thread and is cached.
    var maxPixel: CGFloat = 200

    @State private var image: UIImage?

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
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if url == nil {
                    Image(systemName: glyph)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                // While a real cover loads, the gradient shows (no glyph flash).
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) { await loadImage() }
    }

    private func loadImage() async {
        guard let url else { image = nil; return }
        // Sync cache hit first → no flicker for already-decoded covers.
        if let hit = ThumbnailLoader.cached(url, maxPixel: maxPixel) { image = hit; return }
        if url.isFileURL {
            image = await ThumbnailLoader.thumbnail(for: url, maxPixel: maxPixel)
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
        }
    }
}
