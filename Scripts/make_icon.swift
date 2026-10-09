// Draws the 课序 app icon: a week of course blocks with the current lesson lit in coral,
// matching the in-app "now" color. Usage:
//   swift Scripts/make_icon.swift <output-directory>
// Writes AppIcon.png, AppIcon-dark.png and AppIcon-tinted.png (1024 × 1024) for the
// asset catalog, plus BrandMark.png / BrandMark-dark.png (360 × 360) for in-app use.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

enum Appearance { case light, dark, tinted }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// One column of the timetable: block heights from top to bottom, and which block is "now".
struct Column { var heights: [CGFloat]; var muted: Set<Int>; var now: Int? }

let canvas: CGFloat = 1024
let top: CGFloat = 184, left: CGFloat = 184, columnWidth: CGFloat = 200, gap: CGFloat = 28, radius: CGFloat = 46
let columns = [
    Column(heights: [184, 264, 152], muted: [2], now: nil),
    Column(heights: [144, 184, 272], muted: [0], now: 1),
    Column(heights: [264, 152, 184], muted: [1], now: nil),
]

func draw(_ appearance: Appearance, size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let scale = CGFloat(size) / canvas
    // Work in a top-left origin so the layout reads like the timetable it depicts.
    context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: scale, y: -scale)
    context.interpolationQuality = .high

    // Background
    let background: [CGColor]
    switch appearance {
    case .light: background = [rgb(0x1C9A88), rgb(0x0B5D52)]
    case .dark: background = [rgb(0x15302B), rgb(0x08130F)]
    case .tinted: background = [rgb(0x2A2A2A), rgb(0x050505)]
    }
    let gradient = CGGradient(colorsSpace: space, colors: background as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: canvas, y: canvas), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if appearance == .light {
        // Soft light from the top-left keeps the flat color from looking printed.
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 220, y: 140), startRadius: 0, endCenter: CGPoint(x: 220, y: 140), endRadius: 760, options: [])
    }

    for (index, column) in columns.enumerated() {
        var y = top
        let x = left + CGFloat(index) * (columnWidth + gap)
        for (row, height) in column.heights.enumerated() {
            let rect = CGRect(x: x, y: y, width: columnWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if column.now == row {
                context.saveGState()
                let shadow: CGColor = appearance == .light ? rgb(0x04362F, 0.45) : rgb(0x000000, 0.6)
                context.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: shadow)
                context.addPath(path); context.setFillColor(rgb(0xF0573F)); context.fillPath()
                context.restoreGState()
                context.saveGState()
                context.addPath(path); context.clip()
                let colors: [CGColor] = appearance == .tinted ? [rgb(0xFFFFFF), rgb(0xF2F2F2)] : [rgb(0xFF9466), rgb(0xEE4F3D)]
                let fill = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
                context.drawLinearGradient(fill, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
                context.restoreGState()
            } else {
                let muted = column.muted.contains(row)
                let color: CGColor
                switch appearance {
                case .light: color = rgb(0xFFFFFF, muted ? 0.26 : 0.95)
                case .dark: color = rgb(0xBFEDE4, muted ? 0.16 : 0.86)
                case .tinted: color = rgb(0xFFFFFF, muted ? 0.18 : 0.62)
                }
                context.addPath(path); context.setFillColor(color); context.fillPath()
            }
            y += height + gap
        }
    }
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, appearance, size) in [("AppIcon", Appearance.light, 1024), ("AppIcon-dark", .dark, 1024), ("AppIcon-tinted", .tinted, 1024),
                                 ("BrandMark", .light, 360), ("BrandMark-dark", .dark, 360)] {
    try draw(appearance, size: size).write(to: output.appendingPathComponent("\(name).png"))
}
print("Icons written to \(output.path)")
