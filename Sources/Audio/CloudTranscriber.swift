import AVFoundation
import Foundation

/// A WebSocket connection, so tests can play the server.
protocol WebSocketConnection: AnyObject {
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void)
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func close()
}

/// Optional cloud streaming STT via Deepgram. Sends 16 kHz mono linear16 PCM
/// over a WebSocket and emits interim and final segments. Unlike the on-device
/// backends, audio leaves the machine, so this is opt-in.
///
/// Deepgram closes a stream that goes about 10 s without data, so a KeepAlive
/// goes out whenever no audio has been sent for a few seconds. A dropped
/// connection is re-established with backoff; audio is dropped while
/// disconnected, and the problem is reported once if reconnecting keeps failing.
final class CloudTranscriber: LiveTranscriber {
    static let keepAliveInterval: TimeInterval = 4
    static let failuresBeforeReporting = 3
    private static let maximumBackoff: TimeInterval = 15
    private static let keepAliveMessage = #"{"type":"KeepAlive"}"#
    private static let closeMessage = #"{"type":"CloseStream"}"#

    let backendName = "Deepgram"
    var onSegment: (@MainActor (TranscriptSegment) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (String?) -> Void)?

    private let apiKey: String
    private let localeIdentifier: String
    private let connect: (URLRequest) -> WebSocketConnection
    private let queue: DispatchQueue
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!

    // Only touched on `queue`.
    private var running = false
    private var connection: WebSocketConnection?
    private var generation = 0
    private var heardFromServer = false
    private var reconnecting = false
    private var failures = 0
    private var lastSent = Date.distantPast
    private var utterance = 0
    private var converter: AVAudioConverter?

    init(apiKey: String,
         localeIdentifier: String = "en-US",
         connect: @escaping (URLRequest) -> WebSocketConnection = URLSessionWebSocketConnection.connect,
         queue: DispatchQueue = DispatchQueue(label: "meetingassistant.deepgram"),
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = runAfter) {
        self.apiKey = apiKey
        self.localeIdentifier = localeIdentifier
        self.connect = connect
        self.queue = queue
        self.now = now
        self.schedule = schedule
    }

    /// Cloud service, no OS permission needed.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) { completion(true) }

    func start() {
        queue.async { [self] in
            guard !apiKey.isEmpty else {
                report("Missing Deepgram API key.")
                return
            }
            running = true
            failures = 0
            openConnection()
            scheduleKeepAlive()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            connection?.send(.string(Self.closeMessage)) { _ in }
            connection?.close()
            connection = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let time = now()
        queue.async { [self] in
            guard running, let connection, let data = pcm16Data(from: buffer), !data.isEmpty else { return }
            connection.send(.data(data)) { _ in }
            lastSent = time
        }
    }

    // MARK: - Connection (on `queue`)

    private func openConnection() {
        generation += 1
        heardFromServer = false
        lastSent = now()
        let connection = connect(makeRequest())
        self.connection = connection
        receiveNext(on: connection, generation: generation)
    }

    private func receiveNext(on connection: WebSocketConnection, generation id: Int) {
        connection.receive { [weak self] result in
            self?.queue.async { self?.received(result, on: connection, generation: id) }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>,
                          on connection: WebSocketConnection, generation id: Int) {
        guard running, id == generation else { return }
        switch result {
        case .success(let message):
            if !heardFromServer {
                heardFromServer = true
                failures = 0
                if reconnecting {
                    reconnecting = false
                    notify(nil)
                }
            }
            handle(message)
            receiveNext(on: connection, generation: id)
        case .failure(let error):
            dropped(error)
        }
    }

    private func dropped(_ error: Error) {
        connection?.close()
        connection = nil
        failures += 1
        if !reconnecting {
            reconnecting = true
            notify("Reconnecting to Deepgram…")
        }
        if failures == Self.failuresBeforeReporting {
            report("Deepgram keeps disconnecting: \(error.localizedDescription)")
        }
        let delay = min(Self.maximumBackoff, pow(2, Double(failures - 1)))
        let droppedGeneration = generation
        schedule(delay) { [weak self] in
            self?.queue.async { self?.reconnect(after: droppedGeneration) }
        }
    }

    private func reconnect(after droppedGeneration: Int) {
        guard running, connection == nil, generation == droppedGeneration else { return }
        openConnection()
    }

    private func scheduleKeepAlive() {
        schedule(Self.keepAliveInterval) { [weak self] in
            self?.queue.async { self?.keepAlive() }
        }
    }

    private func keepAlive() {
        guard running else { return }
        if let connection, now().timeIntervalSince(lastSent) >= Self.keepAliveInterval {
            connection.send(.string(Self.keepAliveMessage)) { _ in }
            lastSent = now()
        }
        scheduleKeepAlive()
    }

    private func makeRequest() -> URLRequest {
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
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Results

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
        guard !transcript.isEmpty || isFinal else { return }
        let segment = TranscriptSegment(utterance: utterance, text: transcript, isFinal: isFinal)
        if isFinal { utterance += 1 }
        let onSegment = self.onSegment
        deliverOnMain { onSegment?(segment) }
    }

    private func report(_ message: String) {
        let onError = self.onError
        deliverOnMain { onError?(message) }
    }

    private func notify(_ message: String?) {
        let onNotice = self.onNotice
        deliverOnMain { onNotice?(message) }
    }

    // MARK: - Audio conversion

    /// Converts a capture buffer to 16 kHz mono Int16 and returns the raw little-endian bytes.
    private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channelData = output.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// URLSessionWebSocketTask behind WebSocketConnection. Connections share
/// URLSession.shared, so none is left behind un-invalidated.
final class URLSessionWebSocketConnection: WebSocketConnection {
    private let task: URLSessionWebSocketTask

    private init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    static func connect(_ request: URLRequest) -> WebSocketConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        task.send(message, completionHandler: completion)
    }

    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completion)
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
