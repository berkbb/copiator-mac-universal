// SPDX-License-Identifier: GPL-3.0-or-later
// Copiator uygulama simgesini (AppIcon.icns) çizer. Geçici tasarım: iki üst üste disk ve eşitleme okları.
// Kullanım: swift Scripts/make_icon.swift Resources/AppIcon.icns [--preview önizleme.png]
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first ?? "AppIcon.icns"
let previewPath = arguments.firstIndex(of: "--preview").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// 1024×1024 koordinat sisteminde çizer (orijin sol altta).
func drawIcon(in ctx: CGContext) {
    // macOS simge ızgarası: 824 pt gövde, 100 pt kenar boşluğu.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = roundedRect(body, 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0x0F766E))
    ctx.fillPath()
    ctx.restoreGState()

    // Arka plan: turkuaz → mavi → çivit
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0x2DD4BF), rgb(0x0EA5E9), rgb(0x4F46E5)], [0, 0.5, 1]),
        start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: []
    )
    // Cam parlaması
    ctx.drawLinearGradient(
        gradient([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: []
    )
    ctx.restoreGState()

    // İki disk: arkadaki (kaynak) yarı saydam, öndeki (hedef) beyaz.
    func drive(_ rect: CGRect, fill: CGColor, led: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x1E1B4B, 0.35))
        ctx.addPath(roundedRect(rect, 48))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
        // Alt şerit ve ışık
        ctx.addPath(roundedRect(CGRect(x: rect.minX + 46, y: rect.minY + 40, width: rect.width - 92, height: 18), 9))
        ctx.setFillColor(rgb(0x94A3B8, 0.45))
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: rect.maxX - 92, y: rect.minY + 76, width: 30, height: 30))
        ctx.setFillColor(led)
        ctx.fillPath()
    }
    drive(CGRect(x: 236, y: 470, width: 552, height: 220), fill: rgb(0xFFFFFF, 0.55), led: rgb(0x2DD4BF))
    drive(CGRect(x: 236, y: 214, width: 552, height: 220), fill: rgb(0xFFFFFF, 0.97), led: rgb(0x22C55E))

    // Eşitleme okları: disklerin üzerinde iki yay ve uç.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(46)
    ctx.setStrokeColor(rgb(0x312E81))
    let center = CGPoint(x: 512, y: 452)
    let radius: CGFloat = 170
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    ctx.strokePath()
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
    ctx.strokePath()
    func arrowHead(at angle: CGFloat, clockwiseTip: Bool) {
        let tip = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        let direction: CGFloat = clockwiseTip ? -1 : 1
        let tangent = CGPoint(x: -sin(angle) * direction, y: cos(angle) * direction)
        let normal = CGPoint(x: cos(angle), y: sin(angle))
        let size: CGFloat = 70
        ctx.move(to: CGPoint(x: tip.x + tangent.x * size, y: tip.y + tangent.y * size))
        ctx.addLine(to: CGPoint(x: tip.x + normal.x * size, y: tip.y + normal.y * size))
        ctx.addLine(to: CGPoint(x: tip.x - normal.x * size, y: tip.y - normal.y * size))
        ctx.closePath()
        ctx.setFillColor(rgb(0x312E81))
        ctx.fillPath()
    }
    arrowHead(at: .pi * 0.85, clockwiseTip: false)
    arrowHead(at: .pi * 1.85, clockwiseTip: false)
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Copiator-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (size, name) in variants {
    try png(size: size).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil başarısız oldu\n".data(using: .utf8)!)
    exit(1)
}
if let previewPath {
    try png(size: 512).write(to: URL(fileURLWithPath: previewPath))
}
print("Simge oluşturuldu: \(outputPath)")
