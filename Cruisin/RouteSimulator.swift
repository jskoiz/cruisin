import CoreLocation
import Foundation

protocol LocationSampleProviding {
    var currentCoordinate: CLLocationCoordinate2D { get }
    var currentLabel: String { get }
    var progress: Double { get }

    mutating func advance(by timeInterval: TimeInterval) -> Bool
    mutating func reset()
}

struct RouteSimulator: LocationSampleProviding {
    private let route: [RouteWaypoint]
    private(set) var currentIndex: Int = 0
    private(set) var elapsedTime: TimeInterval = 0

    init(route: [RouteWaypoint]) {
        self.route = route
    }

    var currentCoordinate: CLLocationCoordinate2D {
        guard let first = route.first else {
            return CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)
        }

        guard route.count > 1, elapsedTime > first.secondsFromStart else {
            return first.coordinate
        }

        guard let nextIndex = route.indices.dropFirst().first(where: { route[$0].secondsFromStart >= elapsedTime }) else {
            return route.last?.coordinate ?? first.coordinate
        }

        let start = route[nextIndex - 1]
        let end = route[nextIndex]
        let segmentDuration = end.secondsFromStart - start.secondsFromStart

        guard segmentDuration > 0 else {
            return end.coordinate
        }

        let fraction = min(max((elapsedTime - start.secondsFromStart) / segmentDuration, 0), 1)
        return CLLocationCoordinate2D(
            latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
            longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
        )
    }

    var currentLabel: String {
        guard route.indices.contains(currentIndex) else { return "Honolulu" }
        return route[currentIndex].label
    }

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(max(elapsedTime / totalDuration, 0), 1)
    }

    mutating func advance(by timeInterval: TimeInterval) -> Bool {
        guard totalDuration > 0, elapsedTime < totalDuration else { return false }
        elapsedTime = min(elapsedTime + max(timeInterval, 0), totalDuration)
        updateCurrentIndex()
        return true
    }

    mutating func reset() {
        currentIndex = 0
        elapsedTime = 0
    }

    private var totalDuration: TimeInterval {
        route.last?.secondsFromStart ?? 0
    }

    private mutating func updateCurrentIndex() {
        guard route.count > 1 else {
            currentIndex = 0
            return
        }

        if elapsedTime >= totalDuration {
            currentIndex = route.count - 1
            return
        }

        currentIndex = route.indices.dropLast().last(where: { route[$0].secondsFromStart <= elapsedTime }) ?? 0
    }
}
