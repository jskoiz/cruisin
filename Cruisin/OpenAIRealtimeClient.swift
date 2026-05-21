import Foundation

enum OpenAIRealtimeClientError: LocalizedError {
    case missingAPIKey
    case invalidRealtimeURL
    case notConnected
    case invalidJSONObject
    case invalidJSONString

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set in the process environment."
        case .invalidRealtimeURL:
            return "Could not build the OpenAI Realtime WebSocket URL."
        case .notConnected:
            return "OpenAI Realtime WebSocket is not connected."
        case .invalidJSONObject:
            return "Realtime event payload was not a valid JSON object."
        case .invalidJSONString:
            return "Realtime event payload could not be encoded as a UTF-8 JSON string."
        }
    }
}

struct OpenAIRealtimeAudioDelta {
    let base64Audio: String
    let responseID: String?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
}

struct OpenAIRealtimeTranscriptDelta {
    let text: String
    let responseID: String?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
}

struct OpenAIRealtimeTranscriptDone {
    let text: String?
    let responseID: String?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
}

struct OpenAIRealtimeFunctionCall {
    let callID: String
    let name: String?
    let argumentsJSON: String
    let responseID: String?
    let itemID: String?
}

struct OpenAIRealtimeSpeechStarted {
    let itemID: String?
    let audioStartMilliseconds: Double?
}

struct OpenAIRealtimeSpeechStopped {
    let itemID: String?
    let audioEndMilliseconds: Double?
}

struct OpenAIRealtimeServerError {
    let message: String
    let code: String?
    let eventID: String?
}

enum OpenAIRealtimeEvent {
    typealias JSONObject = [String: Any]

    case sessionCreated(session: JSONObject, raw: JSONObject)
    case sessionUpdated(session: JSONObject, raw: JSONObject)
    case audioDelta(OpenAIRealtimeAudioDelta, raw: JSONObject)
    case audioDone(responseID: String?, itemID: String?, raw: JSONObject)
    case transcriptDelta(OpenAIRealtimeTranscriptDelta, raw: JSONObject)
    case transcriptDone(OpenAIRealtimeTranscriptDone, raw: JSONObject)
    case responseCreated(responseID: String?, raw: JSONObject)
    case responseDone(responseID: String?, status: String?, raw: JSONObject)
    case functionCallCompleted(OpenAIRealtimeFunctionCall, raw: JSONObject)
    case inputAudioSpeechStarted(OpenAIRealtimeSpeechStarted, raw: JSONObject)
    case inputAudioSpeechStopped(OpenAIRealtimeSpeechStopped, raw: JSONObject)
    case inputAudioCommitted(itemID: String?, raw: JSONObject)
    case error(OpenAIRealtimeServerError, raw: JSONObject)
    case unknown(type: String, raw: JSONObject)
}

final class OpenAIRealtimeClient {
    typealias JSONObject = [String: Any]

    static let defaultModel = "gpt-realtime"

    let model: String
    let events: AsyncStream<OpenAIRealtimeEvent>
    var onEvent: ((OpenAIRealtimeEvent) -> Void)?

    private let voice: String
    private let urlSession: URLSession
    private let eventContinuation: AsyncStream<OpenAIRealtimeEvent>.Continuation
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(
        model: String = OpenAIRealtimeClient.defaultModel,
        voice: String = "marin",
        urlSession: URLSession = .shared
    ) {
        self.model = model
        self.voice = voice
        self.urlSession = urlSession

        var continuation: AsyncStream<OpenAIRealtimeEvent>.Continuation!
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        eventContinuation.finish()
    }

    func connect() async throws {
        guard webSocketTask == nil else { return }

        guard let apiKey = Self.apiKeyFromEnvironment() else {
            throw OpenAIRealtimeClientError.missingAPIKey
        }

        guard let url = Self.realtimeURL(model: model) else {
            throw OpenAIRealtimeClientError.invalidRealtimeURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveEvents()
        }

        try await sendSessionUpdate()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func sendConversationText(_ text: String) async throws {
        let payload: JSONObject = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]

        try await send(payload)
    }

    func appendInputAudio(_ pcmAudioData: Data) async throws {
        guard !pcmAudioData.isEmpty else { return }

        let payload: JSONObject = [
            "type": "input_audio_buffer.append",
            "audio": pcmAudioData.base64EncodedString()
        ]

        try await send(payload)
    }

    func clearInputAudio() async throws {
        let payload: JSONObject = [
            "type": "input_audio_buffer.clear"
        ]

        try await send(payload)
    }

    func commitInputAudio() async throws {
        let payload: JSONObject = [
            "type": "input_audio_buffer.commit"
        ]

        try await send(payload)
    }

    func updateSessionInstructions(_ instructions: String) async throws {
        try await sendSessionUpdate(instructions: instructions)
    }

    func createResponse() async throws {
        let payload: JSONObject = [
            "type": "response.create"
        ]

        try await send(payload)
    }

    func cancelResponse() async throws {
        let payload: JSONObject = [
            "type": "response.cancel"
        ]

        try await send(payload)
    }

    func sendFunctionOutput(callID: String, outputJSON: String) async throws {
        let payload: JSONObject = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": outputJSON
            ]
        ]

        try await send(payload)
    }

    private func sendSessionUpdate(instructions: String = OpenAIRealtimeClient.instructions) async throws {
        let payload: JSONObject = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe",
                            "language": "en"
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.875,
                            "prefix_padding_ms": 220,
                            "silence_duration_ms": 750,
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "voice": voice
                    ]
                ],
                "instructions": instructions
            ]
        ]

        try await send(payload)
    }

    private func send(_ payload: JSONObject) async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeClientError.notConnected
        }

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw OpenAIRealtimeClientError.invalidJSONObject
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeClientError.invalidJSONString
        }

        try await webSocketTask.send(.string(jsonString))
    }

    private func receiveEvents() async {
        while !Task.isCancelled {
            guard let webSocketTask else { return }

            do {
                let message = try await webSocketTask.receive()
                handle(message)
            } catch {
                if !Task.isCancelled {
                    publish(
                        .error(
                            OpenAIRealtimeServerError(
                                message: error.localizedDescription,
                                code: nil,
                                eventID: nil
                            ),
                            raw: [:]
                        )
                    )
                }
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            handleEventString(string)
        case .data(let data):
            guard let string = String(data: data, encoding: .utf8) else {
                publish(
                    .error(
                        OpenAIRealtimeServerError(
                            message: "Received a binary Realtime event that was not UTF-8 JSON.",
                            code: "invalid_message",
                            eventID: nil
                        ),
                        raw: [:]
                    )
                )
                return
            }
            handleEventString(string)
        @unknown default:
            publish(
                .error(
                    OpenAIRealtimeServerError(
                        message: "Received an unknown WebSocket message type.",
                        code: "unknown_message",
                        eventID: nil
                    ),
                    raw: [:]
                )
            )
        }
    }

    private func handleEventString(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            publish(
                .error(
                    OpenAIRealtimeServerError(
                        message: "Realtime event string was not UTF-8.",
                        code: "invalid_json",
                        eventID: nil
                    ),
                    raw: [:]
                )
            )
            return
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            guard let raw = json as? JSONObject else {
                publish(
                    .error(
                        OpenAIRealtimeServerError(
                            message: "Realtime event was not a JSON object.",
                            code: "invalid_json",
                            eventID: nil
                        ),
                        raw: [:]
                    )
                )
                return
            }

            publish(Self.event(from: raw))
        } catch {
            publish(
                .error(
                    OpenAIRealtimeServerError(
                        message: "Could not decode Realtime JSON event.",
                        code: "invalid_json",
                        eventID: nil
                    ),
                    raw: [:]
                )
            )
        }
    }

    private func publish(_ event: OpenAIRealtimeEvent) {
        eventContinuation.yield(event)
        onEvent?(event)
    }

    private static func event(from raw: JSONObject) -> OpenAIRealtimeEvent {
        let type = raw.stringValue(for: "type") ?? "unknown"

        switch type {
        case "session.created":
            return .sessionCreated(session: raw.dictionaryValue(for: "session") ?? [:], raw: raw)
        case "session.updated":
            return .sessionUpdated(session: raw.dictionaryValue(for: "session") ?? [:], raw: raw)
        case "response.output_audio.delta", "response.audio.delta":
            return .audioDelta(
                OpenAIRealtimeAudioDelta(
                    base64Audio: raw.stringValue(for: "delta") ?? "",
                    responseID: raw.stringValue(for: "response_id"),
                    itemID: raw.stringValue(for: "item_id"),
                    outputIndex: raw.intValue(for: "output_index"),
                    contentIndex: raw.intValue(for: "content_index")
                ),
                raw: raw
            )
        case "response.output_audio.done", "response.audio.done":
            return .audioDone(
                responseID: raw.stringValue(for: "response_id"),
                itemID: raw.stringValue(for: "item_id"),
                raw: raw
            )
        case "response.created":
            let response = raw.dictionaryValue(for: "response")
            return .responseCreated(
                responseID: response?.stringValue(for: "id") ?? raw.stringValue(for: "response_id"),
                raw: raw
            )
        case "response.output_audio_transcript.delta",
             "response.audio_transcript.delta",
             "conversation.item.input_audio_transcription.delta":
            return .transcriptDelta(
                OpenAIRealtimeTranscriptDelta(
                    text: raw.stringValue(for: "delta") ?? "",
                    responseID: raw.stringValue(for: "response_id"),
                    itemID: raw.stringValue(for: "item_id"),
                    outputIndex: raw.intValue(for: "output_index"),
                    contentIndex: raw.intValue(for: "content_index")
                ),
                raw: raw
            )
        case "response.output_audio_transcript.done",
             "response.audio_transcript.done",
             "conversation.item.input_audio_transcription.completed":
            return .transcriptDone(
                OpenAIRealtimeTranscriptDone(
                    text: raw.stringValue(for: "transcript"),
                    responseID: raw.stringValue(for: "response_id"),
                    itemID: raw.stringValue(for: "item_id"),
                    outputIndex: raw.intValue(for: "output_index"),
                    contentIndex: raw.intValue(for: "content_index")
                ),
                raw: raw
            )
        case "response.done":
            let response = raw.dictionaryValue(for: "response")
            return .responseDone(
                responseID: response?.stringValue(for: "id") ?? raw.stringValue(for: "response_id"),
                status: response?.stringValue(for: "status") ?? raw.stringValue(for: "status"),
                raw: raw
            )
        case "response.function_call_arguments.done":
            return .functionCallCompleted(
                OpenAIRealtimeFunctionCall(
                    callID: raw.stringValue(for: "call_id") ?? "",
                    name: raw.stringValue(for: "name"),
                    argumentsJSON: raw.stringValue(for: "arguments") ?? "{}",
                    responseID: raw.stringValue(for: "response_id"),
                    itemID: raw.stringValue(for: "item_id")
                ),
                raw: raw
            )
        case "response.output_item.done":
            if let item = raw.dictionaryValue(for: "item"),
               item.stringValue(for: "type") == "function_call" {
                return .functionCallCompleted(
                    OpenAIRealtimeFunctionCall(
                        callID: item.stringValue(for: "call_id") ?? "",
                        name: item.stringValue(for: "name"),
                        argumentsJSON: item.stringValue(for: "arguments") ?? "{}",
                        responseID: raw.stringValue(for: "response_id"),
                        itemID: item.stringValue(for: "id") ?? raw.stringValue(for: "item_id")
                    ),
                    raw: raw
                )
            }
            return .unknown(type: type, raw: raw)
        case "input_audio_buffer.speech_started":
            return .inputAudioSpeechStarted(
                OpenAIRealtimeSpeechStarted(
                    itemID: raw.stringValue(for: "item_id"),
                    audioStartMilliseconds: raw.doubleValue(for: "audio_start_ms")
                ),
                raw: raw
            )
        case "input_audio_buffer.speech_stopped":
            return .inputAudioSpeechStopped(
                OpenAIRealtimeSpeechStopped(
                    itemID: raw.stringValue(for: "item_id"),
                    audioEndMilliseconds: raw.doubleValue(for: "audio_end_ms")
                ),
                raw: raw
            )
        case "input_audio_buffer.committed":
            return .inputAudioCommitted(itemID: raw.stringValue(for: "item_id"), raw: raw)
        case "error":
            let error = raw.dictionaryValue(for: "error")
            return .error(
                OpenAIRealtimeServerError(
                    message: error?.stringValue(for: "message") ?? raw.stringValue(for: "message") ?? "Realtime server returned an error.",
                    code: error?.stringValue(for: "code") ?? raw.stringValue(for: "code"),
                    eventID: error?.stringValue(for: "event_id") ?? raw.stringValue(for: "event_id")
                ),
                raw: raw
            )
        default:
            return .unknown(type: type, raw: raw)
        }
    }

    private static func realtimeURL(model: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [
            URLQueryItem(name: "model", value: model)
        ]
        return components.url
    }

    private static func apiKeyFromEnvironment() -> String? {
        for keyName in ["OPENAI_API_KEY", "OPENAI_REALTIME_API_KEY"] {
            let value = ProcessInfo.processInfo.environment[keyName]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private static let instructions = """
    You are Cruisin AI Guide Mode for a bundled Honolulu route replay. Speak concise, passenger-friendly local narration in one or two short sentences. Use only the provided route context and nearby local facts; do not invent live GPS, traffic, hazards, closures, turn-by-turn directions, or emergency guidance. Keep the driver focused on the road, avoid asking anyone to look at the screen, and say less when context is thin.
    """
}

private extension Dictionary where Key == String, Value == Any {
    func stringValue(for key: String) -> String? {
        self[key] as? String
    }

    func intValue(for key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }

        if let value = self[key] as? Double {
            return Int(value)
        }

        return nil
    }

    func doubleValue(for key: String) -> Double? {
        if let value = self[key] as? Double {
            return value
        }

        if let value = self[key] as? Int {
            return Double(value)
        }

        return nil
    }

    func dictionaryValue(for key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
