import CoreLocation
import Foundation

struct LocalFact: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let subcategory: String?
    let tags: [String]
    let latitude: Double
    let longitude: Double
    let narration: String
    let sourceName: String
    let sourceURL: String
    let sourceURLs: [String]
    let sourceConfidence: Double
    let priority: Int
    let culturalImportance: Double
    let historicImportance: Double
    let visualProminence: Double
    let driveByValue: Double
    let sensitivity: String
    let safetyFlags: [String]
    let evergreen: Bool
    let freshness: String?
    let eventStartDate: String?
    let eventEndDate: String?
    let recurrence: String?

    init(
        id: String,
        name: String,
        category: String,
        subcategory: String? = nil,
        tags: [String] = [],
        latitude: Double,
        longitude: Double,
        narration: String,
        sourceName: String,
        sourceURL: String,
        sourceURLs: [String]? = nil,
        sourceConfidence: Double = 0.75,
        priority: Int,
        culturalImportance: Double? = nil,
        historicImportance: Double? = nil,
        visualProminence: Double = 0.5,
        driveByValue: Double = 0.5,
        sensitivity: String = "normal",
        safetyFlags: [String] = [],
        evergreen: Bool = true,
        freshness: String? = nil,
        eventStartDate: String? = nil,
        eventEndDate: String? = nil,
        recurrence: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.subcategory = subcategory
        self.tags = tags
        self.latitude = latitude
        self.longitude = longitude
        self.narration = narration
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.sourceURLs = sourceURLs ?? [sourceURL]
        self.sourceConfidence = min(max(sourceConfidence, 0), 1)
        self.priority = priority
        self.culturalImportance = culturalImportance ?? (category == "culture" ? Double(priority) / 5 : 0.35)
        self.historicImportance = historicImportance ?? (category == "history" ? Double(priority) / 5 : 0.35)
        self.visualProminence = min(max(visualProminence, 0), 1)
        self.driveByValue = min(max(driveByValue, 0), 1)
        self.sensitivity = sensitivity
        self.safetyFlags = safetyFlags
        self.evergreen = evergreen
        self.freshness = freshness
        self.eventStartDate = eventStartDate
        self.eventEndDate = eventEndDate
        self.recurrence = recurrence
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var normalizedCategory: String {
        category.lowercased()
    }

    var intrinsicValue: Double {
        let priorityValue = Double(priority) / 5
        return [priorityValue, culturalImportance, historicImportance, visualProminence, driveByValue].reduce(0, +) / 5
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, subcategory, tags, latitude, longitude, narration, sourceName, sourceURL, sourceURLs
        case sourceConfidence, priority, culturalImportance, historicImportance, visualProminence, driveByValue
        case sensitivity, safetyFlags, evergreen, freshness
        case eventStartDate, eventEndDate, recurrence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let category = try container.decode(String.self, forKey: .category)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        let narration = try container.decode(String.self, forKey: .narration)
        let sourceName = try container.decode(String.self, forKey: .sourceName)
        let sourceURL = try container.decode(String.self, forKey: .sourceURL)
        let priority = try container.decode(Int.self, forKey: .priority)

        self.init(
            id: id,
            name: name,
            category: category,
            subcategory: try container.decodeIfPresent(String.self, forKey: .subcategory),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            latitude: latitude,
            longitude: longitude,
            narration: narration,
            sourceName: sourceName,
            sourceURL: sourceURL,
            sourceURLs: try container.decodeIfPresent([String].self, forKey: .sourceURLs),
            sourceConfidence: try container.decodeIfPresent(Double.self, forKey: .sourceConfidence) ?? 0.75,
            priority: priority,
            culturalImportance: try container.decodeIfPresent(Double.self, forKey: .culturalImportance),
            historicImportance: try container.decodeIfPresent(Double.self, forKey: .historicImportance),
            visualProminence: try container.decodeIfPresent(Double.self, forKey: .visualProminence) ?? 0.5,
            driveByValue: try container.decodeIfPresent(Double.self, forKey: .driveByValue) ?? 0.5,
            sensitivity: try container.decodeIfPresent(String.self, forKey: .sensitivity) ?? "normal",
            safetyFlags: try container.decodeIfPresent([String].self, forKey: .safetyFlags) ?? [],
            evergreen: try container.decodeIfPresent(Bool.self, forKey: .evergreen) ?? true,
            freshness: try container.decodeIfPresent(String.self, forKey: .freshness),
            eventStartDate: try container.decodeIfPresent(String.self, forKey: .eventStartDate),
            eventEndDate: try container.decodeIfPresent(String.self, forKey: .eventEndDate),
            recurrence: try container.decodeIfPresent(String.self, forKey: .recurrence)
        )
    }
}

struct RouteWaypoint: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let latitude: Double
    let longitude: Double
    let secondsFromStart: TimeInterval

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct NearbyCandidate: Identifiable, Hashable {
    let fact: LocalFact
    let distanceMeters: CLLocationDistance
    let rankScore: Double
    let reason: String
    let auditReasons: [String]
    let scoreComponents: RankScoreComponents

    var id: String { fact.id }

    init(
        fact: LocalFact,
        distanceMeters: CLLocationDistance,
        rankScore: Double,
        reason: String,
        auditReasons: [String]? = nil,
        scoreComponents: RankScoreComponents? = nil
    ) {
        self.fact = fact
        self.distanceMeters = distanceMeters
        self.rankScore = rankScore
        self.reason = reason
        self.auditReasons = auditReasons ?? [reason]
        self.scoreComponents = scoreComponents ?? RankScoreComponents.fixture
    }
}

struct RankScoreComponents: Codable, Hashable {
    let intrinsicValue: Double
    let preferenceMatch: Double
    let proximity: Double
    let routeRelevance: Double
    let novelty: Double
    let sourceConfidence: Double
    let visualProminence: Double
    let driveByValue: Double
    let quietPenalty: Double
    let safetyPenalty: Double

    static let fixture = RankScoreComponents(
        intrinsicValue: 0.5,
        preferenceMatch: 0,
        proximity: 0.5,
        routeRelevance: 0.5,
        novelty: 1,
        sourceConfidence: 0.75,
        visualProminence: 0.5,
        driveByValue: 0.5,
        quietPenalty: 0,
        safetyPenalty: 0
    )
}

struct NarrationEvent: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let factID: String
    let title: String
    let text: String
    let reason: String
    let distanceMeters: CLLocationDistance
    let routeLabel: String
}

struct FactContext: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let subcategory: String?
    let tags: [String]
    let distanceMeters: Double
    let rankScore: Double
    let reason: String
    let auditReasons: [String]
    let scoreComponents: RankScoreComponents
    let narration: String
    let sourceName: String
    let sourceURL: String
    let sourceURLs: [String]
    let sourceConfidence: Double

    init(
        id: String,
        name: String,
        category: String,
        subcategory: String? = nil,
        tags: [String] = [],
        distanceMeters: Double,
        rankScore: Double,
        reason: String,
        auditReasons: [String]? = nil,
        scoreComponents: RankScoreComponents? = nil,
        narration: String,
        sourceName: String,
        sourceURL: String,
        sourceURLs: [String]? = nil,
        sourceConfidence: Double = 0.75
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.subcategory = subcategory
        self.tags = tags
        self.distanceMeters = distanceMeters
        self.rankScore = rankScore
        self.reason = reason
        self.auditReasons = auditReasons ?? [reason]
        self.scoreComponents = scoreComponents ?? .fixture
        self.narration = narration
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.sourceURLs = sourceURLs ?? [sourceURL]
        self.sourceConfidence = sourceConfidence
    }
}

struct DriveContextSnapshot: Codable, Hashable {
    struct Coordinates: Codable, Hashable {
        let latitude: Double
        let longitude: Double
    }

    let generatedAt: Date
    let routeLabel: String
    let coordinates: Coordinates
    let progress: Double
    let nearbyFacts: [FactContext]
    let lastSpokenFactID: String?
    let lastDecisionReason: String
    let preferredCategories: [String]
    let excludedCategories: [String]
    let quietMode: Bool

    var summary: String {
        let progressPercent = Int((progress * 100).rounded())
        var preferencePieces = [
            preferredCategories.isEmpty ? "balanced" : "prefers \(preferredCategories.joined(separator: ", "))"
        ]
        if !excludedCategories.isEmpty {
            preferencePieces.append("skips \(excludedCategories.joined(separator: ", "))")
        }
        let voiceText = quietMode ? "quiet" : "normal"
        let preferenceText = preferencePieces.joined(separator: "; ")
        let nearbyText = nearbyFacts.prefix(3)
            .map { "\($0.name) (\($0.category), \(Int($0.distanceMeters))m)" }
            .joined(separator: "; ")

        return [
            "Route: \(routeLabel) (\(progressPercent)%)",
            "Voice: \(voiceText)",
            "Preference: \(preferenceText)",
            "Nearby: \(nearbyText.isEmpty ? "none" : nearbyText)",
            "Decision: \(lastDecisionReason)"
        ].joined(separator: " | ")
    }
}

struct StagedRealtimeContext: Codable, Hashable {
    let topFacts: [FactContext]

    init(snapshot: DriveContextSnapshot, preferences: RealtimeGuidePreferences, limit: Int = 4) {
        topFacts = snapshot.nearbyFacts
            .filter { !preferences.excludedCategories.contains($0.category.lowercased()) }
            .sorted { lhs, rhs in
                let lhsPreferred = preferences.preferredCategories.contains(lhs.category.lowercased())
                let rhsPreferred = preferences.preferredCategories.contains(rhs.category.lowercased())

                if lhsPreferred != rhsPreferred {
                    return lhsPreferred
                }

                return lhs.rankScore > rhs.rankScore
            }
            .prefix(limit)
            .map { $0 }
    }
}

enum GuideVoiceMode: String, Codable, Hashable, CaseIterable {
    case local
    case realtime

    static var aiGuide: GuideVoiceMode { .realtime }
}

enum RealtimeConnectionState: String, Codable, Hashable, CaseIterable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case speaking
    case fallback
    case failed

    var description: String {
        switch self {
        case .failed:
            return "error"
        default:
            return rawValue
        }
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let start = CLLocation(latitude: latitude, longitude: longitude)
        let end = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return start.distance(from: end)
    }
}
