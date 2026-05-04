// MenuBarRingView.swift
// Thin SwiftUI wrapper around RingImageMaker — used in the MenuBarExtra label
// and as a color-palette reference for the settings panel.

import SwiftUI
import AppKit

// MARK: - Menubar icon (NSImage-backed, full color)

struct MenuBarRingView: View {

    let quotas: [UsageQuota]
    let labels: [String]

    // SwiftUI Color equivalents for the settings UI legend
    static let ringColors: [Color] = [
        Color(nsColor: RingImageMaker.ringNSColors[0]),
        Color(nsColor: RingImageMaker.ringNSColors[1]),
        Color(nsColor: RingImageMaker.ringNSColors[2]),
    ]

    var body: some View {
        Image(nsImage: RingImageMaker.image(quotas: quotas, labels: labels))
            .interpolation(.high)
            .antialiased(true)
    }
}

// MARK: - Settings panel preview (larger, labeled)

private struct SingleRingArc: View {
    let progress: Double
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

struct RingSettingsPreview: View {
    let quotas: [UsageQuota]
    let labels: [String]

    private static let outerDiameter: CGFloat = 44
    private static let lineWidth:     CGFloat = 4.5
    private static let step:          CGFloat = 5.5

    private var rings: [(label: String, progress: Double, color: Color)] {
        labels.prefix(3).enumerated().compactMap { i, label in
            guard !label.isEmpty else { return nil }
            let util = quotas.first(where: { $0.label == label })?.utilization ?? 0
            return (label: label,
                    progress: min(util / 100.0, 1.0),
                    color: MenuBarRingView.ringColors[i % MenuBarRingView.ringColors.count])
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Ring diagram
            ZStack {
                if rings.isEmpty {
                    Image(systemName: "c.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(rings.indices, id: \.self) { i in
                        let diam = Self.outerDiameter - CGFloat(i) * Self.step * 2
                        SingleRingArc(progress: rings[i].progress,
                                      color:    rings[i].color,
                                      diameter: max(diam, 4),
                                      lineWidth: Self.lineWidth)
                    }
                }
            }
            .frame(width: Self.outerDiameter, height: Self.outerDiameter)

            // Legend
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(MenuBarRingView.ringColors[i])
                            .frame(width: 7, height: 7)
                        if i < labels.count && !labels[i].isEmpty {
                            let label = labels[i]
                            let util  = quotas.first(where: { $0.label == label })?.utilization
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            if let u = util {
                                Text("\(Int(u))%")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("—")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
