// RingImageMaker.swift
// Draws Apple Watch-style activity rings into an NSImage using NSBezierPath.
// NSImage + isTemplate=false is the only reliable way to show full color in a
// MenuBarExtra label — SwiftUI Canvas/Circle are treated as template (alpha-only)
// by macOS in that rendering context.

import AppKit

enum RingImageMaker {

    // ── Apple Watch Activity palette (explicit sRGB) ──
    static let ringNSColors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.31, blue: 0.25, alpha: 1), // Move  (red)
        NSColor(srgbRed: 0.31, green: 0.90, blue: 0.46, alpha: 1), // Exercise (green)
        NSColor(srgbRed: 0.05, green: 0.73, blue: 0.93, alpha: 1), // Stand (cyan)
    ]

    // ── Layout ──
    // Rings are thinner than the original to carve out a center well for the "S".
    // With size=20, lineWidth=1.5, step=2.5:
    //   ring 0: radius 9.25  (outer)
    //   ring 1: radius 6.75  (mid)
    //   ring 2: radius 4.25  (inner)  → clear centre ≈ Ø7 pt → fits a 6-pt "S"
    private static let size:      CGFloat = 20
    private static let lineWidth: CGFloat = 1.5
    private static let step:      CGFloat = 2.5

    /// Returns a 20×20-point NSImage with 1–3 concentric activity rings and
    /// a small "S" centred inside them. Falls back to the "s.circle" SF Symbol
    /// when no stats are resolved.
    static func image(quotas: [UsageQuota], labels: [String]) -> NSImage {
        let rings: [(progress: Double, color: NSColor)] = labels.prefix(3)
            .enumerated()
            .compactMap { i, label in
                guard !label.isEmpty,
                      let q = quotas.first(where: { $0.label == label })
                else { return nil }
                return (progress: min(q.utilization / 100.0, 1.0),
                        color: ringNSColors[i % ringNSColors.count])
            }

        guard !rings.isEmpty else { return fallbackImage() }

        // NSImage with flipped:false → standard macOS y-up coordinate system.
        // NSBezierPath.appendArc angles: 0°=3-o'clock, 90°=12-o'clock,
        // positive angles = counter-clockwise (standard math).
        // clockwise:true sweeps from startAngle toward decreasing angles
        // = visually clockwise on screen.
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let outerRadius = size / 2 - lineWidth / 2

            // ── Subtle background disc ──
            // On light menubars the bright rings (especially green) can wash out;
            // a faint dark circle behind them restores contrast without being obtrusive.
            // Check appearance at draw time — image is regenerated from the main
            // thread on every quota refresh so it stays in sync with mode changes.
            let isDark = NSApp.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bgAlpha: CGFloat = isDark ? 0.0 : 0.13
            if bgAlpha > 0 {
                let bgPath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0,
                                                         width: size, height: size))
                NSColor.black.withAlphaComponent(bgAlpha).setFill()
                bgPath.fill()
            }

            // ── Rings ──
            for (i, ring) in rings.enumerated() {
                let radius = outerRadius - CGFloat(i) * step
                guard radius > lineWidth / 2 else { continue }

                // Dim track (full circle)
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius,
                                startAngle: 0, endAngle: 360, clockwise: false)
                track.lineWidth = lineWidth
                ring.color.withAlphaComponent(0.28).setStroke()
                track.stroke()

                // Progress arc — 12-o'clock (90°) → clockwise
                guard ring.progress > 0 else { continue }
                let endAngle = 90.0 - CGFloat(ring.progress) * 360.0
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: endAngle,
                              clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                ring.color.setStroke()
                arc.stroke()
            }

            // ── "S" in the centre ──
            // labelColor resolves to black on light menubar, white on dark.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 6.0, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ]
            let str = "S" as NSString
            let strSize = str.size(withAttributes: attrs)
            // In y-up coords, rect.origin.y is the bottom of the text bounding box
            let strRect = NSRect(
                x: center.x - strSize.width  / 2,
                y: center.y - strSize.height / 2,
                width:  strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect, withAttributes: attrs)

            return true
        }

        image.isTemplate = false   // preserve colors — never template-render this
        return image
    }

    private static func fallbackImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: "s.circle",
                       accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }
}
