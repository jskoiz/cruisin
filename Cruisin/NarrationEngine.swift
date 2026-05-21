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
        excludedCategories: Set<String> = [],
        quietMode: Bool = false,
        spokenIDs: Set<String> = []
    ) -> [NearbyCandidate] {
        facts.compactMap { fact in
            let category = fact.normalizedCategory
            guard !excludedCategories.contains(category) else { return nil }

            let distance = coordinate.distance(to: fact.coordinate)
            let radius = fact.category == "area" ? areaRadius : detectionRadius
            guard distance <= radius else { return nil }

            let components = scoreComponents(
                for: fact,
                distance: distance,
                radius: radius,
                preferredCategories: preferredCategories,
                quietMode: quietMode,
                isFresh: !spokenIDs.contains(fact.id)
            )
            let score = score(from: components)
            let reasons = auditReasons(
                for: fact,
                distance: distance,
                preferredCategories: preferredCategories,
                quietMode: quietMode,
                isFresh: !spokenIDs.contains(fact.id),
                components: components
            )
            return NearbyCandidate(
                fact: fact,
                distanceMeters: distance,
                rankScore: score,
                reason: reasons.joined(separator: "; "),
                auditReasons: reasons,
                scoreComponents: components
            )
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

    private func scoreComponents(
        for fact: LocalFact,
        distance: CLLocationDistance,
        radius: CLLocationDistance,
        preferredCategories: Set<String>,
        quietMode: Bool,
        isFresh: Bool
    ) -> RankScoreComponents {
        let category = fact.normalizedCategory
        let proximity = max(0, 1 - (distance / radius))
        let preferenceMatch = preferredCategories.contains(category) || !preferredCategories.isDisjoint(with: Set(fact.tags.map { $0.lowercased() })) ? 1.0 : 0.0
        let categoryRelevance = boost(for: category) / 230
        let routeRelevance = max(categoryRelevance, fact.driveByValue)
        let safetyPenalty = fact.safetyFlags.isEmpty && fact.sensitivity == "normal" ? 0 : 0.25
        let quietPenalty = quietMode && fact.driveByValue < 0.75 && fact.priority < 4 ? 0.18 : 0

        return RankScoreComponents(
            intrinsicValue: fact.intrinsicValue,
            preferenceMatch: preferenceMatch,
            proximity: proximity,
            routeRelevance: routeRelevance,
            novelty: isFresh ? 1 : 0,
            sourceConfidence: fact.sourceConfidence,
            visualProminence: fact.visualProminence,
            driveByValue: fact.driveByValue,
            quietPenalty: quietPenalty,
            safetyPenalty: safetyPenalty
        )
    }

    private func score(from components: RankScoreComponents) -> Double {
        let weighted =
            0.25 * components.intrinsicValue
            + 0.20 * components.preferenceMatch
            + 0.15 * components.proximity
            + 0.10 * components.routeRelevance
            + 0.10 * components.novelty
            + 0.10 * components.sourceConfidence
            + 0.05 * components.visualProminence
            + 0.05 * components.driveByValue
            - components.quietPenalty
            - components.safetyPenalty

        return max(0, weighted) * 1000
    }

    private func auditReasons(
        for fact: LocalFact,
        distance: CLLocationDistance,
        preferredCategories: Set<String>,
        quietMode: Bool,
        isFresh: Bool,
        components: RankScoreComponents
    ) -> [String] {
        var reasons = [
            "\(Int(distance)) m away",
            "\(fact.category), priority \(fact.priority)",
            "source \(Int((components.sourceConfidence * 100).rounded()))%"
        ]

        if components.preferenceMatch > 0 {
            reasons.append("matches preference")
        }
        if fact.driveByValue >= 0.75 {
            reasons.append("strong drive-by value")
        }
        if fact.visualProminence >= 0.75 {
            reasons.append("visually prominent")
        }
        if !isFresh {
            reasons.append("recently spoken penalty")
        }
        if quietMode && components.quietPenalty > 0 {
            reasons.append("quiet mode lowers weak interruption")
        }
        if components.safetyPenalty > 0 {
            reasons.append("safety/sensitivity penalty")
        }

        return reasons
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
