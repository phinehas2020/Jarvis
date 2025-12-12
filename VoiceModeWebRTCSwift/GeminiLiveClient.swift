import Foundation
import AVFoundation

protocol GeminiLiveClientDelegate: AnyObject {
    func geminiLiveClient(_ client: GeminiLiveClient, didChangeStatus status: ConnectionStatus)
    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveMessage message: ConversationItem)
    func geminiLiveClient(_ client: GeminiLiveClient, didEncounterError error: Error)
}

final class GeminiLiveClient: NSObject {
    weak var delegate: GeminiLiveClientDelegate?

    private let apiKey: String
    private let model: String
    private let systemPrompt: String
    private let endpointUrlString: String

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected: Bool = false
    private var remainingEndpointCandidates: [String] = []
    private var currentEndpointAttempt: String?

    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?

    private let desiredInputSampleRate: Double = 16000
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?

    private static let defaultEndpointUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService/BidiGenerateContent"

    init(apiKey: String, model: String, systemPrompt: String, endpointUrlString: String = GeminiLiveClient.defaultEndpointUrlString) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.endpointUrlString = endpointUrlString
        super.init()
        setupAudioSession()
    }

    deinit {
        disconnect()
    }

    func connect() {
        teardownConnection(notify: false)

        guard !apiKey.isEmpty else {
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is missing"])
            )
            return
        }

        let trimmedEndpoint = endpointUrlString.trimmingCharacters(in: .whitespacesAndNewlines)
        remainingEndpointCandidates = endpointCandidates(from: trimmedEndpoint)
        guard !remainingEndpointCandidates.isEmpty else {
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini Live WebSocket URL is missing"])
            )
            return
        }

        delegate?.geminiLiveClient(self, didChangeStatus: .connecting)

        connectNextEndpoint()
    }

    private func connectNextEndpoint() {
        teardownConnection(notify: false)

        guard !apiKey.isEmpty else { return }
        guard !remainingEndpointCandidates.isEmpty else {
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No valid Gemini Live endpoints to try"])
            )
            return
        }

        let endpoint = remainingEndpointCandidates.removeFirst()
        currentEndpointAttempt = endpoint

        print("🔌 Gemini Live WS connecting: \(endpoint)")

        guard let url = URL(string: endpoint) else {
            connectNextEndpoint()
            return
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
    }

    func disconnect() {
        teardownConnection(notify: true)
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard isConnected else { return }

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": trimmed]
                        ]
                    ]
                ],
                "turnComplete": true
            ]
        ]

        sendJSON(message)
    }

    private func sendSetup() {
        guard isConnected else { return }

        let message: [String: Any] = [
            "setup": [
                "model": model,
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": systemPrompt]
                    ]
                ]
            ]
        ]

        sendJSON(message)
    }

    private func sendAudioChunk(_ pcm16Data: Data, sampleRate: Int) {
        guard isConnected else { return }

        let base64 = pcm16Data.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=\(sampleRate)",
                        "data": base64
                    ]
                ]
            ]
        ]

        sendJSON(message)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let webSocketTask else { return }
        guard JSONSerialization.isValidJSONObject(object) else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: object),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocketTask.send(.string(jsonString)) { [weak self] error in
            guard let self else { return }
            if let nsError = error as NSError? {
                if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                    self.teardownConnection(notify: true)
                    return
                }
                self.delegate?.geminiLiveClient(self, didEncounterError: nsError)
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }

                if self.isConnected {
                    self.receiveMessage()
                }

            case .failure(let error):
                self.delegate?.geminiLiveClient(self, didEncounterError: error)
                self.disconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Gemini Live error"
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            )
            return
        }

        guard let serverContent = json["serverContent"] as? [String: Any] else {
            return
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    let item = ConversationItem(id: UUID().uuidString, role: "assistant", text: text)
                    delegate?.geminiLiveClient(self, didReceiveMessage: item)
                }

                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {
                    let sampleRate = parseSampleRate(from: mimeType) ?? 24000
                    playAudio(data: audioData, sampleRate: Double(sampleRate))
                }
            }
        }
    }

    private func parseSampleRate(from mimeType: String) -> Int? {
        // Expected: "audio/pcm;rate=24000"
        guard let rateRange = mimeType.range(of: "rate=") else { return nil }
        let rateString = mimeType[rateRange.upperBound...]
        return Int(rateString)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredSampleRate(desiredInputSampleRate)
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }
    }

    private func startAudio() {
        stopAudio()

        inputNode = audioEngine.inputNode
        guard let inputNode else { return }

        let tapFormat = inputNode.outputFormat(forBus: 0)
        converterInputFormat = tapFormat

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: desiredInputSampleRate,
            channels: 1,
            interleaved: true
        )
        converterOutputFormat = outputFormat
        if let outputFormat {
            audioConverter = AVAudioConverter(from: tapFormat, to: outputFormat)
        } else {
            audioConverter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioInput(buffer: buffer)
        }

        playerNode = AVAudioPlayerNode()
        if let playerNode {
            audioEngine.attach(playerNode)
            let defaultPlaybackFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24000,
                channels: 1,
                interleaved: false
            )
            playbackFormat = defaultPlaybackFormat
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: defaultPlaybackFormat)
        }

        do {
            try audioEngine.start()
        } catch {
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }
    }

    private func stopAudio() {
        audioEngine.stop()
        inputNode?.removeTap(onBus: 0)
        playerNode?.stop()
        playbackFormat = nil
        audioConverter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
    }

    private func processAudioInput(buffer: AVAudioPCMBuffer) {
        guard isConnected else { return }

        if let playerNode, playerNode.isPlaying {
            return
        }

        if let converter = audioConverter,
           let inputFormat = converterInputFormat,
           let outputFormat = converterOutputFormat {
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return }

            var conversionError: NSError?
            var didProvideInput = false
            let outputStatus = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let conversionError {
                delegate?.geminiLiveClient(self, didEncounterError: conversionError)
                return
            }
            if outputStatus == .error {
                delegate?.geminiLiveClient(
                    self,
                    didEncounterError: NSError(domain: "GeminiLiveClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert microphone audio"])
                )
                return
            }

            guard let int16Channel = convertedBuffer.int16ChannelData?[0] else { return }
            let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
            let pcmData = Data(bytes: int16Channel, count: byteCount)
            sendAudioChunk(pcmData, sampleRate: Int(outputFormat.sampleRate))
            return
        }

        guard let pcmData = pcm16Data(from: buffer) else { return }
        sendAudioChunk(pcmData, sampleRate: Int(buffer.format.sampleRate))
    }

    private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        let frameCount = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frameCount)

        for index in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, channelData[index]))
            samples[index] = Int16(clamped * Float(Int16.max))
        }

        return samples.withUnsafeBytes { Data($0) }
    }

    private func playAudio(data: Data, sampleRate: Double) {
        guard let playerNode else { return }

        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)
        if playbackFormat?.sampleRate != desiredFormat?.sampleRate {
            audioEngine.stop()
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.disconnectNodeOutput(playerNode)
            playbackFormat = desiredFormat
            if let desiredFormat {
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: desiredFormat)
            }
            do {
                try audioEngine.start()
            } catch {
                delegate?.geminiLiveClient(self, didEncounterError: error)
                return
            }
        }

        guard let format = playbackFormat else { return }
        let frameCapacity = UInt32(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        buffer.frameLength = frameCapacity

        guard let int16Channel = buffer.int16ChannelData?[0] else { return }
        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(int16Channel, baseAddress, data.count)
            }
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func teardownConnection(notify: Bool) {
        let hadActiveTask = (webSocketTask != nil)

        isConnected = false
        stopAudio()

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        if notify, hadActiveTask {
            delegate?.geminiLiveClient(self, didChangeStatus: .disconnected)
        }
    }

    private func endpointCandidates(from endpoint: String) -> [String] {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func addCandidate(_ candidate: String, to candidates: inout [String]) {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !candidates.contains(value) {
                candidates.append(value)
            }
        }

        func versionSwap(_ value: String) -> String? {
            if value.contains(".v1beta.") {
                return value.replacingOccurrences(of: ".v1beta.", with: ".v1alpha.")
            }
            if value.contains(".v1alpha.") {
                return value.replacingOccurrences(of: ".v1alpha.", with: ".v1beta.")
            }
            return nil
        }

        func wsSwap(_ value: String) -> String? {
            if value.contains("://generativelanguage.googleapis.com/ws/") {
                return value.replacingOccurrences(of: "://generativelanguage.googleapis.com/ws/", with: "://generativelanguage.googleapis.com/")
            }
            if value.contains("://generativelanguage.googleapis.com/") {
                return value.replacingOccurrences(of: "://generativelanguage.googleapis.com/", with: "://generativelanguage.googleapis.com/ws/")
            }
            return nil
        }

        let swappedVersion = versionSwap(trimmed)
        let swappedWs = wsSwap(trimmed)

        var candidates: [String] = [trimmed]
        if let swappedVersion {
            addCandidate(swappedVersion, to: &candidates)
        }
        if let swappedWs {
            addCandidate(swappedWs, to: &candidates)
        }
        if let swappedVersion, let swappedWs {
            let combined = wsSwap(swappedVersion) ?? versionSwap(swappedWs)
            if let combined {
                addCandidate(combined, to: &candidates)
            }
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           let host = url.host,
           (scheme == "wss" || scheme == "ws") {
            let apiVersion = trimmed.contains("v1alpha") ? "v1alpha" : "v1beta"
            let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
            let base = "\(scheme)://\(host)"

            let restCandidate = "\(base)/\(apiVersion)/\(modelPath):bidiGenerateContent"
            addCandidate(restCandidate, to: &candidates)
            addCandidate("\(restCandidate)?alt=websocket", to: &candidates)
        }

        return candidates
    }

    private func probeHttpError(for webSocketEndpoint: String) {
        var urlString = webSocketEndpoint
        if urlString.hasPrefix("wss://") {
            urlString = "https://" + String(urlString.dropFirst("wss://".count))
        } else if urlString.hasPrefix("ws://") {
            urlString = "http://" + String(urlString.dropFirst("ws://".count))
        }

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                let bodyPreview: String
                if let data, !data.isEmpty {
                    let prefix = data.prefix(2048)
                    bodyPreview = String(data: prefix, encoding: .utf8) ?? "<non-utf8 body \(prefix.count) bytes>"
                } else {
                    bodyPreview = "<empty body>"
                }
                print("🔎 Gemini Live probe HTTP \(http.statusCode) for \(urlString): \(bodyPreview)")
            } else if let error {
                print("🔎 Gemini Live probe failed for \(urlString): \(error.localizedDescription)")
            }
        }.resume()
    }
}

extension GeminiLiveClient: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }

        isConnected = true
        delegate?.geminiLiveClient(self, didChangeStatus: .connected)

        receiveMessage()
        sendSetup()
        startAudio()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        teardownConnection(notify: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === urlSession, task === webSocketTask else { return }
        guard let error else { return }

        if let response = task.response as? HTTPURLResponse {
            if response.statusCode == 404, !remainingEndpointCandidates.isEmpty {
                connectNextEndpoint()
                return
            }
            if response.statusCode == 404 {
                let endpoint = currentEndpointAttempt ?? "unknown endpoint"
                probeHttpError(for: endpoint)
            }
            print("❌ Gemini Live handshake HTTP \(response.statusCode) headers: \(response.allHeaderFields)")
            let endpoint = currentEndpointAttempt ?? "unknown endpoint"
            let message = "Gemini Live WebSocket handshake failed (HTTP \(response.statusCode)) for \(endpoint)."
            let wrapped = NSError(domain: "GeminiLiveClient", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            delegate?.geminiLiveClient(self, didEncounterError: wrapped)
        } else {
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }

        teardownConnection(notify: true)
    }
}
