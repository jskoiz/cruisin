import Combine
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class DriveGuideModel: ObservableObject {
    nonisolated static let demoInterruptionText = "Skip food. Give me the history angle, and keep it short."

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
    @Published var guideVoiceMode: GuideVoiceMode = .local {
        didSet {
            guard guideVoiceMode != oldValue else { return }
            handleGuideVoiceModeChange()
        }
    }
    @Published private(set) var realtimeState: RealtimeConnectionState = .disconnected
    @Published private(set) var lastModelTranscript: String?
    @Published private(set) var lastUserUtterance: String?
    @Published private(set) var lastContextSummary: String?
    @Published private(set) var preferredCategories = Set<String>()
    @Published private(set) var excludedCategories = Set<String>()
    @Published private(set) var excludedNearbyCandidateCount = 0
    @Published private(set) var quietMode = false
    @Published private(set) var fallbackReason: String?
    @Published private(set) var realtimeErrorMessage: String?

    private var simulator: RouteSimulator
    private let engine = NarrationEngine()
    private let narrator: VoiceNarrating
    private let realtimeGuide: RealtimeGuideSessioning?
    private var replayTask: Task<Void, Never>?
    private var realtimeNarrationTask: Task<Void, Never>?
    private var realtimeCancellables = Set<AnyCancellable>()
    private var spokenIDs = Set<String>()
    private var lastSpokenAt: Date?
    private var lastAreaID: String?

    var realtimeStatus: RealtimeConnectionState {
        realtimeState
    }

    var fallbackErrorState: String? {
        let messages = [fallbackReason, realtimeErrorMessage]
            .compactMap { message -> String? in
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }

        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    var preferenceAuditSummary: String {
        var pieces: [String] = [
            preferredCategories.isEmpty ? "Balanced categories" : "Prefers \(preferredCategories.sorted().joined(separator: ", "))"
        ]

        if excludedCategories.isEmpty {
            pieces.append("No category skips")
        } else {
            pieces.append("Skips \(excludedCategories.sorted().joined(separator: ", "))")
        }

        pieces.append(quietMode ? "Quiet/short replies" : "Normal length")

        if excludedNearbyCandidateCount > 0 {
            let categoryText = excludedCategories.sorted().joined(separator: ", ")
            let noun = excludedNearbyCandidateCount == 1 ? "candidate" : "candidates"
            pieces.append("Filtered \(excludedNearbyCandidateCount) nearby \(categoryText) \(noun)")
        }

        return pieces.joined(separator: " | ")
    }

    init(
        narrator: VoiceNarrating? = nil,
        realtimeGuide: RealtimeGuideSessioning? = nil,
        guideVoiceMode: GuideVoiceMode = .local
    ) {
        let loadedFacts = SeedDataStore.loadFacts()
        let loadedRoute = SeedDataStore.loadRoute()
        let routeSimulator = RouteSimulator(route: loadedRoute)
        let resolvedRealtimeGuide = realtimeGuide ?? RealtimeGuideSession()

        self.facts = loadedFacts
        self.route = loadedRoute
        self.simulator = routeSimulator
        self.currentCoordinate = routeSimulator.currentCoordinate
        self.currentLabel = routeSimulator.currentLabel
        self.narrator = narrator ?? SpeechNarrator()
        self.realtimeGuide = resolvedRealtimeGuide
        self.guideVoiceMode = guideVoiceMode

        bindRealtimeGuideIfNeeded(resolvedRealtimeGuide)

        refreshCandidates(allowSpeech: false)

        if guideVoiceMode == .realtime {
            handleGuideVoiceModeChange()
        } else {
            updateContextSummary()
        }
    }

    deinit {
        replayTask?.cancel()
        realtimeNarrationTask?.cancel()
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
        cancelRealtimeResponse(updateStatus: false)
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

    func selectGuideVoiceMode(_ mode: GuideVoiceMode) {
        guideVoiceMode = mode
    }

    func selectLocalGuide() {
        guideVoiceMode = .local
    }

    func selectAIGuide() {
        guideVoiceMode = .realtime
    }

    func sendCannedInterruption() {
        submitUserUtterance(Self.demoInterruptionText)
    }

    func submitUserUtterance(_ text: String = DriveGuideModel.demoInterruptionText) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        lastUserUtterance = trimmedText
        narrator.stop()
        applyPreferenceHints(from: trimmedText)
        refreshCandidates(
            allowSpeech: false,
            holdReason: "Updated guide preference from user utterance"
        )

        let snapshot = makeSnapshot()

        guard guideVoiceMode == .realtime else {
            fallbackReason = "Preference saved for Local Guide; AI Guide is not selected."
            return
        }

        guard realtimeState != .failed else {
            fallbackReason = "AI Guide is in failed state; preference saved for Local Guide fallback."
            return
        }

        guard let realtimeGuide else {
            realtimeState = .fallback
            fallbackReason = "AI Guide session is unavailable; preference saved for Local Guide fallback."
            return
        }

        fallbackReason = nil
        realtimeErrorMessage = nil
        realtimeGuide.cancelCurrentResponse()
        realtimeNarrationTask?.cancel()
        realtimeNarrationTask = Task { [weak self] in
            await self?.submitRealtimeUtterance(trimmedText, snapshot: snapshot, using: realtimeGuide)
        }
    }

    func cancelCurrentResponse() {
        narrator.stop()
        cancelRealtimeResponse(updateStatus: true)
    }

    func setPreferredCategories(_ categories: Set<String>) {
        preferredCategories = Set(categories.map { $0.lowercased() })
        excludedCategories.subtract(preferredCategories)
        refreshCandidates(
            allowSpeech: false,
            holdReason: preferredCategories.isEmpty ? "Cleared guide category preference" : "Updated guide category preference"
        )
    }

    func togglePreferredCategory(_ category: String) {
        let category = category.lowercased()
        var categories = preferredCategories

        if categories.contains(category) {
            categories.remove(category)
        } else {
            categories.insert(category)
        }

        setPreferredCategories(categories)
    }

    func setQuietMode(_ enabled: Bool) {
        quietMode = enabled
        updateContextSummary()
    }

    func recordModelTranscript(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        lastModelTranscript = trimmedTranscript.isEmpty ? nil : trimmedTranscript
    }

    func recordRealtimeState(_ state: RealtimeConnectionState) {
        realtimeState = state
    }

    @discardableResult
    func makeSnapshot() -> DriveContextSnapshot {
        let snapshot = DriveContextSnapshot(
            generatedAt: Date(),
            routeLabel: currentLabel,
            coordinates: DriveContextSnapshot.Coordinates(
                latitude: currentCoordinate.latitude,
                longitude: currentCoordinate.longitude
            ),
            progress: progress,
            nearbyFacts: nearbyCandidates.prefix(5).map(FactContext.init(candidate:)),
            lastSpokenFactID: lastSpokenFactID,
            lastDecisionReason: lastDecisionReason,
            preferredCategories: preferredCategories.sorted(),
            excludedCategories: excludedCategories.sorted(),
            quietMode: quietMode
        )

        lastContextSummary = snapshot.summary
        return snapshot
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
            updateContextSummary()
        }
    }

    private func syncFromSimulator() {
        currentCoordinate = simulator.currentCoordinate
        currentLabel = simulator.currentLabel
        progress = simulator.progress
    }

    private func refreshCandidates(
        allowSpeech: Bool,
        holdReason: String = "Speech held until Start or Route Replay"
    ) {
        let now = Date()
        if excludedCategories.isEmpty {
            excludedNearbyCandidateCount = 0
            nearbyCandidates = engine.candidates(
                near: currentCoordinate,
                facts: facts,
                preferredCategories: preferredCategories
            )
        } else {
            let unfilteredCandidates = engine.candidates(
                near: currentCoordinate,
                facts: facts,
                preferredCategories: preferredCategories
            )
            excludedNearbyCandidateCount = unfilteredCandidates.filter { candidate in
                excludedCategories.contains(candidate.fact.category.lowercased())
            }.count
            nearbyCandidates = engine.candidates(
                near: currentCoordinate,
                facts: facts,
                preferredCategories: preferredCategories,
                excludedCategories: excludedCategories
            )
        }

        guard allowSpeech else {
            lastDecisionReason = holdReason
            updateContextSummary()
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
            updateContextSummary()
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

        let snapshot = makeSnapshot()

        guard guideVoiceMode == .realtime else {
            narrator.speak(fact.narration)
            return
        }

        guard realtimeState != .failed else {
            speakWithLocalFallback(
                fact.narration,
                status: "Local fallback: \(fact.name)",
                reason: "AI Guide is in failed state.",
                state: .failed
            )
            return
        }

        guard let realtimeGuide else {
            speakWithLocalFallback(
                fact.narration,
                status: "Local fallback: \(fact.name)",
                reason: "AI Guide session is unavailable."
            )
            return
        }

        fallbackReason = nil
        realtimeErrorMessage = nil
        realtimeNarrationTask?.cancel()
        realtimeNarrationTask = Task { [weak self] in
            await self?.narrateWithRealtime(
                snapshot: snapshot,
                fallbackText: fact.narration,
                factName: fact.name,
                using: realtimeGuide
            )
        }
    }

    private func narrateWithRealtime(
        snapshot: DriveContextSnapshot,
        fallbackText: String,
        factName: String,
        using realtimeGuide: RealtimeGuideSessioning
    ) async {
        realtimeState = .speaking
        narrationStatus = "AI Guide speaking: \(factName)"

        await realtimeGuide.narrate(snapshot: snapshot)

        guard !Task.isCancelled else { return }
        syncRealtimeGuideState(from: realtimeGuide)

        if shouldUseLocalFallback(for: realtimeGuide) {
            speakWithLocalFallback(
                fallbackText,
                status: "Local fallback: \(factName)",
                reason: realtimeGuide.lastContextSummary.isEmpty ? "AI Guide entered fallback." : realtimeGuide.lastContextSummary,
                state: realtimeGuide.state == .failed ? .failed : .fallback
            )
        } else if realtimeState != .speaking {
            realtimeState = .connected
            narrationStatus = "AI Guide ready"
        }
    }

    private func submitRealtimeUtterance(
        _ text: String,
        snapshot: DriveContextSnapshot,
        using realtimeGuide: RealtimeGuideSessioning
    ) async {
        realtimeState = .speaking
        narrationStatus = "AI Guide updating preference"

        await realtimeGuide.sendUserQuestion(text, snapshot: snapshot)

        guard !Task.isCancelled else { return }
        syncRealtimeGuideState(from: realtimeGuide)

        if shouldUseLocalFallback(for: realtimeGuide) {
            fallbackReason = "AI Guide could not handle the interruption; Local Guide preferences were saved."
            narrationStatus = "AI interruption failed"
        } else if realtimeState != .speaking {
            realtimeState = .connected
            narrationStatus = "AI Guide ready"
        }
    }

    private func speakWithLocalFallback(
        _ text: String,
        status: String,
        reason: String,
        state: RealtimeConnectionState = .fallback
    ) {
        realtimeState = state
        fallbackReason = reason
        narrationStatus = status
        narrator.speak(text)
    }

    private func cancelRealtimeResponse(updateStatus: Bool) {
        realtimeNarrationTask?.cancel()
        realtimeNarrationTask = nil

        guard let realtimeGuide else {
            if updateStatus {
                narrationStatus = "Response canceled"
            }
            return
        }

        realtimeGuide.cancelCurrentResponse()

        if guideVoiceMode == .realtime, realtimeState == .speaking {
            realtimeState = .connected
        }

        if updateStatus {
            narrationStatus = "Response canceled"
        }
    }

    private func syncRealtimeGuideState(from realtimeGuide: RealtimeGuideSessioning) {
        realtimeState = realtimeGuide.state

        if !realtimeGuide.lastTranscript.isEmpty {
            lastModelTranscript = realtimeGuide.lastTranscript
        }

        if !realtimeGuide.lastUserUtterance.isEmpty {
            lastUserUtterance = realtimeGuide.lastUserUtterance
        }

        if !realtimeGuide.lastContextSummary.isEmpty {
            lastContextSummary = realtimeGuide.lastContextSummary
        }

        if realtimeGuide.isFallbackActive, !realtimeGuide.lastContextSummary.isEmpty {
            fallbackReason = realtimeGuide.lastContextSummary
        }

        if realtimeGuide.state == .failed, !realtimeGuide.lastContextSummary.isEmpty {
            realtimeErrorMessage = realtimeGuide.lastContextSummary
        }
    }

    private func shouldUseLocalFallback(for realtimeGuide: RealtimeGuideSessioning) -> Bool {
        realtimeGuide.isFallbackActive || realtimeGuide.state == .fallback || realtimeGuide.state == .failed
    }

    private func connectRealtimeGuide(_ realtimeGuide: RealtimeGuideSessioning) async {
        await realtimeGuide.connect()

        guard !Task.isCancelled else { return }
        syncRealtimeGuideState(from: realtimeGuide)

        if shouldUseLocalFallback(for: realtimeGuide) {
            fallbackReason = realtimeGuide.lastContextSummary.isEmpty ? "AI Guide session entered fallback." : realtimeGuide.lastContextSummary
            narrationStatus = "AI Guide unavailable - local fallback"
        } else {
            if realtimeState == .disconnected || realtimeState == .connecting {
                realtimeState = .connected
            }
            narrationStatus = isRunning ? "AI Guide active" : "AI Guide ready"
        }
    }

    private func handleGuideVoiceModeChange() {
        switch guideVoiceMode {
        case .local:
            cancelRealtimeResponse(updateStatus: false)
            realtimeState = .disconnected
            fallbackReason = nil
            realtimeErrorMessage = nil
            narrationStatus = isRunning ? "Local Guide active" : "Local Guide ready"
        case .realtime:
            if realtimeGuide == nil {
                realtimeState = .fallback
                fallbackReason = "AI Guide session is unavailable; AVFoundation fallback is active."
                narrationStatus = "AI Guide unavailable - local fallback"
            } else if realtimeState == .failed {
                fallbackReason = "AI Guide failed earlier; select Local Guide or restart the session to retry."
                narrationStatus = "AI Guide failed - local fallback"
            } else {
                realtimeState = .connecting
                fallbackReason = nil
                realtimeErrorMessage = nil
                narrationStatus = "AI Guide connecting"
                if let realtimeGuide {
                    Task { [weak self] in
                        await self?.connectRealtimeGuide(realtimeGuide)
                    }
                }
            }
        }

        updateContextSummary()
    }

    private func applyPreferenceHints(from text: String) {
        var preferences = RealtimeGuidePreferences(
            preferredCategories: preferredCategories.sorted(),
            excludedCategories: excludedCategories.sorted(),
            quietMode: quietMode
        )
        guard preferences.infer(from: text) else { return }

        preferredCategories = Set(preferences.preferredCategories)
        excludedCategories = Set(preferences.excludedCategories)
        quietMode = preferences.quietMode
    }

    private func updateContextSummary() {
        _ = makeSnapshot()
    }

    private func bindRealtimeGuideIfNeeded(_ realtimeGuide: RealtimeGuideSessioning?) {
        guard let realtimeSession = realtimeGuide as? RealtimeGuideSession else { return }

        realtimeSession.objectWillChange
            .sink { [weak self, weak realtimeSession] _ in
                Task { @MainActor [weak self, weak realtimeSession] in
                    guard let self, let realtimeSession else { return }
                    self.syncRealtimeGuideState(from: realtimeSession)
                }
            }
            .store(in: &realtimeCancellables)

        realtimeSession.onPreferencesChanged = { [weak self] preferences in
            guard let self else { return }
            self.preferredCategories = Set(preferences.preferredCategories)
            self.excludedCategories = Set(preferences.excludedCategories)
            self.quietMode = preferences.quietMode
            self.refreshCandidates(
                allowSpeech: false,
                holdReason: "Updated guide preference from AI interruption"
            )
        }
    }
}

private extension FactContext {
    init(candidate: NearbyCandidate) {
        self.init(
            id: candidate.fact.id,
            name: candidate.fact.name,
            category: candidate.fact.category,
            distanceMeters: candidate.distanceMeters,
            rankScore: candidate.rankScore,
            reason: candidate.reason,
            narration: candidate.fact.narration,
            sourceName: candidate.fact.sourceName,
            sourceURL: candidate.fact.sourceURL
        )
    }
}
