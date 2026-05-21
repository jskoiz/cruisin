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

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let start = CLLocation(latitude: latitude, longitude: longitude)
        let end = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return start.distance(from: end)
    }
}
