#!/usr/bin/env swift
// Renders AgentDeck's app icon (1024×1024 PNG) with CoreGraphics.
//   swift scripts/render-icon.swift <out.png>
// Then scripts/make-appicon.sh builds the asset catalog sizes from it.
//
// Design: a deck of three terminal cards (parallel agent sessions), the front
// one showing a prompt, with a small sparkle for "agent". macOS icon grid:
// 824×824 rounded square inside a 1024 canvas.

import AppKit
import CoreText

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// macOS-style continuous-corner rounded rect (good enough approximation).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// MARK: Background tile

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile, radius: 186)

// Drop shadow under the tile (macOS icons carry their own).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x141B33))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x2A3A6E), rgb(0x161E3D), rgb(0x0B1022)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft glow behind the cards.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x5EF2B5, 0.22), rgb(0x5EF2B5, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 540, y: 470), endRadius: 420, options: [])
// Top highlight.
let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Thin inner stroke for definition on dark docks.
ctx.addPath(squircle(tile.insetBy(dx: 1.5, dy: 1.5), radius: 185))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

// MARK: Cards

struct Card { let rect: CGRect; let angle: CGFloat; let fill: CGColor; let stroke: CGColor }

func drawCard(_ c: Card, front: Bool) {
    ctx.saveGState()
    let center = CGPoint(x: c.rect.midX, y: c.rect.midY)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: c.angle * .pi / 180)
    ctx.translateBy(x: -center.x, y: -center.y)

    let path = squircle(c.rect, radius: 46)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, front ? 0.45 : 0.30))
    ctx.addPath(path)
    ctx.setFillColor(c.fill)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(c.stroke)
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Title bar with three dots.
    let barY = c.rect.maxY - 58
    for (i, color) in [0xFF6B6B, 0xFFC861, 0x5EF2B5].enumerated() {
        let d = CGRect(x: c.rect.minX + 40 + CGFloat(i) * 36, y: barY, width: 22, height: 22)
        ctx.setFillColor(rgb(UInt32(color), front ? 1 : 0.55))
        ctx.fillEllipse(in: d)
    }
    ctx.setStrokeColor(rgb(0xFFFFFF, front ? 0.10 : 0.06))
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: c.rect.minX + 4, y: barY - 24))
    ctx.addLine(to: CGPoint(x: c.rect.maxX - 4, y: barY - 24))
    ctx.strokePath()

    if front {
        // Prompt "❯_" in mint.
        let font = CTFontCreateWithName("SFMono-Bold" as CFString, 150, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x5EF2B5),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "❯_", attributes: attrs))
        ctx.textPosition = CGPoint(x: c.rect.minX + 52, y: c.rect.minY + 150)
        CTLineDraw(line, ctx)

        // Two "output" lines.
        for (i, w) in [CGFloat(250), 170].enumerated() {
            let r = CGRect(x: c.rect.minX + 56, y: c.rect.minY + 92 - CGFloat(i) * 40, width: w, height: 18)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
            ctx.setFillColor(rgb(0xFFFFFF, i == 0 ? 0.28 : 0.16))
            ctx.fillPath()
        }
    } else {
        for (i, w) in [CGFloat(300), 220, 260].enumerated() {
            let r = CGRect(x: c.rect.minX + 44, y: barY - 80 - CGFloat(i) * 44, width: w, height: 16)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(rgb(0xFFFFFF, 0.10))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
}

let cardW: CGFloat = 520, cardH: CGFloat = 400
let back = Card(rect: CGRect(x: 270, y: 470, width: cardW, height: cardH), angle: 9,
                fill: rgb(0x34467F), stroke: rgb(0xFFFFFF, 0.10))
let mid = Card(rect: CGRect(x: 235, y: 395, width: cardW, height: cardH), angle: 3,
               fill: rgb(0x26335F), stroke: rgb(0xFFFFFF, 0.12))
let front = Card(rect: CGRect(x: 200, y: 240, width: cardW, height: cardH), angle: -4,
                 fill: rgb(0x0E1328), stroke: rgb(0x5EF2B5, 0.55))
drawCard(back, front: false)
drawCard(mid, front: false)
drawCard(front, front: true)

// MARK: Sparkle (the "agent")

func sparkle(center c: CGPoint, r: CGFloat, color: CGColor) {
    let p = CGMutablePath()
    let k = r * 0.24   // waist
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFFC861, 0.75))
    ctx.addPath(p)
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}
sparkle(center: CGPoint(x: 760, y: 755), r: 92, color: rgb(0xFFD27A))
sparkle(center: CGPoint(x: 838, y: 640), r: 38, color: rgb(0xFFE7B0))

// MARK: Save

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
