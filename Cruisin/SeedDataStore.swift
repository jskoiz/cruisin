import Foundation

enum SeedDataStore {
    static func loadFacts() -> [LocalFact] {
        load("HonoluluFacts", as: [LocalFact].self)
    }

    static func loadRoute() -> [RouteWaypoint] {
        load("HonoluluRoute", as: [RouteWaypoint].self)
    }

    private static func load<T: Decodable>(_ resource: String, as type: T.Type) -> T {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            assertionFailure("Missing bundled resource: \(resource).json")
            return fallback(type)
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            assertionFailure("Failed to decode \(resource).json: \(error)")
            return fallback(type)
        }
    }

    private static func fallback<T>(_ type: T.Type) -> T {
        if type == [LocalFact].self {
            return [] as! T
        }
        if type == [RouteWaypoint].self {
            return [
                RouteWaypoint(
                    id: "fallback-waikiki",
                    label: "Waikiki",
                    latitude: 21.2766,
                    longitude: -157.8268,
                    secondsFromStart: 0
                )
            ] as! T
        }
        fatalError("No fallback available for \(type)")
    }
}
