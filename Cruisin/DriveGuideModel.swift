import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class DriveGuideModel: ObservableObject {
    @Published private(set) var facts: [LocalFact]
    @Published private(set) var route: [RouteWaypoint]
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D
    @Published private(set) var currentLabel: String
    @Published private(set) var progress: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var nearbyCandidates: [NearbyCandidate] = []
    @Published private(set) var lastDecisionReason = "Ready"
    @Published private(set) var narrationStatus = "Idle"
    @Published private(set) var lastSpokenFactID: String?
    @Published private(set) var spokenEvents: [NarrationEvent] = []

    private var simulator: RouteSimulator
    private let engine = NarrationEngine()
    private let narrator: VoiceNarrating
    private var replayTask: Task<Void, Never>?
    private var spokenIDs = Set<String>()
    private var lastSpokenAt: Date?
    private var lastAreaID: String?

    init(narrator: VoiceNarrating? = nil) {
        let loadedFacts = SeedDataStore.loadFacts()
        let loadedRoute = SeedDataStore.loadRoute()
        let routeSimulator = RouteSimulator(route: loadedRoute)

        self.facts = loadedFacts
        self.route = loadedRoute
        self.simulator = routeSimulator
        self.currentCoordinate = routeSimulator.currentCoordinate
        self.currentLabel = routeSimulator.currentLabel
        self.narrator = narrator ?? SpeechNarrator()

        refreshCandidates(allowSpeech: false)
    }

    var visibleFacts: [LocalFact] {
        Array(nearbyCandidates.prefix(10).map(\.fact))
    }

    func start() {
        isRunning = true
        narrationStatus = "Route replay active"
        ensureReplayTask()
    }

    func pause() {
        isRunning = false
        narrationStatus = "Paused"
        narrator.stop()
    }

    func routeReplay() {
        simulator.reset()
        spokenIDs.removeAll()
        spokenEvents.removeAll()
        lastSpokenAt = nil
        lastAreaID = nil
        lastSpokenFactID = nil
        syncFromSimulator()
        refreshCandidates(allowSpeech: false)
        start()
    }

    private func ensureReplayTask() {
        guard replayTask == nil else { return }
        replayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_250_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isRunning else { return }

        if simulator.advance() {
            syncFromSimulator()
            refreshCandidates(allowSpeech: true)
        } else {
            isRunning = false
            narrationStatus = "Route complete"
            lastDecisionReason = "Reached the end of the bundled Honolulu demo route"
        }
    }

    private func syncFromSimulator() {
        currentCoordinate = simulator.currentCoordinate
        currentLabel = simulator.currentLabel
        progress = simulator.progress
    }

    private func refreshCandidates(allowSpeech: Bool) {
        let now = Date()
        nearbyCandidates = engine.candidates(near: currentCoordinate, facts: facts)

        guard allowSpeech else {
            lastDecisionReason = "Speech held until Start or Route Replay"
            return
        }

        if let decision = engine.decision(
            from: nearbyCandidates,
            spokenIDs: spokenIDs,
            lastSpokenAt: lastSpokenAt,
            lastAreaID: lastAreaID,
            now: now
        ) {
            speak(decision: decision, now: now)
        } else {
            lastDecisionReason = engine.noSelectionReason(
                candidates: nearbyCandidates,
                lastSpokenAt: lastSpokenAt,
                now: now
            )
        }
    }

    private func speak(decision: NarrationDecision, now: Date) {
        let fact = decision.candidate.fact
        spokenIDs.insert(fact.id)
        lastSpokenAt = now
        lastSpokenFactID = fact.id
        lastDecisionReason = decision.reason
        narrationStatus = "Speaking: \(fact.name)"

        if fact.category == "area" {
            lastAreaID = fact.id
        }

        narrator.speak(fact.narration)

        let event = NarrationEvent(
            timestamp: now,
            factID: fact.id,
            title: fact.name,
            text: fact.narration,
            reason: decision.reason,
            distanceMeters: decision.candidate.distanceMeters,
            routeLabel: currentLabel
        )
        spokenEvents.insert(event, at: 0)
        spokenEvents = Array(spokenEvents.prefix(8))
    }
}
