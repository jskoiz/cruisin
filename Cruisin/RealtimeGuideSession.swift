import Combine
import CoreLocation
import Foundation

@MainActor
protocol RealtimeGuideSessioning: AnyObject {
    var state: RealtimeConnectionState { get }
    var lastTranscript: String { get }
    var lastUserUtterance: String { get }
    var lastContextSummary: String { get }
    var isFallbackActive: Bool { get }

    func connect() async
    func disconnect()
    func narrate(snapshot: DriveContextSnapshot) async
    func cancelCurrentResponse()
    func sendUserQuestion(_ text: String, snapshot: DriveContextSnapshot) async
    func updateRouteContext(snapshot: DriveContextSnapshot) async
    func appendMicrophoneAudio(_ pcmData: Data) async
    func finishMicrophoneTurn() async
    func clearMicrophoneAudio() async
}

@MainActor
final class RealtimeGuideSession: ObservableObject, RealtimeGuideSessioning {
    @Published private(set) var state: RealtimeConnectionState = .disconnected
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastUserUtterance = ""
    @Published private(set) var lastContextSummary = "Realtime guide idle"
    @Published private(set) var isFallbackActive = false
    @Published private(set) var guidePreferences = RealtimeGuidePreferences()

    var onPreferencesChanged: ((RealtimeGuidePreferences) -> Void)?

    private let client: OpenAIRealtimeClient
    private let audioPlayer: RealtimeAudioPlayer
    private var eventTask: Task<Void, Never>?
    private var hasActiveResponse = false
    private var ignoresInputTranscriptionUntilSpeechStart = false

    convenience init(client: OpenAIRealtimeClient = OpenAIRealtimeClient()) {
        self.init(client: client, audioPlayer: RealtimeAudioPlayer())
    }

    init(client: OpenAIRealtimeClient, audioPlayer: RealtimeAudioPlayer) {
        self.client = client
        self.audioPlayer = audioPlayer
        configureAudioCallbacks()
    }

    deinit {
        eventTask?.cancel()
    }

    func connect() async {
        if isRealtimeUsable {
            return
        }

        startEventListenerIfNeeded()
        state = .connecting
        isFallbackActive = false

        do {
            try await client.connect()
            state = .connected
        } catch {
            enterFallback("Realtime connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        audioPlayer.stop()
        audioPlayer.reset()
        client.disconnect()
        isFallbackActive = false
        lastTranscript = ""
        hasActiveResponse = false
        state = .disconnected
    }

    func narrate(snapshot: DriveContextSnapshot) async {
        let context = GuideContextPayload(snapshot: snapshot, preferences: guidePreferences)
        lastContextSummary = context.auditSummary

        guard !context.topFacts.isEmpty else {
            lastTranscript = ""
            if state == .speaking {
                state = .connected
            }
            return
        }

        await connect()

        guard isRealtimeUsable else {
            return
        }

        guard !hasActiveResponse else {
            return
        }

        do {
            lastTranscript = ""
            try await client.sendConversationText(narrationContextMessage(context))
            state = .speaking
            hasActiveResponse = true
            try await client.createResponse()
        } catch {
            fail("Realtime narration failed: \(error.localizedDescription)")
        }
    }

    func cancelCurrentResponse() {
        Task { [weak self] in
            guard let self else { return }
            await interruptActiveResponseIfNeeded()
        }
    }

    func sendUserQuestion(_ text: String, snapshot: DriveContextSnapshot) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastUserUtterance = trimmed

        if guidePreferences.infer(from: trimmed) {
            onPreferencesChanged?(guidePreferences)
        }

        let context = GuideContextPayload(snapshot: snapshot, preferences: guidePreferences)
        lastContextSummary = context.auditSummary

        await connect()

        guard isRealtimeUsable else {
            return
        }

        do {
            await interruptActiveResponseIfNeeded()
            lastTranscript = ""
            ignoresInputTranscriptionUntilSpeechStart = true
            try await client.sendConversationText(questionContextMessage(question: trimmed, context: context))
            state = .speaking
            hasActiveResponse = true
            try await client.createResponse()
        } catch {
            fail("Realtime question failed: \(error.localizedDescription)")
        }
    }

    func updateRouteContext(snapshot: DriveContextSnapshot) async {
        let context = GuideContextPayload(snapshot: snapshot, preferences: guidePreferences)
        lastContextSummary = context.auditSummary

        await connect()

        guard isRealtimeUsable else {
            return
        }

        do {
            try await client.updateSessionInstructions(liveConversationInstructions(context: context))
        } catch {
            fail("Realtime context update failed: \(error.localizedDescription)")
        }
    }

    func appendMicrophoneAudio(_ pcmData: Data) async {
        guard !pcmData.isEmpty else { return }

        if state == .disconnected || state == .fallback {
            await connect()
        }

        guard isRealtimeUsable else {
            return
        }

        do {
            try await client.appendInputAudio(pcmData)
        } catch {
            fail("Realtime microphone streaming failed: \(error.localizedDescription)")
        }
    }

    func finishMicrophoneTurn() async {
        guard isRealtimeUsable else { return }
        guard !hasActiveResponse else { return }

        do {
            try await client.commitInputAudio()
            lastTranscript = ""
            lastContextSummary = "Push-to-talk captured; waiting for AI Guide answer"
            state = .speaking
            hasActiveResponse = true
            try await client.createResponse()
        } catch {
            lastContextSummary = "Push-to-talk released; waiting for AI Guide answer"
        }
    }

    func clearMicrophoneAudio() async {
        guard isRealtimeUsable else { return }
        try? await client.clearInputAudio()
    }

    private var isRealtimeUsable: Bool {
        switch state {
        case .connected, .speaking:
            return !isFallbackActive
        default:
            return false
        }
    }

    private func startEventListenerIfNeeded() {
        guard eventTask == nil else { return }

        eventTask = Task { [weak self] in
            guard let self else { return }

            for await event in client.events {
                handle(event)
            }
        }
    }

    private func configureAudioCallbacks() {
        audioPlayer.onSpeakingChanged = { [weak self] isSpeaking in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if isSpeaking {
                    state = .speaking
                } else if state == .speaking {
                    state = .connected
                }
            }
        }

        audioPlayer.onPlaybackCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, state == .speaking else { return }
                state = .connected
            }
        }
    }

    private func handle(_ event: OpenAIRealtimeEvent) {
        switch event {
        case .sessionCreated, .sessionUpdated:
            isFallbackActive = false
            if state == .connecting {
                state = .connected
            }

        case .responseCreated:
            hasActiveResponse = true

        case .audioDelta(let delta, _):
            audioPlayer.appendBase64AudioDelta(delta.base64Audio)
            state = .speaking

        case .audioDone:
            finishBufferedAudio()

        case .transcriptDelta(let delta, let raw):
            if isInputTranscription(raw: raw) {
                if !ignoresInputTranscriptionUntilSpeechStart {
                    lastUserUtterance += delta.text
                }
            } else {
                lastTranscript += delta.text
            }

        case .transcriptDone(let transcript, let raw):
            let text = transcript.text ?? ""
            if isInputTranscription(raw: raw) {
                if !ignoresInputTranscriptionUntilSpeechStart {
                    lastUserUtterance = text
                }
            } else if !text.isEmpty {
                lastTranscript = text
            }

        case .responseDone(_, let status, _):
            hasActiveResponse = false
            if status == "failed" || status == "incomplete" {
                fail("Realtime response ended with status: \(status ?? "unknown")")
            } else {
                finishBufferedAudio()
            }

        case .error(let serverError, _):
            if isBenignCancellationError(serverError) {
                hasActiveResponse = false
                if state == .speaking {
                    state = .connected
                }
                lastContextSummary = "No active AI response to cancel"
                return
            }

            fail("Realtime error: \(serverError.message)")

        case .inputAudioSpeechStarted:
            audioPlayer.stop()
            hasActiveResponse = false
            ignoresInputTranscriptionUntilSpeechStart = false
            lastContextSummary = "Driver voice detected; interrupting current response"
            if state == .speaking {
                state = .connected
            }

        case .inputAudioSpeechStopped:
            lastContextSummary = "Driver voice captured; waiting for AI Guide answer"

        case .inputAudioCommitted:
            break

        case .functionCallCompleted, .unknown:
            break
        }
    }

    private func interruptActiveResponseIfNeeded() async {
        let shouldCancelResponse = hasActiveResponse || state == .speaking
        audioPlayer.stop()

        guard shouldCancelResponse else { return }

        hasActiveResponse = false
        if state == .speaking {
            state = .connected
        }

        try? await client.cancelResponse()
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func enterFallback(_ reason: String) {
        audioPlayer.stop()
        hasActiveResponse = false
        isFallbackActive = true
        lastContextSummary = reason
        state = .fallback
    }

    private func fail(_ reason: String) {
        audioPlayer.stop()
        hasActiveResponse = false
        isFallbackActive = true
        lastContextSummary = reason
        state = .failed
    }

    private func finishBufferedAudio() {
        Task { [weak self] in
            guard let self else { return }
            await audioPlayer.finishAndPlay()

            if state == .speaking && !audioPlayer.isSpeaking {
                state = .connected
            }
        }
    }

    private func isInputTranscription(raw: OpenAIRealtimeEvent.JSONObject) -> Bool {
        let type = raw["type"] as? String
        return type?.contains("input_audio_transcription") == true
    }

    private func isBenignCancellationError(_ error: OpenAIRealtimeServerError) -> Bool {
        let message = error.message.lowercased()
        return message.contains("cancellation failed")
            && message.contains("no active response")
    }

    private func baseSessionInstructions(context: GuideContextPayload) -> String {
        """
        You are Cruisin AI Guide Mode for a prerecorded Honolulu demo drive.
        Speak concise, friendly route narration for OpenAI Voice Hack Night.
        Use only the local facts provided in each message. Do not invent attractions, directions, GPS claims, traffic, safety advice, prices, hours, or live conditions.
        Prefer the driver's saved categories when useful: \(context.preferences.auditSummary).
        If quiet mode is true, speak only when there is a strong nearby fact and keep the answer especially short.
        """
    }

    private func narrationContextMessage(_ context: GuideContextPayload) -> String {
        """
        \(baseSessionInstructions(context: context))

        Current route context:
        \(context.compactJSONString)

        Narrate the best local fact now. Use only facts from topFacts.
        \(narrationResponseInstructions(context: context))
        """
    }

    private func narrationResponseInstructions(context: GuideContextPayload) -> String {
        let length = context.quietMode ? "one short spoken sentence" : "one or two short spoken sentences"
        return """
        Speak \(length), under about 15 seconds total. Mention why it matters from the current route position. Do not read JSON keys aloud.
        """
    }

    private func questionContextMessage(question: String, context: GuideContextPayload) -> String {
        """
        \(baseSessionInstructions(context: context))

        Driver question:
        \(question)

        Current route context:
        \(context.compactJSONString)

        Answer the question using only topFacts when possible. If the local facts do not answer it, say so briefly and pivot to the most relevant nearby fact.
        \(questionResponseInstructions(context: context))
        """
    }

    private func questionResponseInstructions(context: GuideContextPayload) -> String {
        let sentenceLimit = context.quietMode ? "one sentence" : "one or two sentences"
        return """
        Reply in \(sentenceLimit), conversationally, under about 15 seconds. Stay grounded in the supplied local facts.
        """
    }

    private func liveConversationInstructions(context: GuideContextPayload) -> String {
        """
        \(baseSessionInstructions(context: context))

        The driver's microphone is live. If the driver speaks, treat it as an interruption or question about the current drive.

        Current route context:
        \(context.compactJSONString)

        Answer driver questions using only topFacts when possible. If the local facts do not answer the question, say so briefly and pivot to the most relevant nearby fact. After answering, allow the app to continue normal sparse route narration from the updated route position.
        \(questionResponseInstructions(context: context))
        """
    }
}

struct GuideContextPayload: Encodable {
    let routeLabel: String
    let coordinate: GuideCoordinate?
    let progress: Double?
    let topFacts: [GuideFact]
    let lastSpokenFact: LastSpokenFact?
    let decisionReason: String
    let preferences: RealtimeGuidePreferences
    let quietMode: Bool

    init(snapshot: DriveContextSnapshot, preferences: RealtimeGuidePreferences) {
        let reader = SnapshotReader(snapshot)
        self.routeLabel = reader.string(for: [
            "routeLabel",
            "currentRouteLabel",
            "currentLabel",
            "label",
            "areaLabel"
        ]) ?? "Honolulu route"
        self.coordinate = reader.coordinate()
        self.progress = reader.double(for: ["progress", "routeProgress", "progressFraction"]).map { value in
            min(max(value, 0), 1)
        }
        let snapshotQuietMode = reader.bool(for: ["quietMode", "isQuietMode", "quiet"]) ?? false
        let mergedPreferences = preferences.merged(
            snapshotPreferredCategories: reader.stringArray(for: ["preferredCategories", "guidePreferences"]),
            snapshotExcludedCategories: reader.stringArray(for: ["excludedCategories", "categoryExclusions"]),
            snapshotQuietMode: snapshotQuietMode
        )
        self.preferences = mergedPreferences
        self.quietMode = mergedPreferences.quietMode
        self.decisionReason = reader.string(for: [
            "decisionReason",
            "lastDecisionReason",
            "selectionReason",
            "reason"
        ]) ?? "No current decision reason provided"
        self.lastSpokenFact = reader.lastSpokenFact()
        self.topFacts = StagedRealtimeContext(snapshot: snapshot, preferences: mergedPreferences).topFacts.map(GuideFact.init(context:))
    }

    var compactJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return json
    }

    var auditSummary: String {
        let progressText = progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown progress"
        let factText = topFacts.first.map { "\($0.name) (\($0.category))" } ?? "no nearby facts"
        return "Route: \(routeLabel) (\(progressText)) | Top fact: \(factText) | Preference: \(preferences.auditSummary)"
    }
}

struct GuideCoordinate: Encodable {
    let latitude: Double
    let longitude: Double
}

struct GuideFact: Encodable {
    let id: String
    let name: String
    let category: String
    let subcategory: String?
    let tags: [String]
    let distanceMeters: Int?
    let rankScore: Double?
    let reason: String?
    let auditReasons: [String]
    let narration: String
    let sourceConfidence: Double?
    let sourceURLs: [String]
}

struct LastSpokenFact: Encodable {
    let id: String?
    let name: String?
    let text: String?
}

private struct SnapshotReader {
    private let values: [String: Any]

    init(_ snapshot: DriveContextSnapshot) {
        self.values = SnapshotReader.children(of: snapshot)
    }

    func string(for keys: [String]) -> String? {
        for key in keys {
            if let value = values[key] as? String, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    func double(for keys: [String]) -> Double? {
        for key in keys {
            guard let value = values[key] else { continue }

            if let double = value as? Double {
                return double
            }

            if let float = value as? Float {
                return Double(float)
            }

            if let int = value as? Int {
                return Double(int)
            }
        }

        return nil
    }

    func bool(for keys: [String]) -> Bool? {
        for key in keys {
            if let bool = values[key] as? Bool {
                return bool
            }
        }

        return nil
    }

    func stringArray(for keys: [String]) -> [String] {
        for key in keys {
            guard let value = values[key] else { continue }

            if let strings = value as? [String] {
                return strings.map { $0.lowercased() }
            }

            if let string = value as? String {
                return string
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            }

            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .collection {
                let strings = mirror.children.compactMap { child in
                    (child.value as? String)?.lowercased()
                }

                if !strings.isEmpty {
                    return strings
                }
            }
        }

        return []
    }

    func coordinate() -> GuideCoordinate? {
        if let coordinateValue = firstValue(for: ["coordinate", "coordinates", "currentCoordinate", "location"]) {
            let coordinateValues = SnapshotReader.children(of: coordinateValue)

            if let latitude = SnapshotReader.double(named: "latitude", in: coordinateValues),
               let longitude = SnapshotReader.double(named: "longitude", in: coordinateValues) {
                return GuideCoordinate(latitude: latitude, longitude: longitude)
            }
        }

        if let latitude = double(for: ["latitude", "currentLatitude"]),
           let longitude = double(for: ["longitude", "currentLongitude"]) {
            return GuideCoordinate(latitude: latitude, longitude: longitude)
        }

        return nil
    }

    func topFacts(preferences: RealtimeGuidePreferences) -> [GuideFact] {
        let candidates = collectionValues(for: [
            "topNearbyFacts",
            "nearbyCandidates",
            "nearbyFacts",
            "candidates",
            "facts"
        ])

        return candidates
            .compactMap { SnapshotReader.guideFact(from: $0) }
            .filter { !preferences.excludedCategories.contains($0.category.lowercased()) }
            .sorted { lhs, rhs in
                let lhsPreferred = preferences.preferredCategories.contains(lhs.category.lowercased())
                let rhsPreferred = preferences.preferredCategories.contains(rhs.category.lowercased())

                if lhsPreferred != rhsPreferred {
                    return lhsPreferred
                }

                return (lhs.rankScore ?? 0) > (rhs.rankScore ?? 0)
            }
            .prefix(4)
            .map { $0 }
    }

    func lastSpokenFact() -> LastSpokenFact? {
        if let event = firstValue(for: ["lastSpokenFact", "lastSpokenEvent", "lastNarrationEvent"]) {
            let eventValues = SnapshotReader.children(of: event)

            return LastSpokenFact(
                id: SnapshotReader.string(named: "factID", in: eventValues)
                    ?? SnapshotReader.string(named: "factId", in: eventValues)
                    ?? SnapshotReader.string(named: "id", in: eventValues),
                name: SnapshotReader.string(named: "title", in: eventValues)
                    ?? SnapshotReader.string(named: "name", in: eventValues),
                text: SnapshotReader.string(named: "text", in: eventValues)
                    ?? SnapshotReader.string(named: "narration", in: eventValues)
            )
        }

        if let id = string(for: ["lastSpokenFactID", "lastSpokenFactId"]) {
            return LastSpokenFact(id: id, name: nil, text: nil)
        }

        return nil
    }

    private func firstValue(for keys: [String]) -> Any? {
        for key in keys {
            if let value = values[key] {
                return value
            }
        }

        return nil
    }

    private func collectionValues(for keys: [String]) -> [Any] {
        for key in keys {
            guard let value = values[key] else { continue }
            let mirror = Mirror(reflecting: value)

            if mirror.displayStyle == .collection {
                return mirror.children.map(\.value)
            }
        }

        return []
    }

    private static func guideFact(from value: Any) -> GuideFact? {
        if let candidate = value as? NearbyCandidate {
            return GuideFact(
                id: candidate.fact.id,
                name: candidate.fact.name,
                category: candidate.fact.category,
                subcategory: candidate.fact.subcategory,
                tags: candidate.fact.tags,
                distanceMeters: Int(candidate.distanceMeters.rounded()),
                rankScore: candidate.rankScore,
                reason: candidate.reason,
                auditReasons: candidate.auditReasons,
                narration: candidate.fact.narration,
                sourceConfidence: candidate.fact.sourceConfidence,
                sourceURLs: candidate.fact.sourceURLs
            )
        }

        if let fact = value as? LocalFact {
            return GuideFact(
                id: fact.id,
                name: fact.name,
                category: fact.category,
                subcategory: fact.subcategory,
                tags: fact.tags,
                distanceMeters: nil,
                rankScore: Double(fact.priority),
                reason: nil,
                auditReasons: ["bundled fact, priority \(fact.priority)"],
                narration: fact.narration,
                sourceConfidence: fact.sourceConfidence,
                sourceURLs: fact.sourceURLs
            )
        }

        let values = children(of: value)
        let factValue = values["fact"]
        let factValues = factValue.map { children(of: $0) } ?? values

        guard let id = string(named: "id", in: factValues),
              let name = string(named: "name", in: factValues),
              let category = string(named: "category", in: factValues),
              let narration = string(named: "narration", in: factValues) else {
            return nil
        }

        return GuideFact(
            id: id,
            name: name,
            category: category,
            subcategory: string(named: "subcategory", in: factValues),
            tags: stringArray(named: "tags", in: factValues),
            distanceMeters: double(named: "distanceMeters", in: values).map { Int($0.rounded()) },
            rankScore: double(named: "rankScore", in: values),
            reason: string(named: "reason", in: values),
            auditReasons: stringArray(named: "auditReasons", in: values),
            narration: narration,
            sourceConfidence: double(named: "sourceConfidence", in: factValues),
            sourceURLs: stringArray(named: "sourceURLs", in: factValues)
        )
    }

    private static func children(of value: Any) -> [String: Any] {
        var result: [String: Any] = [:]
        var mirror: Mirror? = Mirror(reflecting: value)

        while let currentMirror = mirror {
            for child in currentMirror.children {
                guard let label = child.label else { continue }
                result[label] = child.value
            }

            mirror = currentMirror.superclassMirror
        }

        return result
    }

    private static func string(named key: String, in values: [String: Any]) -> String? {
        values[key] as? String
    }

    private static func double(named key: String, in values: [String: Any]) -> Double? {
        guard let value = values[key] else { return nil }

        if let double = value as? Double {
            return double
        }

        if let float = value as? Float {
            return Double(float)
        }

        if let int = value as? Int {
            return Double(int)
        }

        return nil
    }

    private static func stringArray(named key: String, in values: [String: Any]) -> [String] {
        guard let value = values[key] else { return [] }

        if let strings = value as? [String] {
            return strings
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .collection {
            return mirror.children.compactMap { $0.value as? String }
        }

        return []
    }
}

private extension GuideFact {
    init(context: FactContext) {
        self.init(
            id: context.id,
            name: context.name,
            category: context.category,
            subcategory: context.subcategory,
            tags: context.tags,
            distanceMeters: Int(context.distanceMeters.rounded()),
            rankScore: context.rankScore,
            reason: context.reason,
            auditReasons: context.auditReasons,
            narration: context.narration,
            sourceConfidence: context.sourceConfidence,
            sourceURLs: context.sourceURLs
        )
    }
}
