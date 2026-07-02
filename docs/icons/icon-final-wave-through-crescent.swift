import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
let ink: UInt32 = 0x0A0805, creamStrong: UInt32 = 0xFFF7E0

let moonC = CGPoint(x: 487, y: 512)
let moonR: CGFloat = 330
let occC = CGPoint(x: moonC.x - 151, y: moonC.y + 121)
let occR: CGFloat = 322

let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.setFillColor(rgba(ink))
c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

// Cream moon; ink occluder carves the crescent.
c.setFillColor(rgba(creamStrong))
c.fillEllipse(in: CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: moonR * 2, height: moonR * 2))
c.setFillColor(rgba(ink))
c.fillEllipse(in: CGRect(x: occC.x - occR, y: occC.y - occR, width: occR * 2, height: occR * 2))

// One waveform row crossing the whole moon, same-width bars, peak at center.
// Each bar is CREAM (visible over the dark hollow/background), then the part
// lying on the lit crescent is redrawn INK — the wave inverts as it crosses
// the light. Even-odd clip = moon minus occluder.
let heights: [CGFloat] = [120, 190, 300, 460, 300, 190, 120]
let barW: CGFloat = 30
let midY = moonC.y - 20   // slightly below center

// Row spans the VISIBLE crescent silhouette's horizontal extent, not the full
// circle. Left limit = lower horn tip (circle-intersection cusp), right limit
// = moon rim at its widest visible point. 25px padding to each.
func visibleLeftAt(_ y: CGFloat) -> CGFloat? {
    let md = moonR * moonR - (y - moonC.y) * (y - moonC.y)
    guard md >= 0 else { return nil }
    let mL = moonC.x - sqrt(md), mR = moonC.x + sqrt(md)
    let od = occR * occR - (y - occC.y) * (y - occC.y)
    guard od >= 0 else { return mL }
    let oL = occC.x - sqrt(od), oR = occC.x + sqrt(od)
    if oL <= mL { return oR < mR ? oR : nil }
    return mL
}
var silL = CGFloat.infinity
var yScan = moonC.y - moonR
while yScan <= moonC.y + moonR {
    if let vl = visibleLeftAt(yScan) { silL = min(silL, vl) }
    yScan += 0.05
}
let silR = moonC.x + moonR                       // rim visible at y = moonC.y
let pad: CGFloat = 25
let rowLeft = silL + pad
let totalW = (silR - pad) - rowLeft
let gap = (totalW - CGFloat(heights.count) * barW) / CGFloat(heights.count - 1)

func barPath(_ i: Int) -> CGPath {
    let x = rowLeft + CGFloat(i) * (barW + gap)
    let h = heights[i]
    return CGPath(roundedRect: CGRect(x: x, y: midY - h / 2, width: barW, height: h),
                  cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
}

// Pass 1: cream bars everywhere.
c.setFillColor(rgba(creamStrong))
for i in heights.indices { c.addPath(barPath(i)); c.fillPath() }

// Pass 2: ink over the lit-crescent region only.
c.saveGState()
c.addEllipse(in: CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: moonR * 2, height: moonR * 2))
c.addEllipse(in: CGRect(x: occC.x - occR, y: occC.y - occR, width: occR * 2, height: occR * 2))
c.clip(using: .evenOdd)
c.setFillColor(rgba(ink))
for i in heights.indices { c.addPath(barPath(i)); c.fillPath() }
c.restoreGState()

let img = c.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "iconFinal.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print(String(format: "silL=%.1f rowLeft=%.1f gap=%.2f totalW=%.1f rowRight=%.1f", silL, rowLeft, gap, totalW, rowLeft + totalW))
