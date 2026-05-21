import AVFoundation
import Foundation

@MainActor
final class RealtimeAudioPlayer: NSObject {
    var onSpeakingChanged: ((Bool) -> Void)?
    var onPlaybackCompleted: (() -> Void)?

    private let playbackVolume: Float = 0.65

    private(set) var isSpeaking = false {
        didSet {
            guard oldValue != isSpeaking else { return }
            onSpeakingChanged?(isSpeaking)
        }
    }

    private(set) var lastError: Error?

    private var bufferedPCM = Data()
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var temporaryWAVURL: URL?

    func appendBase64AudioDelta(_ base64Audio: String) {
        let trimmedAudio = base64Audio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAudio.isEmpty else { return }

        guard let audioData = Data(base64Encoded: trimmedAudio, options: [.ignoreUnknownCharacters]) else {
            lastError = RealtimeAudioPlayerError.malformedBase64Delta
            return
        }

        appendPCMData(audioData)
    }

    func appendPCMData(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        bufferedPCM.append(pcmData)
    }

    func finishAndPlay() async {
        let pcmData = bufferedPCM
        bufferedPCM.removeAll(keepingCapacity: true)

        guard let playablePCMData = sanitizedPCMData(from: pcmData) else { return }

        stopCurrentPlayback(resumeContinuation: true)

        do {
            try configureAudioSession()

            let wavURL = try writeTemporaryWAVFile(from: playablePCMData)
            let player = try AVAudioPlayer(contentsOf: wavURL)
            player.delegate = self
            player.volume = playbackVolume
            player.prepareToPlay()

            audioPlayer = player
            temporaryWAVURL = wavURL
            setSpeaking(true)

            await withCheckedContinuation { continuation in
                playbackContinuation = continuation

                guard player.play() else {
                    lastError = RealtimeAudioPlayerError.playbackStartFailed
                    finishPlayback(completedNaturally: false)
                    return
                }
            }
        } catch {
            lastError = error
            finishPlayback(completedNaturally: false)
        }
    }

    func stop() {
        bufferedPCM.removeAll(keepingCapacity: true)
        stopCurrentPlayback(resumeContinuation: true)
    }

    func reset() {
        stop()
        lastError = nil
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
    }

    private func sanitizedPCMData(from pcmData: Data) -> Data? {
        guard !pcmData.isEmpty else { return nil }

        let playableByteCount = pcmData.count - (pcmData.count % RealtimeAudioFormat.bytesPerSample)
        guard playableByteCount > 0 else {
            lastError = RealtimeAudioPlayerError.incompletePCMFrame
            return nil
        }

        if playableByteCount == pcmData.count {
            return pcmData
        }

        lastError = RealtimeAudioPlayerError.incompletePCMFrame
        return pcmData.prefix(playableByteCount)
    }

    private func writeTemporaryWAVFile(from pcmData: Data) throws -> URL {
        let wavData = makeWAVData(from: pcmData)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cruisin-realtime-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try wavData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func makeWAVData(from pcmData: Data) -> Data {
        var wavData = Data()
        let dataByteCount = UInt32(pcmData.count)
        let fileByteCount = UInt32(36) + dataByteCount
        let byteRate = UInt32(RealtimeAudioFormat.sampleRate)
            * UInt32(RealtimeAudioFormat.channelCount)
            * UInt32(RealtimeAudioFormat.bytesPerSample)
        let blockAlign = UInt16(RealtimeAudioFormat.channelCount * RealtimeAudioFormat.bytesPerSample)

        wavData.append(Data("RIFF".utf8))
        wavData.appendLittleEndian(fileByteCount)
        wavData.append(Data("WAVE".utf8))
        wavData.append(Data("fmt ".utf8))
        wavData.appendLittleEndian(UInt32(16))
        wavData.appendLittleEndian(UInt16(1))
        wavData.appendLittleEndian(UInt16(RealtimeAudioFormat.channelCount))
        wavData.appendLittleEndian(UInt32(RealtimeAudioFormat.sampleRate))
        wavData.appendLittleEndian(byteRate)
        wavData.appendLittleEndian(blockAlign)
        wavData.appendLittleEndian(UInt16(RealtimeAudioFormat.bitsPerSample))
        wavData.append(Data("data".utf8))
        wavData.appendLittleEndian(dataByteCount)
        wavData.append(pcmData)

        return wavData
    }

    private func stopCurrentPlayback(resumeContinuation: Bool) {
        audioPlayer?.stop()
        finishPlayback(completedNaturally: false, resumeContinuation: resumeContinuation)
    }

    private func finishPlayback(completedNaturally: Bool, resumeContinuation: Bool = true) {
        audioPlayer = nil
        setSpeaking(false)
        removeTemporaryWAVFile()

        if resumeContinuation {
            playbackContinuation?.resume()
            playbackContinuation = nil
        }

        if completedNaturally {
            onPlaybackCompleted?()
        }
    }

    private func removeTemporaryWAVFile() {
        guard let temporaryWAVURL else { return }
        try? FileManager.default.removeItem(at: temporaryWAVURL)
        self.temporaryWAVURL = nil
    }

    private func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
    }
}

extension RealtimeAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.audioPlayer === player else { return }
            self?.finishPlayback(completedNaturally: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.audioPlayer === player else { return }
            self?.lastError = error ?? RealtimeAudioPlayerError.decodeFailed
            self?.finishPlayback(completedNaturally: false)
        }
    }
}

private enum RealtimeAudioFormat {
    static let sampleRate = 24_000
    static let channelCount = 1
    static let bitsPerSample = 16
    static let bytesPerSample = bitsPerSample / 8
}

private enum RealtimeAudioPlayerError: LocalizedError {
    case malformedBase64Delta
    case incompletePCMFrame
    case playbackStartFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .malformedBase64Delta:
            return "Realtime audio delta was not valid base64."
        case .incompletePCMFrame:
            return "Realtime audio delta ended with an incomplete PCM16 frame."
        case .playbackStartFailed:
            return "Realtime audio playback could not start."
        case .decodeFailed:
            return "Realtime audio playback could not decode the generated WAV file."
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
