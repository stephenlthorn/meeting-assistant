import Foundation
import AVFoundation

/// Optional cloud streaming STT via Deepgram. Sends 16 kHz mono linear16 PCM over
/// a WebSocket and emits interim + final segments. Unlike the on-device backends,
/// audio leaves the machine, so this is opt-in.
final class CloudTranscriber: LiveTranscriber {
    var onSegment: ((_ text: String, _ isFinal: Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let localeIdentifier: String
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var running = false

    init(apiKey: String, localeIdentifier: String = "en-US") {
        self.apiKey = apiKey
        self.localeIdentifier = localeIdentifier
    }

    /// Cloud service, no OS permission needed.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(true) }

    func start() {
        guard !apiKey.isEmpty else { onError?("Missing Deepgram API key."); return }
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "language", value: localeIdentifier),
        ]
        guard let url = components.url else { onError?("Bad Deepgram URL."); return }
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        running = true
        task.resume()
        receive()
    }

    func stop() {
        running = false
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "CloseStream"]),
           let text = String(data: data, encoding: .utf8) {
            task?.send(.string(text)) { _ in }
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard running, let task, let data = pcm16Data(from: buffer), !data.isEmpty else { return }
        task.send(.data(data)) { [weak self] error in
            guard let self, let error, self.running else { return }
            self.onError?("Deepgram send: \(error.localizedDescription)")
        }
    }

    // MARK: - Receive

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if self.running { self.onError?("Deepgram: \(error.localizedDescription)") }
            case .success(let message):
                self.handle(message)
                if self.running { self.receive() }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let value): data = value
        case .string(let value): data = value.data(using: .utf8)
        @unknown default: data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = object["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else { return }
        let isFinal = (object["is_final"] as? Bool) ?? false
        if !transcript.isEmpty || isFinal {
            onSegment?(transcript, isFinal)
        }
    }

    // MARK: - Audio conversion

    /// Convert a capture buffer to 16 kHz mono Int16 and return raw little-endian bytes.
    private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: false) else { return nil }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = 16000.0 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0,
              let channelData = output.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
