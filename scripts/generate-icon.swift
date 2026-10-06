#!/usr/bin/env swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: generate-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = CommandLine.arguments[1]

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Cannot create CGContext")
}

let r = CGFloat(size)
let rect = CGRect(x: 0, y: 0, width: r, height: r)

// Fond : rounded rect dark (forme d'icône macOS moderne)
let cornerRadius: CGFloat = r * 0.2237
let bgPath = CGPath(
    roundedRect: rect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
// Léger gradient haut → bas
let gradColors = [
    CGColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1),
    CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: r),
    end: CGPoint(x: 0, y: 0),
    options: []
)
ctx.restoreGState()

// Cercle rouge "REC" centré
let circleSize: CGFloat = r * 0.50
let circleRect = CGRect(
    x: (r - circleSize) / 2,
    y: (r - circleSize) / 2,
    width: circleSize,
    height: circleSize
)
// Ombre douce
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -r * 0.012),
    blur: r * 0.04,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
)
ctx.setFillColor(CGColor(red: 0.93, green: 0.24, blue: 0.24, alpha: 1))
ctx.fillEllipse(in: circleRect)
ctx.restoreGState()

// Halo blanc subtil au centre pour donner du relief
let highlightSize: CGFloat = circleSize * 0.35
let highlightRect = CGRect(
    x: circleRect.midX - highlightSize / 2,
    y: circleRect.midY + circleSize * 0.10,
    width: highlightSize,
    height: highlightSize * 0.45
)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
ctx.fillEllipse(in: highlightRect)

guard let cgImage = ctx.makeImage() else { fatalError("Cannot make CGImage") }

let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(
    url, UTType.png.identifier as CFString, 1, nil
) else {
    fatalError("Cannot create image destination")
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Cannot finalize PNG") }
print("Icon written: \(outPath)")
