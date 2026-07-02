import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
let creamStrong: UInt32 = 0xFFF7E0, cream: UInt32 = 0xFDEED0, ink: UInt32 = 0x0A0805

func render(_ name: String, glow: Bool) {
    let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.setFillColor(rgba(ink))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if glow {
        let g = CGGradient(colorsSpace: space, colors: [rgba(cream, 0.22), rgba(cream, 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: 600, y: 585), startRadius: 0, endCenter: CGPoint(x: 600, y: 585), endRadius: 360, options: [])
    }
    let moonR: CGFloat = 285
    let moonCenter = CGPoint(x: 452, y: 655)
    c.setFillColor(rgba(creamStrong))
    c.fillEllipse(in: CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2))
    let occCenter = CGPoint(x: moonCenter.x - 131, y: moonCenter.y + 105)
    c.saveGState()
    c.addEllipse(in: CGRect(x: occCenter.x - moonR, y: occCenter.y - moonR, width: moonR * 2, height: moonR * 2))
    c.clip()
    c.setFillColor(rgba(ink))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if glow {
        let g = CGGradient(colorsSpace: space, colors: [rgba(cream, 0.22), rgba(cream, 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: 600, y: 585), startRadius: 0, endCenter: CGPoint(x: 600, y: 585), endRadius: 360, options: [])
    }
    c.restoreGState()
    // waveform
    let heights: [CGFloat] = [96, 168, 240, 168, 96]
    let barW: CGFloat = 52, gap: CGFloat = 34
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (1024 - totalW) / 2
    for h in heights {
        let r = CGRect(x: x, y: 250 - h / 2, width: barW, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        c.setFillColor(rgba(creamStrong))
        c.fillPath()
        x += barW + gap
    }
    let img = c.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
render("iconI.png", glow: false)

print("done")
