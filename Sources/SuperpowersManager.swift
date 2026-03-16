// SuperpowersManager.swift
// Reads superpowers plugin skills, plans, and specs from local files

import Foundation

// MARK: - Models

struct SuperpowersSkill: Identifiable {
    let name: String
    let description: String
    let lineCount: Int
    let supportingFiles: Int
    let path: String

    var id: String { name }

    var displayName: String {
        name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    var category: String {
        switch name {
        case "test-driven-development": return "Testing"
        case "systematic-debugging": return "Debugging"
        case "brainstorming": return "Design"
        case "writing-plans", "executing-plans": return "Planning"
        case "writing-skills": return "Skills"
        case "dispatching-parallel-agents", "subagent-driven-development": return "Agents"
        case "requesting-code-review", "receiving-code-review": return "Review"
        case "using-git-worktrees", "finishing-a-development-branch": return "Git"
        case "verification-before-completion": return "Quality"
        case "using-superpowers": return "Meta"
        default: return "Other"
        }
    }
}

struct SuperpowersPlan: Identifiable {
    let filename: String
    let title: String
    let date: String
    let path: String
    let totalSteps: Int
    let completedSteps: Int

    var id: String { filename }

    var progress: Double {
        totalSteps > 0 ? Double(completedSteps) / Double(totalSteps) : 0
    }
}

struct SuperpowersSpec: Identifiable {
    let filename: String
    let title: String
    let date: String
    let path: String

    var id: String { filename }
}

// MARK: - Manager

class SuperpowersManager: ObservableObject {

    @Published var skills: [SuperpowersSkill] = []
    @Published var plans: [SuperpowersPlan] = []
    @Published var specs: [SuperpowersSpec] = []
    @Published var isLoading = false
    @Published var pluginVersion = ""

    // MARK: - Load data

    func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.loadData()
            DispatchQueue.main.async {
                self.skills = result.skills
                self.plans = result.plans
                self.specs = result.specs
                self.pluginVersion = result.version
                self.isLoading = false
            }
        }
    }

    private struct LoadResult {
        let skills: [SuperpowersSkill]
        let plans: [SuperpowersPlan]
        let specs: [SuperpowersSpec]
        let version: String
    }

    private static func loadData() -> LoadResult {
        let skillsPath = findSuperpowersPath()
        let skills = skillsPath.map { loadSkills(from: $0) } ?? []
        let version = skillsPath.map { extractVersion(from: $0) } ?? ""
        let plans = loadPlans()
        let specs = loadSpecs()
        return LoadResult(skills: skills, plans: plans, specs: specs, version: version)
    }

    // MARK: - Find plugin path

    private static func findSuperpowersPath() -> String? {
        let pluginsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/cache/claude-plugins-official/superpowers")
            .path
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: pluginsDir) else { return nil }
        // Pick the latest version directory
        let sorted = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        guard let latest = sorted.first else { return nil }
        return "\(pluginsDir)/\(latest)"
    }

    private static func extractVersion(from path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Load skills

    private static func loadSkills(from basePath: String) -> [SuperpowersSkill] {
        let skillsDir = "\(basePath)/skills"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: skillsDir) else { return [] }

        return dirs.compactMap { dir -> SuperpowersSkill? in
            let skillPath = "\(skillsDir)/\(dir)/SKILL.md"
            guard let content = try? String(contentsOfFile: skillPath, encoding: .utf8) else { return nil }

            let (name, description) = parseFrontmatter(content)
            let lineCount = content.components(separatedBy: "\n").count

            // Count supporting files
            let allFiles = (try? fm.contentsOfDirectory(atPath: "\(skillsDir)/\(dir)")) ?? []
            let supportingFiles = allFiles.filter { $0.hasSuffix(".md") && $0 != "SKILL.md" }.count

            return SuperpowersSkill(
                name: name.isEmpty ? dir : name,
                description: description,
                lineCount: lineCount,
                supportingFiles: supportingFiles,
                path: skillPath
            )
        }.sorted { $0.name < $1.name }
    }

    private static func parseFrontmatter(_ content: String) -> (name: String, description: String) {
        guard content.hasPrefix("---") else { return ("", "") }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return ("", "") }
        let frontmatter = parts[1]

        var name = ""
        var description = ""
        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("description:") {
                description = trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes
                if description.hasPrefix("\"") && description.hasSuffix("\"") {
                    description = String(description.dropFirst().dropLast())
                }
            }
        }
        return (name, description)
    }

    // MARK: - Load plans

    private static func loadPlans() -> [SuperpowersPlan] {
        let plansDir = findProjectDocsPath("plans")
        guard let plansDir, let files = try? FileManager.default.contentsOfDirectory(atPath: plansDir) else { return [] }

        return files.filter { $0.hasSuffix(".md") }.compactMap { file -> SuperpowersPlan? in
            let path = "\(plansDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

            let title = extractTitle(from: content) ?? file
            let date = String(file.prefix(10)) // YYYY-MM-DD
            let totalSteps = content.components(separatedBy: "- [ ] ").count - 1
                + content.components(separatedBy: "- [x] ").count - 1
            let completedSteps = content.components(separatedBy: "- [x] ").count - 1

            return SuperpowersPlan(
                filename: file,
                title: title,
                date: date,
                path: path,
                totalSteps: totalSteps,
                completedSteps: completedSteps
            )
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Load specs

    private static func loadSpecs() -> [SuperpowersSpec] {
        let specsDir = findProjectDocsPath("specs")
        guard let specsDir, let files = try? FileManager.default.contentsOfDirectory(atPath: specsDir) else { return [] }

        return files.filter { $0.hasSuffix(".md") }.compactMap { file -> SuperpowersSpec? in
            let path = "\(specsDir)/\(file)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

            let title = extractTitle(from: content) ?? file
            let date = String(file.prefix(10))

            return SuperpowersSpec(filename: file, title: title, date: date, path: path)
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Helpers

    private static func findProjectDocsPath(_ subdir: String) -> String? {
        // Look in current working directory and common project locations
        let candidates = [
            FileManager.default.currentDirectoryPath + "/docs/superpowers/\(subdir)",
        ]
        // Also scan home projects
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/Projects"
        if let projects = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
            for project in projects {
                let path = "\(projectsDir)/\(project)/docs/superpowers/\(subdir)"
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func extractTitle(from content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return nil
    }
}
