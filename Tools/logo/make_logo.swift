// Draws the DayDayUP logo (天天 + an upward arrow) and writes:
//   logo.svg                       – vector master (glyphs converted to paths, no font needed)
//   preview.png                    – 1024 px preview
//   AppIcon.appiconset/…           – iOS (full-bleed 1024) and macOS (rounded-square, all sizes)
// Run:  swift Tools/logo/make_logo.swift <out-dir>
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Palette (matches DesignSystem.swift)
let grapeTop = NSColor(srgbRed: 0x82/255, green: 0x63/255, blue: 0xFF/255, alpha: 1)
let grapeBottom = NSColor(srgbRed: 0x55/255, green: 0x36/255, blue: 0xE0/255, alpha: 1)
let sunshine = NSColor(srgbRed: 0xFF/255, green: 0xC9/255, blue: 0x3C/255, alpha: 1)

// MARK: Geometry in a 1024 × 1024, y-down canvas

func glyphPath(_ text: String, fontName: String, size: CGFloat) -> CGPath {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for (g, p) in zip(glyphs, positions) {
            if let gp = CTFontCreatePathForGlyph(font, g, nil) {
                // Flip to y-down.
                path.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: 0).scaledBy(x: 1, y: -1))
            }
        }
    }
    return path
}

/// Places `path` so its bounding box is centred on `center` with the given height.
func place(_ path: CGPath, center: CGPoint, height: CGFloat) -> CGPath {
    let b = path.boundingBoxOfPath
    let s = height / b.height
    var t = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: s, y: s)
        .translatedBy(x: -b.midX, y: -b.midY)
    return path.copy(using: &t)!
}

let tian = glyphPath("天", fontName: "PingFangSC-Semibold", size: 400)
let charHeight: CGFloat = 318
/// Glyph plus a same-colour outline, so the strokes read boldly even at 16 px.
func bold(_ p: CGPath, width: CGFloat) -> [CGPath] {
    [p, p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)]
}
let tian1 = bold(place(tian, center: CGPoint(x: 298, y: 655), height: charHeight), width: 30)
let tian2 = bold(place(tian, center: CGPoint(x: 690, y: 468), height: charHeight), width: 30)

// Bold upward arrow at the top right: rounded shaft + head.
let arrowX: CGFloat = 868
let arrow = CGMutablePath()
let shaftWidth: CGFloat = 54
let shaftTop: CGFloat = 160, shaftBottom: CGFloat = 268
arrow.addPath(CGPath(roundedRect: CGRect(x: arrowX - shaftWidth / 2, y: shaftTop, width: shaftWidth, height: shaftBottom - shaftTop),
                     cornerWidth: shaftWidth / 2, cornerHeight: shaftWidth / 2, transform: nil))
let headHalf: CGFloat = 74, tipY: CGFloat = 70, baseY: CGFloat = 190
let head = CGMutablePath()
head.move(to: CGPoint(x: arrowX, y: tipY))
head.addLine(to: CGPoint(x: arrowX + headHalf, y: baseY))
head.addLine(to: CGPoint(x: arrowX - headHalf, y: baseY))
head.closeSubpath()
// Round the head's corners slightly with a fat stroke of the same colour.
let roundedHead = head.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 1)

// Rising "steps" underline in yellow: one under each 天, the second higher.
let step1 = CGPath(roundedRect: CGRect(x: 120, y: 862, width: 360, height: 52), cornerWidth: 26, cornerHeight: 26, transform: nil)
let step2 = CGPath(roundedRect: CGRect(x: 512, y: 675, width: 360, height: 52), cornerWidth: 26, cornerHeight: 26, transform: nil)

// MARK: Rendering

func drawArt(in ctx: CGContext, size: CGFloat, macStyle: Bool) {
    ctx.saveGState()
    // y-down
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: size / 1024, y: -size / 1024)

    var clip = CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil)
    if macStyle {
        // Big Sur style: 824 pt rounded square centred, with a soft shadow.
        let r = CGRect(x: 100, y: 100, width: 824, height: 824)
        clip = CGPath(roundedRect: r, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(clip); ctx.setFillColor(grapeBottom.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(clip); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [grapeTop.cgColor, grapeBottom.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])

    if macStyle {
        // Fit the full-bleed artwork inside the rounded square.
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }
    ctx.setFillColor(sunshine.cgColor)
    for p in [step1, step2, arrow, roundedHead, head] { ctx.addPath(p); ctx.fillPath() }
    ctx.setFillColor(NSColor.white.cgColor)
    for p in tian1 + tian2 { ctx.addPath(p); ctx.fillPath() }
    ctx.restoreGState()
}

func png(size: Int, macStyle: Bool) -> Data {
    // iOS icons must be opaque; macOS icons keep transparent corners.
    let alpha: CGImageAlphaInfo = macStyle ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    ctx.interpolationQuality = .high
    drawArt(in: ctx, size: CGFloat(size), macStyle: macStyle)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

// MARK: SVG

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    path.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>DayDayUP</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#8263FF"/><stop offset="1" stop-color="#5536E0"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="0" fill="url(#bg)"/>
  <g fill="#FFC93C">
    <path d="\(svgPathData(step1))"/>
    <path d="\(svgPathData(step2))"/>
    <path d="\(svgPathData(arrow))"/>
    <path d="\(svgPathData(roundedHead))"/>
    <path d="\(svgPathData(head))"/>
  </g>
  <g fill="#FFFFFF">
    \((tian1 + tian2).map { "<path d=\"\(svgPathData($0))\"/>" }.joined(separator: "\n    "))
  </g>
</svg>

"""
try! svg.write(to: outDir.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
try! png(size: 1024, macStyle: false).write(to: outDir.appendingPathComponent("preview.png"))
try! png(size: 1024, macStyle: true).write(to: outDir.appendingPathComponent("preview-mac.png"))
try! png(size: 64, macStyle: false).write(to: outDir.appendingPathComponent("preview-64.png"))

if CommandLine.arguments.count > 2 {
    // Asset catalog
    let set = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    try! png(size: 1024, macStyle: false).write(to: set.appendingPathComponent("icon-ios-1024.png"))
    images.append(["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
    for pt in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = pt * scale
            let name = "icon-mac-\(pt)@\(scale)x.png"
            try! png(size: px, macStyle: true).write(to: set.appendingPathComponent(name))
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: set.appendingPathComponent("Contents.json"))
}
print("done")
