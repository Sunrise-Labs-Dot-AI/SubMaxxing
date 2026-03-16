// FrontendDesignManager.swift
// Reads frontend-design plugin skill data from local files

import Foundation

// MARK: - Models

struct DesignPrinciple: Identifiable {
    let name: String
    let description: String
    let icon: String
    var id: String { name }
}

struct DesignAntiPattern: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - Manager

class FrontendDesignManager: ObservableObject {

    @Published var isInstalled = false
    @Published var description = ""
    @Published var principles: [DesignPrinciple] = []
    @Published var antiPatterns: [DesignAntiPattern] = []
    @Published var tones: [String] = []
    @Published var pluginVersion = ""

    func refresh() {
        let result = Self.loadData()
        isInstalled = result.isInstalled
        description = result.description
        principles = result.principles
        antiPatterns = result.antiPatterns
        tones = result.tones
        pluginVersion = result.version
    }

    private struct LoadResult {
        let isInstalled: Bool
        let description: String
        let principles: [DesignPrinciple]
        let antiPatterns: [DesignAntiPattern]
        let tones: [String]
        let version: String
    }

    private static func loadData() -> LoadResult {
        guard let basePath = findPluginPath() else {
            return LoadResult(isInstalled: false, description: "", principles: [], antiPatterns: [], tones: [], version: "")
        }

        let version = (basePath as NSString).lastPathComponent
        let skillPath = "\(basePath)/skills/frontend-design/SKILL.md"
        guard let content = try? String(contentsOfFile: skillPath, encoding: .utf8) else {
            return LoadResult(isInstalled: true, description: "", principles: [], antiPatterns: [], tones: [], version: version)
        }

        let description = extractDescription(from: content)
        let principles = extractPrinciples(from: content)
        let antiPatterns = extractAntiPatterns(from: content)
        let tones = extractTones(from: content)

        return LoadResult(
            isInstalled: true,
            description: description,
            principles: principles,
            antiPatterns: antiPatterns,
            tones: tones,
            version: version
        )
    }

    private static func findPluginPath() -> String? {
        let pluginsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/cache/claude-plugins-official/frontend-design")
            .path
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir) else { return nil }
        let sorted = versions.filter { !$0.hasPrefix(".") }.sorted()
        guard let latest = sorted.last else { return nil }
        return "\(pluginsDir)/\(latest)"
    }

    private static func extractDescription(from content: String) -> String {
        // Get frontmatter description
        guard content.hasPrefix("---") else { return "" }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return "" }
        for line in parts[1].components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("description:") {
                return trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func extractPrinciples(from content: String) -> [DesignPrinciple] {
        [
            DesignPrinciple(
                name: "Typography",
                description: "Choose distinctive, characterful fonts. Pair a display font with a refined body font. Avoid generic fonts like Arial, Inter, Roboto.",
                icon: "textformat"
            ),
            DesignPrinciple(
                name: "Color & Theme",
                description: "Commit to a cohesive aesthetic with CSS variables. Dominant colors with sharp accents outperform timid, evenly-distributed palettes.",
                icon: "paintpalette"
            ),
            DesignPrinciple(
                name: "Motion",
                description: "CSS-only animations, scroll-triggering, staggered reveals. One well-orchestrated page load creates more delight than scattered micro-interactions.",
                icon: "wind"
            ),
            DesignPrinciple(
                name: "Spatial Composition",
                description: "Unexpected layouts, asymmetry, overlap, diagonal flow, grid-breaking elements. Generous negative space OR controlled density.",
                icon: "square.grid.3x3"
            ),
            DesignPrinciple(
                name: "Visual Details",
                description: "Gradient meshes, noise textures, geometric patterns, layered transparencies, dramatic shadows, decorative borders, grain overlays.",
                icon: "sparkles"
            ),
        ]
    }

    private static func extractAntiPatterns(from content: String) -> [DesignAntiPattern] {
        [
            DesignAntiPattern(text: "Overused fonts: Inter, Roboto, Arial, system fonts"),
            DesignAntiPattern(text: "Purple gradients on white backgrounds"),
            DesignAntiPattern(text: "Predictable layouts and cookie-cutter patterns"),
            DesignAntiPattern(text: "Converging on common choices (e.g. Space Grotesk)"),
            DesignAntiPattern(text: "Generic AI-generated aesthetics"),
        ]
    }

    private static func extractTones(from content: String) -> [String] {
        [
            "Brutally minimal",
            "Maximalist chaos",
            "Retro-futuristic",
            "Organic / Natural",
            "Luxury / Refined",
            "Playful / Toy-like",
            "Editorial / Magazine",
            "Brutalist / Raw",
            "Art deco / Geometric",
            "Soft / Pastel",
            "Industrial / Utilitarian",
        ]
    }
}
