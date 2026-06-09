import AppKit
import Foundation

// Humiqa-Markenfarben (Indigo -> Cyan Gradient)
func hex(_ h: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255.0,
            green: CGFloat((h >> 8) & 0xFF) / 255.0,
            blue: CGFloat(h & 0xFF) / 255.0, alpha: 1)
}
let indigo = hex(0x4F46E5)
let cyan = hex(0x0EA5E9)

// Rendert den humiqa-Mark (Gradient-Rundquadrat mit weissem H) als PNG.
// inset = Randanteil (0 = randlos, 0.1 = 10% Rand fuer App-Icons)
func renderMark(px: Int, inset: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext

    let full = CGFloat(px)
    let pad = full * inset
    let side = full - 2 * pad
    let rect = CGRect(x: pad, y: pad, width: side, height: side)
    let radius = side * (9.0 / 34.0)

    // Gradient-Rundquadrat
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.addPath(path); cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [indigo.cgColor, cyan.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad,
                          start: CGPoint(x: rect.minX, y: rect.maxY),
                          end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    cg.restoreGState()

    // Weisses H (Koordinaten aus dem 34er-SVG-Raster, top-down -> CG bottom-up)
    let glyph: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (8.5, 10.5, 4.5, 13),
        (14.5, 10.5, 5, 5),
        (14.5, 18.5, 5, 5),
        (21, 10.5, 4.5, 13)
    ]
    let s = side / 34.0
    cg.setFillColor(NSColor.white.cgColor)
    for (gx, gy, gw, gh) in glyph {
        let x = rect.minX + gx * s
        let w = gw * s
        let h = gh * s
        let y = rect.maxY - gy * s - h
        cg.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)")
}

let res = "/Users/ali/humibeam/HumibeamMac/Resources"
let appiconset = "\(res)/Assets.xcassets/AppIcon.appiconset"
let iconsetTmp = "/tmp/Humibeam.iconset"

// Menueleisten-Logo (randlos, klein)
write(renderMark(px: 18, inset: 0.02), "\(res)/menubar_icon.png")
write(renderMark(px: 36, inset: 0.02), "\(res)/menubar_icon@2x.png")
write(renderMark(px: 54, inset: 0.02), "\(res)/menubar_icon@3x.png")

// App-Icon-Set (mit ~10% Rand wie macOS-Icons)
let appIcons: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_64x64.png", 64), ("icon_64x64@2x.png", 128),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ("icon_1024x1024.png", 1024)
]
for (name, sz) in appIcons { write(renderMark(px: sz, inset: 0.10), "\(appiconset)/\(name)") }

// .iconset fuer iconutil -> .icns
let iconsetFiles: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
try? FileManager.default.removeItem(atPath: iconsetTmp)
try! FileManager.default.createDirectory(atPath: iconsetTmp, withIntermediateDirectories: true)
for (name, sz) in iconsetFiles { write(renderMark(px: sz, inset: 0.10), "\(iconsetTmp)/\(name)") }
print("DONE")
