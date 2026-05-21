import CoreLocation
import Foundation

struct NarrationDecision {
    let candidate: NearbyCandidate
    let reason: String
}

struct NarrationEngine {
    let detectionRadius: CLLocationDistance = 475
    let areaRadius: CLLocationDistance = 700
    let cooldownSeconds: TimeInterval = 13

    func candidates(
        near coordinate: CLLocationCoordinate2D,
        facts: [LocalFact],
        preferredCategories: Set<String> = [],
        excludedCategories: Set<String> = []
    ) -> [NearbyCandidate] {
        facts.compactMap { fact in
            let category = fact.category.lowercased()
            guard !excludedCategories.contains(category) else { return nil }

            let distance = coordinate.distance(to: fact.coordinate)
            let radius = fact.category == "area" ? areaRadius : detectionRadius
            guard distance <= radius else { return nil }

            let categoryBoost = boost(for: fact.category)
            let preferenceBoost = preferredCategories.contains(category) ? 65.0 : 0
            let score = max(0, radius - distance) + Double(fact.priority * 70) + categoryBoost + preferenceBoost
            let preferenceReason = preferenceBoost > 0 ? ", preference boost" : ""
            let reason = "\(Int(distance)) m away, \(fact.category), priority \(fact.priority)\(preferenceReason)"
            return NearbyCandidate(fact: fact, distanceMeters: distance, rankScore: score, reason: reason)
        }
        .sorted {
            if $0.rankScore == $1.rankScore {
                return $0.distanceMeters < $1.distanceMeters
            }
            return $0.rankScore > $1.rankScore
        }
    }

    func decision(
        from candidates: [NearbyCandidate],
        spokenIDs: Set<String>,
        lastSpokenAt: Date?,
        lastAreaID: String?,
        now: Date
    ) -> NarrationDecision? {
        if let lastSpokenAt, now.timeIntervalSince(lastSpokenAt) < cooldownSeconds {
            return nil
        }

        if let area = candidates.first(where: { candidate in
            candidate.fact.category == "area"
                && candidate.fact.id != lastAreaID
                && candidate.distanceMeters <= areaRadius
        }) {
            return NarrationDecision(
                candidate: area,
                reason: "Entered \(area.fact.name) area within \(Int(area.distanceMeters)) m"
            )
        }

        guard let candidate = candidates.first(where: { !spokenIDs.contains($0.fact.id) }) else {
            return nil
        }

        return NarrationDecision(
            candidate: candidate,
            reason: "Best fresh nearby context: \(candidate.reason)"
        )
    }

    func noSelectionReason(candidates: [NearbyCandidate], lastSpokenAt: Date?, now: Date) -> String {
        if let lastSpokenAt {
            let elapsed = now.timeIntervalSince(lastSpokenAt)
            if elapsed < cooldownSeconds {
                return "Cooling down for \(Int(ceil(cooldownSeconds - elapsed))) s"
            }
        }

        if candidates.isEmpty {
            return "No bundled facts inside the current detection radius"
        }

        return "Nearby facts are already spoken or lower priority"
    }

    private func boost(for category: String) -> Double {
        switch category {
        case "lookout": return 230
        case "landmark": return 210
        case "history": return 190
        case "culture": return 175
        case "area": return 160
        case "food": return 120
        case "nature": return 115
        default: return 90
        }
    }
}
