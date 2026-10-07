import AppKit
let destination = CommandLine.arguments[1]
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.96, green: 0.975, blue: 0.95, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let deep = NSColor(srgbRed: 0.06, green: 0.40, blue: 0.35, alpha: 1)
let mint = NSColor(srgbRed: 0.72, green: 0.85, blue: 0.77, alpha: 1)
let gold = NSColor(srgbRed: 0.88, green: 0.74, blue: 0.43, alpha: 1)
func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    color.setFill(); NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h),xRadius:34,yRadius:34).fill()
}
for x in [CGFloat(185), 419, 653] { block(x, 738, 186, 58, deep) }
block(185, 430, 186, 268, deep)
block(185, 228, 186, 166, mint)
block(419, 532, 186, 166, mint)
block(419, 228, 186, 268, deep)
block(653, 430, 186, 268, deep)
block(653, 228, 186, 166, gold)
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: destination))
