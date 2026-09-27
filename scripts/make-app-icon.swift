#!/usr/bin/env swift
//
// make-app-icon.swift
//
// Renders the Meeting Assistant macOS app icon master PNG at 1024x1024.
//
// Usage:
//   swift scripts/make-app-icon.swift <output-dir>
//
// Writes <output-dir>/icon_1024.png. Feed that file to `sips -z <h> <w>`
// to produce the smaller sizes needed by an AppIcon.appiconset.
//
// The icon reads as "listening to a conversation, with a helpful AI
// answer": a white audio waveform (the call being transcribed) is
// overlapped at the lower right by a small white speech bubble holding
// a sparkle (the live AI suggestion). The body is a macOS Big Sur-style
// squircle with a soft drop shadow and an indigo-to-teal gradient.
//
// Colors live in one place below so the owner can restyle without
// hunting through the drawing code. Layout numbers are grouped at the
// top of each draw function for the same reason.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Colors (tweak here)

/// Squircle body gradient: deep indigo (top-left) to teal (bottom-right).
let colorGradientTopLeft     = NSColor(srgbRed: 0x31 / 255.0, green: 0x2E / 255.0, blue: 0x81 / 255.0, alpha: 1.0) // #312E81
let colorGradientBottomRight = NSColor(srgbRed: 0x0F / 255.0, green: 0x76 / 255.0, blue: 0x6E / 255.0, alpha: 1.0) // #0F766E

/// Faint lightening across the top third of the body, for a glassy lift.
let colorTopHighlight = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.20)

/// Drop shadow cast by the squircle onto the transparent canvas.
let colorBodyShadow = CGColor(gray: 0.0, alpha: 0.40)

/// The waveform bars (the call being listened to).
let colorWaveform = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)

/// The speech bubble (the AI answer) and its own small lift-off shadow.
let colorBubble       = NSColor.white
let colorBubbleShadow = CGColor(gray: 0.0, alpha: 0.30)

/// Sparkle inside the bubble, tinted to match the body so it reads as
/// "the assistant speaking" rather than a random accent color.
let colorSparkle = colorGradientTopLeft

// MARK: - Canvas

let canvasSize: CGFloat = 1024

// MARK: - Drawing

func drawBody(in ctx: CGContext) {
    let inset: CGFloat = 100
    let cornerRadius: CGFloat = 185
    let bodyRect = CGRect(x: inset, y: inset, width: canvasSize - inset * 2, height: canvasSize - inset * 2)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft drop shadow (macOS Big Sur+ style). Cast from a separate fill
    // of the same shape so clipping the gradient below doesn't clip the
    // shadow along with it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 48, color: colorBodyShadow)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(bodyPath)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient body, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let bodyGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [colorGradientTopLeft.cgColor, colorGradientBottomRight.cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) else { fatalError("Could not build body gradient") }

    ctx.drawLinearGradient(
        bodyGradient,
        start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
        options: []
    )

    guard let highlightGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [colorTopHighlight.cgColor, colorTopHighlight.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) else { fatalError("Could not build highlight gradient") }

    ctx.drawLinearGradient(
        highlightGradient,
        start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.midX, y: bodyRect.maxY - bodyRect.height * 0.55),
        options: []
    )

    ctx.restoreGState()
}

func drawWaveform(in ctx: CGContext) {
    // Five rounded capsule bars, tallest in the middle, like a still frame
    // of an audio waveform. Centered left-of-middle so the bubble has room
    // to sit over its lower-right corner. Bars are kept wide relative to
    // their gaps (and no bar is too short) so the group still reads as a
    // solid, deliberate shape once downsampled to 16x16.
    let barWidth: CGFloat = 84
    let barSpacing: CGFloat = 18
    let heights: [CGFloat] = [220, 340, 460, 350, 250]
    let groupCenterX: CGFloat = 420
    let groupCenterY: CGFloat = 526

    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * barSpacing
    var x = groupCenterX - totalWidth / 2

    ctx.saveGState()
    ctx.setFillColor(colorWaveform.cgColor)
    for height in heights {
        let rect = CGRect(x: x, y: groupCenterY - height / 2, width: barWidth, height: height)
        let barPath = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
        x += barWidth + barSpacing
    }
    ctx.restoreGState()
}

/// A simple four-point sparkle: four outer spikes with the edges between
/// them pulled in toward an inner radius, like the SF Symbols "sparkle".
func sparklePath(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> CGPath {
    let north = CGPoint(x: center.x, y: center.y + outerRadius)
    let east  = CGPoint(x: center.x + outerRadius, y: center.y)
    let south = CGPoint(x: center.x, y: center.y - outerRadius)
    let west  = CGPoint(x: center.x - outerRadius, y: center.y)

    let northEast = CGPoint(x: center.x + innerRadius, y: center.y + innerRadius)
    let southEast = CGPoint(x: center.x + innerRadius, y: center.y - innerRadius)
    let southWest = CGPoint(x: center.x - innerRadius, y: center.y - innerRadius)
    let northWest = CGPoint(x: center.x - innerRadius, y: center.y + innerRadius)

    let path = CGMutablePath()
    path.move(to: north)
    path.addQuadCurve(to: east, control: northEast)
    path.addQuadCurve(to: south, control: southEast)
    path.addQuadCurve(to: west, control: southWest)
    path.addQuadCurve(to: north, control: northWest)
    path.closeSubpath()
    return path
}

func drawBubble(in ctx: CGContext) {
    // Positioned in the lower right of the body so it overlaps the base
    // of the tallest right-hand waveform bars, like a suggestion popping
    // up over the call.
    let bubbleRect: CGRect = CGRect(x: 556, y: 200, width: 320, height: 260)
    let bubbleRadius: CGFloat = 64

    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubbleRect, cornerWidth: bubbleRadius, cornerHeight: bubbleRadius)

    // Small tail pointing back down toward the waveform.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: bubbleRect.minX + 70, y: bubbleRect.minY + 18))
    tail.addLine(to: CGPoint(x: bubbleRect.minX + 18, y: bubbleRect.minY - 40))
    tail.addLine(to: CGPoint(x: bubbleRect.minX + 96, y: bubbleRect.minY + 2))
    tail.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: colorBubbleShadow)
    ctx.setFillColor(colorBubble.cgColor)
    ctx.addPath(bubblePath)
    ctx.addPath(tail)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setFillColor(colorSparkle.cgColor)
    ctx.addPath(sparklePath(center: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY), outerRadius: 58, innerRadius: 20))
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Rendering

func renderIcon() -> NSBitmapImageRep {
    let pixelSize = Int(canvasSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("Could not allocate bitmap") }

    // Set the rep's logical size to match its pixel size so we always get
    // an exact 1:1 canvas regardless of the host's display scale.
    rep.size = NSSize(width: canvasSize, height: canvasSize)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        fatalError("Could not create a graphics context for the bitmap")
    }

    ctx.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    drawBody(in: ctx)
    drawWaveform(in: ctx)
    drawBubble(in: ctx)

    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG data")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("Could not write \(url.path): \(error)")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("Usage: swift scripts/make-app-icon.swift <output-dir>")
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icon = renderIcon()
let outputURL = outputDirectory.appendingPathComponent("icon_1024.png")
writePNG(icon, to: outputURL)
print("Wrote \(outputURL.path)")
