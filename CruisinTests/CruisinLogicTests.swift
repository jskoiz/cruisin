import CoreLocation
import XCTest

final class CruisinLogicTests: XCTestCase {
    func testCandidateRankingUsesPreferenceBoostBeforeDistanceTieBreaks() {
        let coordinate = CLLocationCoordinate2D(latitude: 21.3000, longitude: -157.8500)
        let facts = [
            fact(id: "food", name: "Plate Lunch", category: "food", latitude: 21.3000, longitude: -157.8500, priority: 1),
            fact(id: "culture", name: "Cultural Center", category: "culture", latitude: 21.3000, longitude: -157.8500, priority: 1),
            fact(id: "remote", name: "Remote Beach", category: "nature", latitude: 21.3200, longitude: -157.8500, priority: 5)
        ]

        let candidates = NarrationEngine().candidates(
            near: coordinate,
            facts: facts,
            preferredCategories: ["food"]
        )

        XCTAssertEqual(candidates.map(\.fact.id), ["food", "culture"])
        XCTAssertGreaterThan(candidates[0].rankScore, candidates[1].rankScore)
        XCTAssertTrue(candidates[0].reason.contains("preference boost"))
    }

    func testCooldownBlocksNarrationAndExplainsRemainingTime() {
        let engine = NarrationEngine()
        let now = Date(timeIntervalSince1970: 1_000)
        let candidate = NearbyCandidate(
            fact: fact(id: "history", name: "Historic Site", category: "history", priority: 2),
            distanceMeters: 20,
            rankScore: 900,
            reason: "20 m away, history, priority 2"
        )

        let decision = engine.decision(
            from: [candidate],
            spokenIDs: [],
            lastSpokenAt: now.addingTimeInterval(-5),
            lastAreaID: nil,
            now: now
        )

        XCTAssertNil(decision)
        XCTAssertEqual(
            engine.noSelectionReason(candidates: [candidate], lastSpokenAt: now.addingTimeInterval(-5), now: now),
            "Cooling down for 8 s"
        )
    }

    func testRouteSimulatorProgressAdvancesAndResets() {
        var simulator = RouteSimulator(route: [
            waypoint(id: "start", label: "Start", secondsFromStart: 0),
            waypoint(id: "mid", label: "Midpoint", secondsFromStart: 10),
            waypoint(id: "end", label: "End", secondsFromStart: 20)
        ])

        XCTAssertEqual(simulator.currentLabel, "Start")
        XCTAssertEqual(simulator.progress, 0)

        XCTAssertTrue(simulator.advance(by: 10))
        XCTAssertEqual(simulator.currentLabel, "Midpoint")
        XCTAssertEqual(simulator.progress, 0.5, accuracy: 0.001)

        XCTAssertTrue(simulator.advance(by: 10))
        XCTAssertEqual(simulator.currentLabel, "End")
        XCTAssertEqual(simulator.progress, 1, accuracy: 0.001)

        XCTAssertFalse(simulator.advance(by: 10))
        XCTAssertEqual(simulator.progress, 1, accuracy: 0.001)

        simulator.reset()
        XCTAssertEqual(simulator.currentLabel, "Start")
        XCTAssertEqual(simulator.progress, 0)
    }

    func testRouteSimulatorAdvancesByElapsedTimeAndInterpolatesCoordinate() {
        var simulator = RouteSimulator(route: [
            waypoint(id: "start", label: "Start", latitude: 21.0, longitude: -157.0, secondsFromStart: 0),
            waypoint(id: "end", label: "End", latitude: 21.0, longitude: -156.0, secondsFromStart: 100)
        ])

        XCTAssertTrue(simulator.advance(by: 25))

        XCTAssertEqual(simulator.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(simulator.currentCoordinate.latitude, 21.0, accuracy: 0.0001)
        XCTAssertEqual(simulator.currentCoordinate.longitude, -156.75, accuracy: 0.0001)
    }

    func testDriveContextSnapshotSummaryIsCompactAndCapped() {
        let snapshot = DriveContextSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000),
            routeLabel: "Harbor loop",
            coordinates: .init(latitude: 21.3000, longitude: -157.8500),
            progress: 0.424,
            nearbyFacts: [
                factContext(name: "Bishop Museum", category: "history", distanceMeters: 88),
                factContext(name: "Lunch Spot", category: "food", distanceMeters: 120),
                factContext(name: "Lookout", category: "lookout", distanceMeters: 240),
                factContext(name: "Hidden Garden", category: "nature", distanceMeters: 360)
            ],
            lastSpokenFactID: "bishop",
            lastDecisionReason: "Cooling down for 3 s",
            preferredCategories: ["history", "culture"],
            excludedCategories: ["food"],
            quietMode: true
        )

        XCTAssertEqual(
            snapshot.summary,
            "Route: Harbor loop (42%) | Voice: quiet | Preference: prefers history, culture; skips food | Nearby: Bishop Museum (history, 88m); Lunch Spot (food, 120m); Lookout (lookout, 240m) | Decision: Cooling down for 3 s"
        )
        XCTAssertFalse(snapshot.summary.contains("Hidden Garden"))
    }

    func testCannedInterruptionPrefersHistorySkipsFoodAndEnablesQuietMode() {
        var preferences = RealtimeGuidePreferences()

        XCTAssertTrue(preferences.infer(from: "Skip food. Give me the history angle, and keep it short."))
        XCTAssertEqual(preferences.preferredCategories, ["history"])
        XCTAssertEqual(preferences.excludedCategories, ["food"])
        XCTAssertTrue(preferences.quietMode)
        XCTAssertEqual(preferences.auditSummary, "prefers history; skips food; quiet/short")
    }

    private func fact(
        id: String,
        name: String,
        category: String,
        latitude: Double = 21.3000,
        longitude: Double = -157.8500,
        priority: Int
    ) -> LocalFact {
        LocalFact(
            id: id,
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude,
            narration: "\(name) narration",
            sourceName: "fixture",
            sourceURL: "https://example.invalid/\(id)",
            priority: priority
        )
    }

    private func waypoint(
        id: String,
        label: String,
        latitude: Double = 21.3000,
        longitude: Double = -157.8500,
        secondsFromStart: TimeInterval
    ) -> RouteWaypoint {
        RouteWaypoint(
            id: id,
            label: label,
            latitude: latitude,
            longitude: longitude,
            secondsFromStart: secondsFromStart
        )
    }

    private func factContext(
        name: String,
        category: String,
        distanceMeters: Double
    ) -> FactContext {
        FactContext(
            id: name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name,
            category: category,
            distanceMeters: distanceMeters,
            rankScore: 1000 - distanceMeters,
            reason: "\(Int(distanceMeters)) m away",
            narration: "\(name) narration",
            sourceName: "fixture",
            sourceURL: "https://example.invalid"
        )
    }
}
