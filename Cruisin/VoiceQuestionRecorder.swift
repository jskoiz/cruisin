import AVFoundation
import Foundation

final class VoiceQuestionRecorder: @unchecked Sendable {
    var onAudioData: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "cruisin.voice-question-recorder.audio")
    private var audioConverter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var isTapInstalled = false
    private var isRecording = false
    private var nextCaptureID: UInt64 = 0
    private var activeCaptureID: UInt64 = 0
    private var suppressAudioUntil = Date.distantPast

    private static let startupSuppressionDuration: TimeInterval = 0.7

    var transcript: String {
        ""
    }

    func start() async throws {
        guard await requestMicrophonePermission() else {
            throw VoiceQuestionRecorderError.microphonePermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: VoiceQuestionRecorderError.audioInputUnavailable)
                    return
                }

                do {
                    try self.startOnAudioQueue()
                    continuation.resume()
                } catch {
                    self.stopOnAudioQueue(deactivateSession: true)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func finish() -> String {
        stop()
        return ""
    }

    func cancel() {
        stop()
    }

    private func startOnAudioQueue() throws {
        stopOnAudioQueue(deactivateSession: false)

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)
        try? audioEngine.outputNode.setVoiceProcessingEnabled(true)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw VoiceQuestionRecorderError.audioInputUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw VoiceQuestionRecorderError.audioInputUnavailable
        }

        guard let audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceQuestionRecorderError.audioInputUnavailable
        }

        self.audioConverter = audioConverter
        self.outputFormat = outputFormat

        nextCaptureID &+= 1
        let captureID = nextCaptureID
        activeCaptureID = captureID
        isRecording = true
        suppressAudioUntil = Date().addingTimeInterval(Self.startupSuppressionDuration)

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, captureID: captureID)
        }
        isTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stop() {
        audioQueue.async { [weak self] in
            self?.stopOnAudioQueue(deactivateSession: true)
        }
    }

    private func stopOnAudioQueue(deactivateSession: Bool) {
        isRecording = false
        activeCaptureID = 0
        suppressAudioUntil = .distantPast

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        audioConverter?.reset()
        audioConverter = nil
        outputFormat = nil

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func convertAndEmit(_ inputBuffer: AVAudioPCMBuffer, captureID: UInt64) {
        audioQueue.async { [weak self, inputBuffer] in
            guard let self,
                  isRecording,
                  activeCaptureID == captureID,
                  Date() >= suppressAudioUntil,
                  let audioConverter,
                  let outputFormat else { return }

            let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
            let frameCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 16
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

            var conversionError: NSError?
            var didProvideInput = false
            let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                onError?(conversionError.localizedDescription)
                return
            }

            guard status != .error, outputBuffer.frameLength > 0 else { return }
            guard let channelData = outputBuffer.int16ChannelData else { return }

            let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            let audioData = Data(bytes: channelData[0], count: byteCount)
            onAudioData?(audioData)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

private enum VoiceQuestionRecorderError: LocalizedError {
    case microphonePermissionDenied
    case audioInputUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for AI Guide push-to-talk."
        case .audioInputUnavailable:
            return "No microphone input was available."
        }
    }
}
