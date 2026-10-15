import AppKit
import SwiftUI

// StepFun (阶跃星辰) mark, from www.stepfun.com/step_favicon.svg: a disc with five stair-step squares cut out.
enum Brand {
    static let name = "StepBar"
    // #00A9FF, the accent on stepfun.com.
    static let blue = Color(red: 0, green: 169 / 255, blue: 1)
    static let squares: [CGRect] = [(3.65, 12.69), (8.17, 12.69), (8.17, 8.17), (8.17, 3.66), (12.69, 3.65)]
        .map { CGRect(x: $0.0, y: $0.1, width: 3.65, height: 3.65) }

    // The mark in `rect` (y-down, as in the SVG), squares as holes so whatever is behind shows through.
    static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 20
        let transform = CGAffineTransform(translationX: rect.midX - 10 * scale, y: rect.midY - 10 * scale).scaledBy(x: scale, y: scale)
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: 20, height: 20), transform: transform)
        for square in squares { path.addRect(square, transform: transform) }
        return path
    }
    // Template image: menu bar and panel tint it to fit light and dark appearance.
    static func mark(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path(in: rect)); context.setFillColor(NSColor.black.cgColor); context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        return image
    }
    // App icon: white mark on a near-black squircle, in the macOS icon grid (824 of 1024, radius 185).
    static func icon(pixels: Int) -> Data? {
        let side = CGFloat(pixels)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: side); context.scaleBy(x: 1, y: -1)
        let unit = side / 1024, tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let squircle = CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
        context.saveGState()
        context.addPath(squircle); context.clip()
        let colors = [CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1), CGColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        }
        context.restoreGState()
        context.addPath(path(in: tile.insetBy(dx: 190 * unit, dy: 190 * unit)))
        context.setFillColor(.white); context.fillPath(using: .evenOdd)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
    // `StepBar --make-icon <dir>.iconset`; build.sh turns it into AppIcon.icns with iconutil.
    static func writeIconset(_ folder: String) -> Bool {
        let url = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let data = icon(pixels: points * scale), (try? data.write(to: url.appendingPathComponent(name))) != nil else { return false }
            }
        }
        return true
    }
}

struct BrandMark: View {
    var size: CGFloat
    var body: some View { Image(nsImage: Brand.mark(size: size)).renderingMode(.template).resizable().frame(width: size, height: size) }
}
