#!/usr/bin/env swift

import AppKit
import CoreGraphics
import ImageIO

// MARK: - World Tree Icon Generator
// Draws a stylized Yggdrasil / World Tree symbol as the app icon.
// Design: Dark forest background, glowing sacred tree with organic branches and roots,
// inscribed in a golden ring. Norse/sacred geometry aesthetic.

func drawWorldTree(size: CGFloat) -> CGImage? {
    let px = Int(size)
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let w = size
    let h = size
    let cx = w / 2
    let cy = h / 2
    let r = w / 2 - (w * 0.04)

    // --- Background: deep forest gradient ---
    let bgGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.04, green: 0.10, blue: 0.06, alpha: 1.0),
            CGColor(red: 0.02, green: 0.06, blue: 0.03, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!

    let cornerRadius = w * 0.22
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: cx, y: h),
                           end: CGPoint(x: cx, y: 0),
                           options: [])
    ctx.resetClip()

    // --- Outer glow ring ---
    ctx.setLineWidth(w * 0.018)
    ctx.setStrokeColor(CGColor(red: 0.65, green: 0.85, blue: 0.45, alpha: 0.6))
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    ctx.strokePath()

    // Inner ring (thinner)
    let r2 = r - w * 0.035
    ctx.setLineWidth(w * 0.008)
    ctx.setStrokeColor(CGColor(red: 0.65, green: 0.85, blue: 0.45, alpha: 0.25))
    ctx.addEllipse(in: CGRect(x: cx - r2, y: cy - r2, width: r2 * 2, height: r2 * 2))
    ctx.strokePath()

    // --- Trunk: asymmetric, slightly curved, living feel ---
    let trunkW = w * 0.068
    let trunkTop = cy + r * 0.24
    let trunkBottom = cy - r * 0.38

    let trunkPath = CGMutablePath()
    // Left side — gentle inward bow
    trunkPath.move(to: CGPoint(x: cx - trunkW * 0.58, y: trunkBottom))
    trunkPath.addCurve(
        to: CGPoint(x: cx - trunkW * 0.32, y: trunkTop),
        control1: CGPoint(x: cx - trunkW * 0.72, y: cy - r * 0.05),
        control2: CGPoint(x: cx - trunkW * 0.42, y: cy + r * 0.12)
    )
    // Top crown — slight rightward lean
    trunkPath.addCurve(
        to: CGPoint(x: cx + trunkW * 0.48, y: trunkTop),
        control1: CGPoint(x: cx - trunkW * 0.05, y: trunkTop + w * 0.022),
        control2: CGPoint(x: cx + trunkW * 0.28, y: trunkTop + w * 0.018)
    )
    // Right side — slightly wider (tree isn't perfectly straight)
    trunkPath.addCurve(
        to: CGPoint(x: cx + trunkW * 0.68, y: trunkBottom),
        control1: CGPoint(x: cx + trunkW * 0.60, y: cy + r * 0.12),
        control2: CGPoint(x: cx + trunkW * 0.78, y: cy - r * 0.08)
    )
    trunkPath.closeSubpath()

    ctx.addPath(trunkPath)
    ctx.setFillColor(CGColor(red: 0.45, green: 0.72, blue: 0.30, alpha: 0.9))
    ctx.fillPath()

    // --- Branch + root drawing helper ---
    let branchLineWidth = w * 0.022
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    func drawBranch(from: CGPoint, to: CGPoint, cp1: CGPoint, cp2: CGPoint,
                    width: CGFloat, alpha: CGFloat = 1.0) {
        let p = CGMutablePath()
        p.move(to: from)
        p.addCurve(to: to, control1: cp1, control2: cp2)
        // Glow layer
        ctx.setLineWidth(width * 2.5)
        ctx.setStrokeColor(CGColor(red: 0.5, green: 0.9, blue: 0.3, alpha: alpha * 0.15))
        ctx.addPath(p)
        ctx.strokePath()
        // Core line
        ctx.setLineWidth(width)
        ctx.setStrokeColor(CGColor(red: 0.65, green: 0.88, blue: 0.40, alpha: alpha * 0.9))
        ctx.addPath(p)
        ctx.strokePath()
    }

    // Branch origins — slightly offset, not perfectly centered
    let branchOriginY = cy + r * 0.16
    let leftOrigin  = CGPoint(x: cx - trunkW * 0.18, y: branchOriginY)
    let rightOrigin = CGPoint(x: cx + trunkW * 0.12, y: branchOriginY - w * 0.012)

    // LEFT MAIN BRANCH
    // S-curve: first rises nearly vertical, then sweeps hard left
    // Mimics real branch growth — reaching for light before bending outward
    drawBranch(
        from: leftOrigin,
        to: CGPoint(x: cx - r * 0.82, y: cy + r * 0.70),
        cp1: CGPoint(x: cx - r * 0.04, y: cy + r * 0.48),   // rises up near center
        cp2: CGPoint(x: cx - r * 0.60, y: cy + r * 0.65),   // sweeps hard left
        width: branchLineWidth
    )

    // LEFT UPPER BRANCH — emerges slightly higher, reaches up-left
    drawBranch(
        from: CGPoint(x: cx - trunkW * 0.08, y: branchOriginY + w * 0.038),
        to: CGPoint(x: cx - r * 0.50, y: cy + r * 0.88),
        cp1: CGPoint(x: cx - r * 0.06, y: cy + r * 0.58),
        cp2: CGPoint(x: cx - r * 0.36, y: cy + r * 0.80),
        width: branchLineWidth * 0.62,
        alpha: 0.82
    )

    // RIGHT MAIN BRANCH — different reach and angle than left (not a mirror)
    drawBranch(
        from: rightOrigin,
        to: CGPoint(x: cx + r * 0.74, y: cy + r * 0.62),
        cp1: CGPoint(x: cx + r * 0.06, y: cy + r * 0.40),
        cp2: CGPoint(x: cx + r * 0.54, y: cy + r * 0.56),
        width: branchLineWidth * 0.90
    )

    // RIGHT UPPER BRANCH
    drawBranch(
        from: CGPoint(x: cx + trunkW * 0.05, y: branchOriginY + w * 0.022),
        to: CGPoint(x: cx + r * 0.58, y: cy + r * 0.82),
        cp1: CGPoint(x: cx + r * 0.10, y: cy + r * 0.56),
        cp2: CGPoint(x: cx + r * 0.44, y: cy + r * 0.76),
        width: branchLineWidth * 0.58,
        alpha: 0.78
    )

    // CENTER CROWN — slight rightward bow reaching high
    drawBranch(
        from: CGPoint(x: cx + w * 0.008, y: trunkTop),
        to: CGPoint(x: cx - r * 0.05, y: cy + r * 0.92),
        cp1: CGPoint(x: cx + r * 0.07, y: cy + r * 0.50),
        cp2: CGPoint(x: cx + r * 0.03, y: cy + r * 0.80),
        width: branchLineWidth * 0.72
    )

    // SUB-BRANCH off left main (~55% along the curve)
    drawBranch(
        from: CGPoint(x: cx - r * 0.48, y: cy + r * 0.60),
        to: CGPoint(x: cx - r * 0.60, y: cy + r * 0.80),
        cp1: CGPoint(x: cx - r * 0.46, y: cy + r * 0.68),
        cp2: CGPoint(x: cx - r * 0.56, y: cy + r * 0.77),
        width: branchLineWidth * 0.30,
        alpha: 0.60
    )

    // SUB-BRANCH off right main
    drawBranch(
        from: CGPoint(x: cx + r * 0.44, y: cy + r * 0.52),
        to: CGPoint(x: cx + r * 0.56, y: cy + r * 0.72),
        cp1: CGPoint(x: cx + r * 0.46, y: cy + r * 0.60),
        cp2: CGPoint(x: cx + r * 0.53, y: cy + r * 0.69),
        width: branchLineWidth * 0.30,
        alpha: 0.60
    )

    // --- ROOTS ---
    // Natural roots spread LATERALLY first, then curve downward (S-curve)
    // This is how real roots behave — they search outward before descending
    let rootLineWidth = branchLineWidth * 0.85

    // LEFT MAIN ROOT — spreads left near-horizontal, then curves down
    drawBranch(
        from: CGPoint(x: cx - trunkW * 0.32, y: trunkBottom),
        to: CGPoint(x: cx - r * 0.80, y: cy - r * 0.58),
        cp1: CGPoint(x: cx - r * 0.35, y: trunkBottom - w * 0.015),  // spreads left, nearly flat
        cp2: CGPoint(x: cx - r * 0.68, y: cy - r * 0.38),             // then curves down
        width: rootLineWidth
    )

    // RIGHT MAIN ROOT — slightly steeper, less spread
    drawBranch(
        from: CGPoint(x: cx + trunkW * 0.35, y: trunkBottom),
        to: CGPoint(x: cx + r * 0.74, y: cy - r * 0.62),
        cp1: CGPoint(x: cx + r * 0.30, y: trunkBottom - w * 0.022),
        cp2: CGPoint(x: cx + r * 0.62, y: cy - r * 0.44),
        width: rootLineWidth * 0.92
    )

    // CENTER ROOT — descends with gentle left-then-right winding
    drawBranch(
        from: CGPoint(x: cx + r * 0.03, y: trunkBottom),
        to: CGPoint(x: cx - r * 0.05, y: cy - r * 0.86),
        cp1: CGPoint(x: cx - r * 0.10, y: cy - r * 0.30),
        cp2: CGPoint(x: cx + r * 0.08, y: cy - r * 0.65),
        width: rootLineWidth * 0.68
    )

    // LEFT SECONDARY ROOT — diverges at steeper angle
    drawBranch(
        from: CGPoint(x: cx - r * 0.15, y: trunkBottom - w * 0.015),
        to: CGPoint(x: cx - r * 0.48, y: cy - r * 0.84),
        cp1: CGPoint(x: cx - r * 0.20, y: cy - r * 0.38),
        cp2: CGPoint(x: cx - r * 0.38, y: cy - r * 0.70),
        width: rootLineWidth * 0.48,
        alpha: 0.70
    )

    // RIGHT SECONDARY ROOT
    drawBranch(
        from: CGPoint(x: cx + r * 0.18, y: trunkBottom - w * 0.018),
        to: CGPoint(x: cx + r * 0.52, y: cy - r * 0.80),
        cp1: CGPoint(x: cx + r * 0.22, y: cy - r * 0.35),
        cp2: CGPoint(x: cx + r * 0.44, y: cy - r * 0.66),
        width: rootLineWidth * 0.48,
        alpha: 0.70
    )

    // --- Leaf nodes at branch tips ---
    func drawLeaf(at point: CGPoint, radius: CGFloat) {
        ctx.setFillColor(CGColor(red: 0.55, green: 0.95, blue: 0.35, alpha: 0.2))
        ctx.addEllipse(in: CGRect(x: point.x - radius * 2.2, y: point.y - radius * 2.2,
                                   width: radius * 4.4, height: radius * 4.4))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.70, green: 0.95, blue: 0.45, alpha: 0.95))
        ctx.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.fillPath()
    }

    let leafR = w * 0.025
    drawLeaf(at: CGPoint(x: cx - r * 0.82, y: cy + r * 0.70), radius: leafR)
    drawLeaf(at: CGPoint(x: cx + r * 0.74, y: cy + r * 0.62), radius: leafR)
    drawLeaf(at: CGPoint(x: cx - r * 0.05, y: cy + r * 0.92), radius: leafR * 1.2)  // crown tip
    drawLeaf(at: CGPoint(x: cx - r * 0.50, y: cy + r * 0.88), radius: leafR * 0.85)
    drawLeaf(at: CGPoint(x: cx + r * 0.58, y: cy + r * 0.82), radius: leafR * 0.85)
    drawLeaf(at: CGPoint(x: cx - r * 0.60, y: cy + r * 0.80), radius: leafR * 0.55) // sub-branch tip
    drawLeaf(at: CGPoint(x: cx + r * 0.56, y: cy + r * 0.72), radius: leafR * 0.55) // sub-branch tip

    // --- Rune ticks at cardinal & diagonal points on outer ring ---
    let tickR = r + w * 0.008
    let tickLen = w * 0.028
    let tickAngles: [CGFloat] = [0, 45, 90, 135, 180, 225, 270, 315]
    ctx.setLineWidth(w * 0.012)
    ctx.setStrokeColor(CGColor(red: 0.65, green: 0.85, blue: 0.45, alpha: 0.35))
    for angle in tickAngles {
        let rad = angle * CGFloat.pi / 180.0
        let x1 = cx + (tickR - tickLen) * cos(rad)
        let y1 = cy + (tickR - tickLen) * sin(rad)
        let x2 = cx + tickR * cos(rad)
        let y2 = cy + tickR * sin(rad)
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.strokePath()
    }

    // --- Ambient center glow ---
    let centerGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.4, green: 0.8, blue: 0.25, alpha: 0.12),
            CGColor(red: 0.4, green: 0.8, blue: 0.25, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    let glowRadius = r * 0.55
    ctx.drawRadialGradient(centerGlow,
                           startCenter: CGPoint(x: cx, y: cy),
                           startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy),
                           endRadius: glowRadius,
                           options: [])

    return ctx.makeImage()
}

// MARK: - Generate all macOS icon sizes

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/AppIcon.appiconset"

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let sizes: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (64, 1), (64, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
    (1024, 1)
]

for entry in sizes {
    let px = entry.size * entry.scale
    let img = drawWorldTree(size: CGFloat(px))
    let filename = entry.scale == 1
        ? "icon_\(entry.size)x\(entry.size).png"
        : "icon_\(entry.size)x\(entry.size)@\(entry.scale)x.png"
    let path = outputDir + "/" + filename

    if let cgImage = img,
       let dest = CGImageDestinationCreateWithURL(
           URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        print("✓ \(filename) (\(px)×\(px)px)")
    } else {
        print("✗ Failed: \(filename)")
    }
}

print("\nWorld Tree icon set generated at: \(outputDir)")
