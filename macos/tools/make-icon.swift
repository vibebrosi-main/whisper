// Generator ikony aplikacji: rysuje ją w CoreGraphics i składa AppIcon.icns
// przez iconutil. Ten sam motyw co ikona rozszerzenia (tools/make-icons.mjs):
// fala z pięciu słupków na niebieskim tle, tylko w proporcjach macOS.
//
//   swift macos/tools/make-icon.swift
//
// Wynik trafia do macos/Resources/AppIcon.icns i jest w repo, więc zwykły
// build go nie generuje.

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

/// Wysokości słupków fali (ułamek boku kafla), jak w ikonie rozszerzenia.
let bars: [CGFloat] = [0.28, 0.52, 0.86, 0.62, 0.34]

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Siatka ikon macOS: kafel 824/1024 wyśrodkowany, róg ~22,5% kafla.
    let tile = s * 824 / 1024
    let rect = CGRect(x: (s - tile) / 2, y: (s - tile) / 2, width: tile, height: tile)
    let shape = CGPath(roundedRect: rect, cornerWidth: tile * 0.225, cornerHeight: tile * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0B57D0))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient od jaśniejszego niebieskiego u góry: M3 primary 0B57D0.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(0x4C8DF6), rgb(0x0B57D0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Fala: zaokrąglone słupki, wyśrodkowane w pionie.
    let barWidth = tile * 0.085
    let gap = tile * 0.06
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    var x = rect.midX - total / 2
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for fraction in bars {
        let height = fraction * tile * 0.62
        let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil: \(iconutil.terminationStatus)") }
print("Zapisano \(output.path)")
