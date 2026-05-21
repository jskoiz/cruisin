import CoreLocation
import Foundation

protocol LocationSampleProviding {
    var currentCoordinate: CLLocationCoordinate2D { get }
    var currentLabel: String { get }
    var progress: Double { get }

    mutating func advance() -> Bool
    mutating func reset()
}

struct RouteSimulator: LocationSampleProviding {
    private let route: [RouteWaypoint]
    private(set) var currentIndex: Int = 0

    init(route: [RouteWaypoint]) {
        self.route = route
    }

    var currentCoordinate: CLLocationCoordinate2D {
        guard route.indices.contains(currentIndex) else {
            return CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)
        }
        return route[currentIndex].coordinate
    }

    var currentLabel: String {
        guard route.indices.contains(currentIndex) else { return "Honolulu" }
        return route[currentIndex].label
    }

    var progress: Double {
        guard route.count > 1 else { return 0 }
        return Double(currentIndex) / Double(route.count - 1)
    }

    mutating func advance() -> Bool {
        guard currentIndex < route.count - 1 else { return false }
        currentIndex += 1
        return true
    }

    mutating func reset() {
        currentIndex = 0
    }
}
