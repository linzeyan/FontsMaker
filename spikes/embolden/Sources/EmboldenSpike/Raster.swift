import CoreGraphics
import Foundation

/// Binary (non-antialiased) rasterizer at a fixed 4 units/px over the em box
/// plus margin. Used as a geometry-independent oracle: if union were wrong,
/// its fill would disagree with filling outline and stroke separately.
final class Raster {
    static let size = 320
    static let unitsPerPixel: CGFloat = 4
    static let origin = CGPoint(x: -140, y: -260)

    let ctx: CGContext
    private let bytes: UnsafeMutablePointer<UInt8>

    init() {
        let n = Raster.size
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { fail("cannot create raster context") }
        ctx = c
        bytes = c.data!.assumingMemoryBound(to: UInt8.self)
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.scaleBy(x: 1 / Raster.unitsPerPixel, y: 1 / Raster.unitsPerPixel)
        ctx.translateBy(x: -Raster.origin.x, y: -Raster.origin.y)
        ctx.setFillColor(gray: 1, alpha: 1)
    }

    func clear() { memset(bytes, 0, ctx.bytesPerRow * Raster.size) }

    func fill(_ p: CGPath, _ rule: CGPathFillRule) {
        ctx.addPath(p)
        ctx.fillPath(using: rule)
    }

    func render(_ paths: [CGPath], _ rule: CGPathFillRule = .winding) -> [UInt8] {
        clear()
        for p in paths { fill(p, rule) }
        return Array(UnsafeBufferPointer(start: bytes, count: ctx.bytesPerRow * Raster.size))
    }
}

func mismatch(_ a: [UInt8], _ b: [UInt8]) -> Int {
    var n = 0
    for i in 0..<a.count where (a[i] > 127) != (b[i] > 127) { n += 1 }
    return n
}

func iou(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var inter = 0, uni = 0
    for i in 0..<a.count {
        let x = a[i] > 127, y = b[i] > 127
        if x && y { inter += 1 }
        if x || y { uni += 1 }
    }
    return uni == 0 ? 1 : Double(inter) / Double(uni)
}
