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
    private var isReadyForAudio: Bool = false
    private var isAwaitingModelResponse: Bool = false
    private var remainingEndpointCandidates: [String] = []
    private var currentEndpointAttempt: String?

    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private let playbackStateLock = NSLock()
    private var pendingPlaybackBuffers: Int = 0

    private let desiredInputSampleRate: Double = 16000
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?

    private static let defaultEndpointUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let vadSpeechRmsThreshold: Float = 0.02
    private let vadContinueRmsThreshold: Float = 0.015
    private let vadSilenceDurationSeconds: TimeInterval = 0.75
    private var vadHasDetectedSpeechInCurrentTurn: Bool = false
    private var vadSilenceBeganUptime: TimeInterval?
    private var nextRmsLogUptime: TimeInterval = 0

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

        // Append API key as query parameter
        var urlString = endpoint
        if !apiKey.isEmpty {
            let separator = endpoint.contains("?") ? "&" : "?"
            urlString = "\(endpoint)\(separator)key=\(apiKey)"
        }

        print("🔌 Gemini Live WS connecting: \(urlString)")

        guard let url = URL(string: urlString) else {
            connectNextEndpoint()
            return
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

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
        isAwaitingModelResponse = true

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

        // Start with minimal setup - just model and config
        let modelName = model.hasPrefix("models/") ? model : "models/\(model)"
        
        var setupDict: [String: Any] = [
            "model": modelName,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": "Puck"
                        ]
                    ]
                ]
            ]
        ]
        
        if !systemPrompt.isEmpty {
            setupDict["systemInstruction"] = [
                "parts": [
                    ["text": systemPrompt]
                ]
            ]
        }
        
        let message: [String: Any] = [
            "setup": setupDict
        ]

        print("📤 Sending minimal setup message for model: \(model)")
        print("📤 Setup JSON: \(String(data: try! JSONSerialization.data(withJSONObject: message), encoding: .utf8) ?? "error")")
        sendJSON(message)
    }

    private var audioChunkCounter = 0
    
    private func sendAudioChunk(_ pcm16Data: Data, sampleRate: Int) {
        guard isConnected else { return }
        guard isReadyForAudio else { return }
        guard !isAwaitingModelResponse else { return }
        guard !isPlayingAssistantAudio() else { return }

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

        audioChunkCounter += 1
        if audioChunkCounter % 100 == 0 {
             // We can't calculate RMS from Data easily here efficiently without decoding, 
             // but we will rely on the fact that we are sending data.
            print("🎤 Sent \(audioChunkCounter) audio chunks (\(pcm16Data.count) bytes @ \(sampleRate)Hz)")
        }
        
        sendJSON(message)
    }

    private func sendAudioTurnStartIfNeeded() {
        guard isConnected else { return }
        guard isReadyForAudio else { return }

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": " "]
                        ]
                    ]
                ]
            ]
        ]

        print("📤 Starting audio turn (clientContent)")
        sendJSON(message)
    }

    private func sendTurnComplete() {
        guard isConnected else { return }
        guard isReadyForAudio else { return }

        let message: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]
        print("📤 Sending turnComplete (audio)")
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
                print("❌ Gemini Live send error: \(nsError.localizedDescription) (domain: \(nsError.domain) code: \(nsError.code))")
                if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                    self.teardownConnection(notify: true)
                    return
                }
                self.delegate?.geminiLiveClient(self, didEncounterError: nsError)
            }
        }
    }

    private var messageCounter = 0
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.messageCounter += 1
                switch message {
                case .string(let text):
                    print("📨 Message #\(self.messageCounter) received (\(text.count) chars)")
                    self.handleMessage(text)
                case .data(let data):
                    print("📨 Message #\(self.messageCounter) received (\(data.count) bytes as data)")
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    } else {
                        print("⚠️ Could not decode data as UTF-8")
                    }
                @unknown default:
                    print("⚠️ Unknown message type")
                    break
                }

                if self.isConnected {
                    self.receiveMessage()
                }

            case .failure(let error):
                print("❌ WebSocket receive error: \(error.localizedDescription)")
                self.delegate?.geminiLiveClient(self, didEncounterError: error)
                self.disconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        print("📥 Received Gemini Live message: \(text.prefix(200))...")
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ Failed to parse message JSON")
            return
        }

        // Handle setupComplete
        if json["setupComplete"] != nil {
            print("✅ Setup complete - ready to receive audio!")
            isReadyForAudio = true
            startAudio()
            return
        }

        // Handle errors
        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Gemini Live error"
            print("❌ Gemini Live error: \(message)")
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            )
            return
        }

        // Handle toolCall
        if json["toolCall"] != nil {
            print("🔧 Received tool call (not yet implemented)")
            return
        }

        // Handle serverContent
        guard let serverContent = json["serverContent"] as? [String: Any] else {
            print("⚠️ Unhandled message type, keys: \(json.keys.joined(separator: ", "))")
            return
        }

        // Handle interruption
        if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
            print("⚠️ Model was interrupted")
            isAwaitingModelResponse = false
            return
        }

        // Handle model turn with response
        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            print("✅ Received model turn with \(parts.count) parts")
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    print("💬 Received text: \(text)")
                    let item = ConversationItem(id: UUID().uuidString, role: "assistant", text: text)
                    delegate?.geminiLiveClient(self, didReceiveMessage: item)
                }

                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {
                    print("🔊 Received audio: \(audioData.count) bytes, mimeType: \(mimeType)")
                    let sampleRate = parseSampleRate(from: mimeType) ?? 24000
                    playAudio(data: audioData, sampleRate: Double(sampleRate))
                }
            }
        }

        // Handle turnComplete
        if serverContent["turnComplete"] != nil {
            print("✅ Turn complete")
            isAwaitingModelResponse = false
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
        guard isReadyForAudio else { return }
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
        playbackStateLock.lock()
        pendingPlaybackBuffers = 0
        playbackStateLock.unlock()
        audioConverter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
    }

    private func processAudioInput(buffer: AVAudioPCMBuffer) {
        guard isConnected else { return }
        guard isReadyForAudio else { return }

        // Apply digital gain (10x) to boost generic mic input without excessive noise
        if let floatData = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            for i in 0..<frames {
                floatData[i] = min(1.0, max(-1.0, floatData[i] * 10.0))
            }
        }

        let rms = listAudioLevels(buffer)

        // Debug RMS levels (every ~2 seconds)
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRmsLogUptime {
            nextRmsLogUptime = now + 2.0
            print("🎤 Audio Input RMS: \(rms) (boosted 10x)")
        }

        if isAwaitingModelResponse || isPlayingAssistantAudio() {
            return
        }

        updateTurnDetection(rms: rms)
        if isAwaitingModelResponse {
            return
        }

        if let converter = audioConverter,
           let inputFormat = converterInputFormat,
           let outputFormat = converterOutputFormat {
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                print("❌ Failed to create converted buffer")
                return
            }

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
                print("❌ Audio conversion error: \(conversionError.localizedDescription)")
                delegate?.geminiLiveClient(self, didEncounterError: conversionError)
                return
            }
            if outputStatus == .error {
                print("❌ Audio conversion returned error status")
                delegate?.geminiLiveClient(
                    self,
                    didEncounterError: NSError(domain: "GeminiLiveClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert microphone audio"])
                )
                return
            }

            // CRITICAL FIX: AVAudioConverter doesn't set frameLength automatically
            // We need to calculate it based on the expected conversion ratio
            let expectedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            convertedBuffer.frameLength = expectedFrames

            // Check if we got valid data
            if convertedBuffer.frameLength == 0 {
                print("⚠️ Converted buffer has 0 frames (input had \(buffer.frameLength) frames)")
                return
            }

            guard let int16Channel = convertedBuffer.int16ChannelData?[0] else {
                print("❌ No int16 channel data after conversion")
                return
            }
            let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
            let pcmData = Data(bytes: int16Channel, count: byteCount)
            sendAudioChunk(pcmData, sampleRate: Int(outputFormat.sampleRate))
            return
        }

        if audioChunkCounter % 100 == 0 {
            let rms = listAudioLevels(buffer)
            print("🎤 Audio Input RMS: \(rms)")
        }

        // Fallback path without conversion
        guard let pcmData = pcm16Data(from: buffer) else {
            print("⚠️ Failed to get PCM data from buffer (frameLength: \(buffer.frameLength))")
            return
        }
        sendAudioChunk(pcmData, sampleRate: Int(buffer.format.sampleRate))
    }

    private func updateTurnDetection(rms: Float) {
        let now = ProcessInfo.processInfo.systemUptime

        let isSpeech: Bool
        if vadHasDetectedSpeechInCurrentTurn {
            isSpeech = rms >= vadContinueRmsThreshold
        } else {
            isSpeech = rms >= vadSpeechRmsThreshold
        }

        if isSpeech {
            if !vadHasDetectedSpeechInCurrentTurn {
                sendAudioTurnStartIfNeeded()
            }
            vadHasDetectedSpeechInCurrentTurn = true
            vadSilenceBeganUptime = nil
            return
        }

        guard vadHasDetectedSpeechInCurrentTurn else { return }

        if vadSilenceBeganUptime == nil {
            vadSilenceBeganUptime = now
            return
        }

        guard let silenceBegan = vadSilenceBeganUptime else { return }
        if now - silenceBegan >= vadSilenceDurationSeconds {
            vadHasDetectedSpeechInCurrentTurn = false
            vadSilenceBeganUptime = nil

            guard !isAwaitingModelResponse else { return }
            isAwaitingModelResponse = true
            sendTurnComplete()
        }
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
            playbackStateLock.lock()
            pendingPlaybackBuffers = 0
            playbackStateLock.unlock()
            playerNode.stop()
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

        incrementPendingPlaybackBuffers()
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.decrementPendingPlaybackBuffers()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func incrementPendingPlaybackBuffers() {
        playbackStateLock.lock()
        pendingPlaybackBuffers += 1
        playbackStateLock.unlock()
    }

    private func decrementPendingPlaybackBuffers() {
        playbackStateLock.lock()
        pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
        playbackStateLock.unlock()
    }

    private func isPlayingAssistantAudio() -> Bool {
        playbackStateLock.lock()
        let isPlaying = pendingPlaybackBuffers > 0
        playbackStateLock.unlock()
        return isPlaying
    }

    private func teardownConnection(notify: Bool) {
        let hadActiveTask = (webSocketTask != nil)

        isConnected = false
        isReadyForAudio = false
        isAwaitingModelResponse = false
        vadHasDetectedSpeechInCurrentTurn = false
        vadSilenceBeganUptime = nil
        nextRmsLogUptime = 0
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

        // Append API key as query parameter
        if !apiKey.isEmpty {
            let separator = urlString.contains("?") ? "&" : "?"
            urlString = "\(urlString)\(separator)key=\(apiKey)"
        }

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
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

        print("✅ Gemini Live WebSocket opened successfully (protocol: \(`protocol` ?? "none"))")
        isConnected = true
        isReadyForAudio = false
        isAwaitingModelResponse = false
        delegate?.geminiLiveClient(self, didChangeStatus: .connected)

        receiveMessage()
        
        // Add a small delay before sending setup to ensure socket is ready for writes
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.isConnected else { return }
            self.sendSetup()
        }
    }
    
    // Helper to calculate RMS for debugging
    private func listAudioLevels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        return sqrt(sum / Float(frameLength))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        print("🔌 Gemini Live WebSocket closed: code=\(closeCode.rawValue), reason=\(reasonString)")
        
        // If we haven't successfully established a session (or just connected and closed), try next candidate
        if !remainingEndpointCandidates.isEmpty {
             print("⚠️ WebSocket closed, trying next endpoint candidate...")
             connectNextEndpoint()
             return
        }
        
        teardownConnection(notify: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === urlSession, task === webSocketTask else { return }
        
        if error == nil {
            print("✅ Gemini Live WebSocket task completed successfully")
            return
        }
        
        guard let error else { return }

        if let response = task.response as? HTTPURLResponse {
            print("❌ Gemini Live handshake HTTP \(response.statusCode) headers: \(response.allHeaderFields)")
            
            if !remainingEndpointCandidates.isEmpty {
                print("⚠️ HTTP \(response.statusCode), trying next endpoint candidate...")
                connectNextEndpoint()
                return
            }
            
            if response.statusCode == 404 {
                let endpoint = currentEndpointAttempt ?? "unknown endpoint"
                probeHttpError(for: endpoint)
            }
            
            let endpoint = currentEndpointAttempt ?? "unknown endpoint"
            let message = "Gemini Live WebSocket handshake failed (HTTP \(response.statusCode)) for \(endpoint)."
            let wrapped = NSError(domain: "GeminiLiveClient", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            delegate?.geminiLiveClient(self, didEncounterError: wrapped)
        } else {
            print("❌ Gemini Live WebSocket error: \(error.localizedDescription)")
            
            if !remainingEndpointCandidates.isEmpty {
                print("⚠️ Connection error, trying next endpoint candidate...")
                connectNextEndpoint()
                return
            }
            
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }

        teardownConnection(notify: true)
    }
}
