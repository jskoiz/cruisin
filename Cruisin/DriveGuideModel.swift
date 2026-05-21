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
    @Published var guideVoiceMode: GuideVoiceMode = .realtime {
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
    @Published var questionDraft = ""
    @Published private(set) var voiceQuestionTranscript = ""
    @Published private(set) var voiceQuestionStatus = "Push-to-talk starts with AI Guide"
    @Published private(set) var isListeningForQuestion = false

    private var simulator: RouteSimulator
    private let engine = NarrationEngine()
    private let narrator: VoiceNarrating
    private let realtimeGuide: RealtimeGuideSessioning?
    private let voiceQuestionRecorder = VoiceQuestionRecorder()
    private var replayTask: Task<Void, Never>?
    private var realtimeNarrationTask: Task<Void, Never>?
    private var realtimeCancellables = Set<AnyCancellable>()
    private var spokenIDs = Set<String>()
    private var lastSpokenAt: Date?
    private var lastReplayTickAt: Date?
    private var lastAreaID: String?
    private var shouldResumeRouteContextAfterQuestion = false
    private var isStartingVoiceQuestion = false
    private var shouldFinishVoiceQuestionAfterStart = false
    private var lastRealtimeContextUpdateAt: Date?
    private var routeNarrationHoldUntil: Date?
    private let questionRouteNarrationGraceSeconds: TimeInterval = 30

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
        guideVoiceMode: GuideVoiceMode = .realtime
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
        configureVoiceQuestionRecorder()

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
        guard !isRunning else { return }
        isRunning = true
        lastReplayTickAt = Date()
        narrationStatus = "Route replay active"
        ensureReplayTask()
    }

    func pause() {
        isRunning = false
        lastReplayTickAt = nil
        narrationStatus = "Paused"
        narrator.stop()
        cancelRealtimeResponse(updateStatus: false)
    }

    func routeReplay() {
        simulator.reset()
        spokenIDs.removeAll()
        spokenEvents.removeAll()
        lastSpokenAt = nil
        routeNarrationHoldUntil = nil
        lastReplayTickAt = nil
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

    func beginVoiceQuestion() {
        guard guideVoiceMode == .realtime else {
            fallbackReason = "Switch to AI Guide before using push-to-talk."
            voiceQuestionStatus = "AI Guide required"
            return
        }

        guard !isListeningForQuestion, !isStartingVoiceQuestion else { return }

        isStartingVoiceQuestion = true
        shouldFinishVoiceQuestionAfterStart = false
        voiceQuestionStatus = "Starting push-to-talk"
        cancelRealtimeResponse(updateStatus: false)
        publishRealtimeRouteContext(force: true)

        Task { [weak self] in
            guard let self else { return }

            do {
                try await voiceQuestionRecorder.start()
                isStartingVoiceQuestion = false
                isListeningForQuestion = true
                voiceQuestionStatus = "Listening - release when done"

                if shouldFinishVoiceQuestionAfterStart {
                    shouldFinishVoiceQuestionAfterStart = false
                    finishVoiceQuestion()
                }
            } catch {
                isStartingVoiceQuestion = false
                shouldFinishVoiceQuestionAfterStart = false
                isListeningForQuestion = false
                voiceQuestionStatus = "Voice input unavailable"
                fallbackReason = error.localizedDescription
            }
        }
    }

    func finishVoiceQuestion() {
        if isStartingVoiceQuestion {
            shouldFinishVoiceQuestionAfterStart = true
            voiceQuestionStatus = "Release detected"
            return
        }

        guard isListeningForQuestion else { return }

        voiceQuestionRecorder.finish()
        voiceQuestionStatus = "Sending voice turn"
        holdRouteNarrationAfterQuestion()

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            isListeningForQuestion = false

            if let realtimeGuide {
                await realtimeGuide.finishMicrophoneTurn()
                syncRealtimeGuideState(from: realtimeGuide)
            }

            if voiceQuestionStatus == "Sending voice turn" {
                voiceQuestionStatus = "AI Guide answering"
            }
        }
    }

    func cancelVoiceQuestion() {
        isStartingVoiceQuestion = false
        shouldFinishVoiceQuestionAfterStart = false
        isListeningForQuestion = false
        voiceQuestionRecorder.cancel()
        voiceQuestionTranscript = ""
        voiceQuestionStatus = guideVoiceMode == .realtime ? "Hold mic to talk" : "Push-to-talk starts with AI Guide"
        clearRealtimeMicrophoneBuffer()
    }

    func submitQuestionDraft() {
        let trimmedQuestion = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            voiceQuestionStatus = isListeningForQuestion ? "Listening - release when done" : "Hold mic to talk"
            return
        }

        questionDraft = ""
        voiceQuestionTranscript = trimmedQuestion
        voiceQuestionStatus = "Asking AI Guide"
        submitUserUtterance(trimmedQuestion)
    }

    func sendCannedInterruption() {
        submitUserUtterance(Self.demoInterruptionText)
    }

    func submitUserUtterance(_ text: String = DriveGuideModel.demoInterruptionText) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        lastUserUtterance = trimmedText
        narrator.stop()
        let changedPreferences = applyPreferenceHints(from: trimmedText)
        refreshCandidates(
            allowSpeech: false,
            holdReason: changedPreferences ? "Updated guide preference from user utterance" : "Driver question sent to AI Guide"
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
        lastSpokenAt = Date()
        holdRouteNarrationAfterQuestion()
        shouldResumeRouteContextAfterQuestion = isRunning
        if isListeningForQuestion {
            isListeningForQuestion = false
            voiceQuestionRecorder.cancel()
            voiceQuestionStatus = "Text interruption sent"
            clearRealtimeMicrophoneBuffer()
        }
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isRunning else { return }

        let now = Date()
        let elapsed = lastReplayTickAt.map { now.timeIntervalSince($0) } ?? 1
        lastReplayTickAt = now

        if simulator.advance(by: elapsed) {
            syncFromSimulator()
            refreshCandidates(allowSpeech: true)
            publishRealtimeRouteContext()
        } else {
            isRunning = false
            lastReplayTickAt = nil
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
                preferredCategories: preferredCategories,
                quietMode: quietMode,
                spokenIDs: spokenIDs
            )
        } else {
            let unfilteredCandidates = engine.candidates(
                near: currentCoordinate,
                facts: facts,
                preferredCategories: preferredCategories,
                quietMode: quietMode,
                spokenIDs: spokenIDs
            )
            excludedNearbyCandidateCount = unfilteredCandidates.filter { candidate in
                excludedCategories.contains(candidate.fact.category.lowercased())
            }.count
            nearbyCandidates = engine.candidates(
                near: currentCoordinate,
                facts: facts,
                preferredCategories: preferredCategories,
                excludedCategories: excludedCategories,
                quietMode: quietMode,
                spokenIDs: spokenIDs
            )
        }

        guard allowSpeech else {
            lastDecisionReason = holdReason
            updateContextSummary()
            return
        }

        if let routeNarrationHoldUntil, now < routeNarrationHoldUntil {
            lastDecisionReason = "Holding route narration so the AI Guide can finish the driver question"
            updateContextSummary()
            return
        }

        if guideVoiceMode == .realtime, realtimeState == .speaking {
            lastDecisionReason = "AI Guide is answering; skipping this waypoint narration"
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
        narrationStatus = "AI Guide answering"

        await realtimeGuide.sendUserQuestion(text, snapshot: snapshot)

        guard !Task.isCancelled else { return }
        syncRealtimeGuideState(from: realtimeGuide)

        if shouldUseLocalFallback(for: realtimeGuide) {
            fallbackReason = "AI Guide could not handle the interruption; Local Guide preferences were saved."
            shouldResumeRouteContextAfterQuestion = false
            voiceQuestionStatus = "AI Guide fallback active"
            narrationStatus = "AI interruption failed"
        } else if realtimeState != .speaking {
            resumeRouteContextAfterQuestion()
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
        let previousRealtimeState = realtimeState
        realtimeState = realtimeGuide.state

        if !realtimeGuide.lastTranscript.isEmpty {
            lastModelTranscript = realtimeGuide.lastTranscript
        }

        if !realtimeGuide.lastUserUtterance.isEmpty {
            lastUserUtterance = realtimeGuide.lastUserUtterance
            voiceQuestionTranscript = realtimeGuide.lastUserUtterance
        }

        let guideSummary = realtimeGuide.lastContextSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guideSummary.isEmpty else { return }
        guard guideSummary != "Realtime guide idle" else { return }

        if realtimeGuide.isFallbackActive || realtimeGuide.state == .fallback || realtimeGuide.state == .failed {
            fallbackReason = guideSummary
        } else if realtimeGuide.state == .connected || realtimeGuide.state == .speaking {
            lastContextSummary = guideSummary
        }

        if realtimeGuide.state == .failed {
            realtimeErrorMessage = guideSummary
        }

        if guideSummary.contains("Driver voice detected") {
            voiceQuestionStatus = "Interrupting"
        } else if guideSummary.contains("Driver voice captured") {
            voiceQuestionStatus = "AI Guide answering"
        } else if realtimeGuide.state == .connected, isListeningForQuestion {
            voiceQuestionStatus = "Listening - release when done"
        }

        if shouldResumeRouteContextAfterQuestion,
           previousRealtimeState == .speaking,
           realtimeGuide.state == .connected {
            resumeRouteContextAfterQuestion()
        }

    }

    private func resumeRouteContextAfterQuestion() {
        shouldResumeRouteContextAfterQuestion = false
        realtimeState = .connected
        voiceQuestionStatus = isListeningForQuestion ? "Listening - release when done" : "Hold mic to talk"

        if isRunning {
            refreshCandidates(
                allowSpeech: false,
                holdReason: "Resumed route context after driver question"
            )
            narrationStatus = "Route replay active"
        } else {
            narrationStatus = "AI Guide ready"
            updateContextSummary()
        }
    }

    private func holdRouteNarrationAfterQuestion() {
        let holdUntil = Date().addingTimeInterval(questionRouteNarrationGraceSeconds)
        if let routeNarrationHoldUntil, routeNarrationHoldUntil > holdUntil {
            return
        }

        routeNarrationHoldUntil = holdUntil
        lastSpokenAt = Date()
    }

    private func publishRealtimeRouteContext(force: Bool = false) {
        guard guideVoiceMode == .realtime, let realtimeGuide else { return }
        guard realtimeState == .connected || realtimeState == .speaking else { return }
        guard !shouldUseLocalFallback(for: realtimeGuide) else { return }

        let now = Date()
        if !force, let lastRealtimeContextUpdateAt, now.timeIntervalSince(lastRealtimeContextUpdateAt) < 2.5 {
            return
        }

        lastRealtimeContextUpdateAt = now
        let snapshot = makeSnapshot()

        Task { [weak self, weak realtimeGuide] in
            guard let self, let realtimeGuide else { return }
            await realtimeGuide.updateRouteContext(snapshot: snapshot)
            self.syncRealtimeGuideState(from: realtimeGuide)
        }
    }

    private func clearRealtimeMicrophoneBuffer() {
        guard guideVoiceMode == .realtime, let realtimeGuide else { return }

        Task { @MainActor [weak self, weak realtimeGuide] in
            guard let self, let realtimeGuide else { return }
            await realtimeGuide.clearMicrophoneAudio()
            self.syncRealtimeGuideState(from: realtimeGuide)
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
            cancelVoiceQuestion()
        } else {
            if realtimeState == .disconnected || realtimeState == .connecting {
                realtimeState = .connected
            }
            narrationStatus = isRunning ? "AI Guide active" : "AI Guide ready"
            publishRealtimeRouteContext(force: true)
            voiceQuestionStatus = "Hold mic to talk"
        }
    }

    private func handleGuideVoiceModeChange() {
        switch guideVoiceMode {
        case .local:
            cancelVoiceQuestion()
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
                cancelVoiceQuestion()
            } else if realtimeState == .failed {
                fallbackReason = "AI Guide failed earlier; select Local Guide or restart the session to retry."
                narrationStatus = "AI Guide failed - local fallback"
                cancelVoiceQuestion()
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

    @discardableResult
    private func applyPreferenceHints(from text: String) -> Bool {
        var preferences = RealtimeGuidePreferences(
            preferredCategories: preferredCategories.sorted(),
            excludedCategories: excludedCategories.sorted(),
            quietMode: quietMode
        )
        guard preferences.infer(from: text) else { return false }

        preferredCategories = Set(preferences.preferredCategories)
        excludedCategories = Set(preferences.excludedCategories)
        quietMode = preferences.quietMode
        return true
    }

    private func updateContextSummary() {
        _ = makeSnapshot()
    }

    private func configureVoiceQuestionRecorder() {
        voiceQuestionRecorder.onAudioData = { [weak self] audioData in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self, let realtimeGuide else { return }
                guard self.isListeningForQuestion else { return }
                await realtimeGuide.appendMicrophoneAudio(audioData)
                syncRealtimeGuideState(from: realtimeGuide)
            }
        }

        voiceQuestionRecorder.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isListeningForQuestion = false
                self.voiceQuestionStatus = "Voice input unavailable"
                self.fallbackReason = message
            }
        }
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
            subcategory: candidate.fact.subcategory,
            tags: candidate.fact.tags,
            distanceMeters: candidate.distanceMeters,
            rankScore: candidate.rankScore,
            reason: candidate.reason,
            auditReasons: candidate.auditReasons,
            scoreComponents: candidate.scoreComponents,
            narration: candidate.fact.narration,
            sourceName: candidate.fact.sourceName,
            sourceURL: candidate.fact.sourceURL,
            sourceURLs: candidate.fact.sourceURLs,
            sourceConfidence: candidate.fact.sourceConfidence
        )
    }
}
