import CoreLocation
import Foundation

struct LocalFact: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let latitude: Double
    let longitude: Double
    let narration: String
    let sourceName: String
    let sourceURL: String
    let priority: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

    var id: String { fact.id }
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
    let distanceMeters: Double
    let rankScore: Double
    let reason: String
    let narration: String
    let sourceName: String
    let sourceURL: String
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
    let quietMode: Bool

    var summary: String {
        let progressPercent = Int((progress * 100).rounded())
        let preferenceText = preferredCategories.isEmpty ? "balanced" : preferredCategories.joined(separator: ", ")
        let voiceText = quietMode ? "quiet" : "normal"
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
