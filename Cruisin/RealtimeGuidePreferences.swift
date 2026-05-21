import Foundation

struct RealtimeGuidePreferences: Codable, Equatable {
    var preferredCategories: [String] = []
    var excludedCategories: [String] = []
    var quietMode = false

    var auditSummary: String {
        var pieces: [String] = []

        if preferredCategories.isEmpty {
            pieces.append("balanced")
        } else {
            pieces.append("prefers \(preferredCategories.joined(separator: ", "))")
        }

        if !excludedCategories.isEmpty {
            pieces.append("skips \(excludedCategories.joined(separator: ", "))")
        }

        if quietMode {
            pieces.append("quiet/short")
        }

        return pieces.joined(separator: "; ")
    }

    mutating func infer(from utterance: String) -> Bool {
        let previous = self
        let text = utterance.lowercased()

        if containsAny(text, ["history", "historic", "old honolulu", "royal"]) {
            prefer("history")
        }

        if containsAny(text, ["food", "eat", "restaurant", "lunch", "dinner", "poke", "plate lunch"]) {
            prefer("food")
        }

        if containsAny(text, ["nature", "beach", "park", "ocean", "mountain", "trees", "scenic"]) {
            prefer("nature")
        }

        if containsAny(text, ["culture", "cultural", "hawaiian", "tradition", "art", "music"]) {
            prefer("culture")
        }

        if containsAny(text, ["skip food", "no food", "not food", "don't mention food", "dont mention food"]) {
            exclude("food")
        }

        if containsAny(text, ["quiet", "short", "shorter", "less talking", "keep it brief", "brief"]) {
            quietMode = true
        }

        return previous != self
    }

    private mutating func prefer(_ category: String) {
        guard !preferredCategories.contains(category) else { return }
        preferredCategories.append(category)
        excludedCategories.removeAll { $0 == category }
    }

    private mutating func exclude(_ category: String) {
        guard !excludedCategories.contains(category) else { return }
        excludedCategories.append(category)
        preferredCategories.removeAll { $0 == category }
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    func merged(snapshotPreferredCategories: [String], snapshotQuietMode: Bool) -> RealtimeGuidePreferences {
        var merged = self

        for category in snapshotPreferredCategories {
            let normalized = category.lowercased()
            guard !merged.preferredCategories.contains(normalized),
                  !merged.excludedCategories.contains(normalized) else {
                continue
            }
            merged.preferredCategories.append(normalized)
        }

        merged.quietMode = merged.quietMode || snapshotQuietMode
        return merged
    }
}
