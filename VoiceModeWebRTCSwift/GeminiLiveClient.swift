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
    private let webSocketSendQueue = DispatchQueue(label: "GeminiLiveClient.webSocketSendQueue")

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

    private let desiredInputSampleRate: Double = 16000  // Gemini Live API expects 16kHz input
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?

    // Gemini Live API WebSocket endpoint - model is specified in setup message, not URL
    // Format: wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}
    private static let defaultEndpointUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let maximumMicGain: Float = 10.0
    private let vadSpeechRmsThreshold: Float = 0.012  // Lower for iPhone mics (was 0.02)
    private let vadContinueRmsThreshold: Float = 0.008  // Lower for quiet rooms (was 0.015)
    private let vadSilenceDurationSeconds: TimeInterval = 0.4  // Faster response (was 0.75)
    private var vadHasDetectedSpeechInCurrentTurn: Bool = false
    private var vadSilenceBeganUptime: TimeInterval?
    private var nextRmsLogUptime: TimeInterval = 0
    private var currentTurnStartUptime: TimeInterval?
    private var currentTurnAudioChunksSent: Int = 0
    private var currentTurnAudioBytesSent: Int = 0
    private var responseTimeoutTimer: Timer?
    private let responseTimeoutSeconds: TimeInterval = 10.0

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

        var endpoint = remainingEndpointCandidates.removeFirst()
        
        // Add API key as query parameter (required for Gemini Live WebSocket)
        if !apiKey.isEmpty {
            let separator = endpoint.contains("?") ? "&" : "?"
            endpoint = "\(endpoint)\(separator)key=\(apiKey)"
            print("🔑 Using query parameter authentication (?key=...)")
        }
        
        currentEndpointAttempt = endpoint

        print("🔌 Gemini Live WS connecting: \(endpoint.replacingOccurrences(of: apiKey, with: "***API_KEY***"))")
        print("📋 Model: \(model) (will be sent in setup message)")

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

        // Send turn content first
        let turnMessage: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": trimmed]
                        ]
                    ]
                ]
            ]
        ]
        sendJSON(turnMessage)
        
        // Then send turn complete separately
        let completeMessage: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]
        sendJSON(completeMessage)
        
        isAwaitingModelResponse = true
    }

    private func sendSetup() {
        guard isConnected else { return }

        // Model name must be prefixed with "models/"
        let modelName = model.hasPrefix("models/") ? model : "models/\(model)"
        
        // Gemini Live API setup message format
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

        print("📤 Sending Gemini Live setup")
        print("📤 Model: \(modelName)")
        if let jsonData = try? JSONSerialization.data(withJSONObject: message, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Setup JSON: \(jsonString)")
        }
        sendJSON(message)
    }

    private var audioChunkCounter = 0
    
    private func sendAudioChunk(_ pcm16Data: Data, sampleRate: Int) {
        guard isConnected else { return }
        guard isReadyForAudio else { return }
        guard !isAwaitingModelResponse else { return }
        guard !isPlayingAssistantAudio() else { return }
        guard vadHasDetectedSpeechInCurrentTurn else { return }

        if currentTurnAudioChunksSent == 0 {
            print("🎤 Sending first audio chunk (\(pcm16Data.count) bytes @ \(sampleRate)Hz)")
        }

        currentTurnAudioChunksSent += 1
        currentTurnAudioBytesSent += pcm16Data.count

        audioChunkCounter += 1
        if audioChunkCounter % 100 == 0 {
             // We can't calculate RMS from Data easily here efficiently without decoding,
             // but we will rely on the fact that we are sending data.
            print("🎤 Sent \(audioChunkCounter) audio chunks (\(pcm16Data.count) bytes @ \(sampleRate)Hz)")
        }

        let pcmDataToSend = pcm16Data
        let sampleRateToSend = sampleRate
        webSocketSendQueue.async { [weak self] in
            guard let self else { return }
            let base64 = pcmDataToSend.base64EncodedString()
            // Use "media" not "audio" - this is the correct format per Gemini Live API docs
            let message: [String: Any] = [
                "realtimeInput": [
                    "media": [
                        "mimeType": "audio/pcm;rate=\(sampleRateToSend)",
                        "data": base64
                    ]
                ]
            ]
            self.sendJSONOnSendQueue(message)
        }
    }

    private func sendAudioStreamEnd() {
        guard isConnected else { return }
        guard isReadyForAudio else { return }
        print("📤 Sending activityEnd")
        print("⏳ Awaiting model response...")
        // Use activityEnd to signal end of audio input (not audioStreamEnd)
        sendJSON(["realtimeInput": ["activityEnd": [:]]])
        
        // Start timeout timer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.responseTimeoutTimer?.invalidate()
            self.responseTimeoutTimer = Timer.scheduledTimer(withTimeInterval: self.responseTimeoutSeconds, repeats: false) { [weak self] _ in
                guard let self else { return }
                if self.isAwaitingModelResponse {
                    print("⚠️ Response timeout - no response from Gemini after \(self.responseTimeoutSeconds)s")
                    print("⚠️ This might indicate an API issue, incorrect model name, or missing configuration")
                    self.isAwaitingModelResponse = false
                    self.vadHasDetectedSpeechInCurrentTurn = false
                }
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        webSocketSendQueue.async { [weak self] in
            self?.sendJSONOnSendQueue(object)
        }
    }

    private func sendJSONOnSendQueue(_ object: [String: Any]) {
        guard let webSocketTask else {
            print("⚠️ Cannot send JSON: WebSocket task is nil")
            return
        }
        
        guard webSocketTask.state == .running else {
            print("⚠️ Cannot send JSON: WebSocket state is \(webSocketTask.state.rawValue) (not running)")
            return
        }
        
        guard JSONSerialization.isValidJSONObject(object) else {
            print("⚠️ Invalid JSON object")
            return
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: object),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("⚠️ Failed to serialize JSON")
            return
        }

        webSocketTask.send(.string(jsonString)) { [weak self] error in
            guard let self else { return }
            if let nsError = error as NSError? {
                print("❌ Gemini Live send error: \(nsError.localizedDescription) (domain: \(nsError.domain) code: \(nsError.code))")
                print("❌ Error details: \(nsError)")
                if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                    print("❌ Socket not connected (POSIX 57) - connection was closed")
                    self.teardownConnection(notify: true)
                    return
                }
                self.delegate?.geminiLiveClient(self, didEncounterError: nsError)
            } else {
                print("✅ Message sent successfully")
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
                let nsError = error as NSError
                print("❌ WebSocket receive error: \(error.localizedDescription)")
                print("❌ Error domain: \(nsError.domain), code: \(nsError.code)")
                print("❌ Full error: \(nsError)")
                self.delegate?.geminiLiveClient(self, didEncounterError: error)
                self.disconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        print("📥 Received Gemini Live message (\(text.count) chars)")
        print("📥 Full message: \(text)")
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ Failed to parse message JSON")
            print("⚠️ Raw message: \(text)")
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
            let code = error["code"] as? Int ?? -1
            let message = (error["message"] as? String) ?? "Gemini Live error"
            let status = error["status"] as? String ?? "UNKNOWN"
            print("❌ Gemini Live API error:")
            print("   Code: \(code)")
            print("   Status: \(status)")
            print("   Message: \(message)")
            print("   Full error: \(error)")
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: code, userInfo: [
                    NSLocalizedDescriptionKey: message,
                    "status": status,
                    "fullError": error
                ])
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
            print("⚠️ Full JSON: \(json)")
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
            
            // Cancel timeout as we received a response
            DispatchQueue.main.async { [weak self] in
                self?.responseTimeoutTimer?.invalidate()
                self?.responseTimeoutTimer = nil
            }
            
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
            DispatchQueue.main.async { [weak self] in
                self?.responseTimeoutTimer?.invalidate()
                self?.responseTimeoutTimer = nil
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
            interleaved: false
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

        // IMPORTANT: Compute RMS pre-gain for VAD; boosting/clamping can prevent silence detection.
        let rawRms = listAudioLevels(buffer)

        // Debug RMS levels (every ~2 seconds)
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRmsLogUptime {
            nextRmsLogUptime = now + 2.0
            print("🎤 Audio Input RMS: \(rawRms) (raw)")
        }

        if isAwaitingModelResponse || isPlayingAssistantAudio() {
            return
        }

        updateTurnDetection(rms: rawRms)
        if isAwaitingModelResponse {
            return
        }

        // Only send microphone audio once VAD considers us "in speech" for this turn.
        guard vadHasDetectedSpeechInCurrentTurn else { return }

        // Apply microphone gain with a simple limiter to avoid clipping.
        if let channelData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)

            var maxAbs: Float = 0
            for channelIndex in 0..<channels {
                let samples = channelData[channelIndex]
                for frameIndex in 0..<frames {
                    maxAbs = max(maxAbs, abs(samples[frameIndex]))
                }
            }

            if maxAbs > 0 {
                let limitedGain = min(maximumMicGain, 0.99 / maxAbs)
                if limitedGain > 1.0 {
                    for channelIndex in 0..<channels {
                        let samples = channelData[channelIndex]
                        for frameIndex in 0..<frames {
                            samples[frameIndex] *= limitedGain
                        }
                    }
                }
            }
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
                currentTurnStartUptime = now
                currentTurnAudioChunksSent = 0
                currentTurnAudioBytesSent = 0
                print("🎙️ Speech started (rms=\(rms))")
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
            
            if let start = currentTurnStartUptime {
                let duration = ProcessInfo.processInfo.systemUptime - start
                print("🎤 Ending speech turn (\(currentTurnAudioChunksSent) chunks, \(currentTurnAudioBytesSent) bytes, ~\(String(format: "%.2f", duration))s)")
            } else {
                print("🎤 Ending speech turn (\(currentTurnAudioChunksSent) chunks, \(currentTurnAudioBytesSent) bytes)")
            }
            currentTurnStartUptime = nil
            currentTurnAudioChunksSent = 0
            currentTurnAudioBytesSent = 0
            
            // CRITICAL: Send audioStreamEnd BEFORE setting awaiting flag
            // Otherwise the guard in sendAudioStreamEnd will block it
            sendAudioStreamEnd()
            isAwaitingModelResponse = true
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

    private func redactApiKey(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        guard let items = components.queryItems, !items.isEmpty else { return urlString }

        components.queryItems = items.map { item in
            guard item.name.lowercased() == "key", let value = item.value, !value.isEmpty else { return item }
            return URLQueryItem(name: item.name, value: "REDACTED")
        }
        return components.string ?? urlString
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
        
        // Clean up timeout timer
        DispatchQueue.main.async { [weak self] in
            self?.responseTimeoutTimer?.invalidate()
            self?.responseTimeoutTimer = nil
        }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        if notify, hadActiveTask {
            delegate?.geminiLiveClient(self, didChangeStatus: .disconnected)
        }
    }

    private func endpointCandidates(from endpoint: String) -> [String] {
        // Gemini Live API WebSocket format:
        // wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}
        // The model is specified in the setup message, NOT in the URL
        
        var candidates: [String] = []
        
        // Use provided endpoint if it looks valid (contains BidiGenerateContent or /ws/)
        if !endpoint.isEmpty && (endpoint.contains("BidiGenerateContent") || endpoint.contains("/ws/")) {
            candidates.append(endpoint)
        }

        // Primary: Global WebSocket endpoint for Gemini Live API
        candidates.append("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        
        print("🔍 Prepared \(candidates.count) Gemini Live endpoint candidates:")
        for (index, candidate) in candidates.enumerated() {
            print("   \(index + 1). \(candidate)")
        }
        print("📋 Model will be specified in setup message: \(model)")

        return candidates
    }

    private func probeHttpError(for webSocketEndpoint: String) {
        var urlString = webSocketEndpoint
        if urlString.hasPrefix("wss://") {
            urlString = "https://" + String(urlString.dropFirst("wss://".count))
        } else if urlString.hasPrefix("ws://") {
            urlString = "http://" + String(urlString.dropFirst("ws://".count))
        }
        
        // API key should already be in the URL as query parameter

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                var bodyPreview: String = "<no data>"
                
                if let data, !data.isEmpty {
                    // Try to decompress if gzipped
                    var decodedData = data
                    if let contentEncoding = http.allHeaderFields["Content-Encoding"] as? String,
                       contentEncoding.lowercased().contains("gzip") {
                        // Data might be gzipped - try to decompress
                        do {
                            decodedData = try (data as NSData).decompressed(using: .zlib) as Data
                            print("🔎 Decompressed gzipped response: \(decodedData.count) bytes")
                        } catch {
                            print("🔎 Could not decompress gzip: \(error)")
                        }
                    }
                    
                    let prefix = decodedData.prefix(2048)
                    bodyPreview = String(data: prefix, encoding: .utf8) ?? "<non-utf8 body \(prefix.count) bytes>"
                }
                
                print("🔎 Gemini Live probe HTTP \(http.statusCode)")
                print("🔎 Headers: \(http.allHeaderFields)")
                print("🔎 Body: \(bodyPreview)")
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
        
        print(String(repeating: "=", count: 60))
        print("🔌 WEBSOCKET CLOSED")
        print("   Close Code: \(closeCode.rawValue)")
        print("   Reason: \(reasonString)")
        
        // Log additional details for debugging
        if let reason = reason, !reason.isEmpty {
            print("   Reason bytes: \(reason.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print("   Reason data: \(reason as NSData)")
        }
        
        // Check if this is an abnormal closure
        if closeCode == .abnormalClosure || closeCode == .internalServerError {
            print("   ⚠️ ABNORMAL CLOSURE - server rejected connection")
        }
        print(String(repeating: "=", count: 60))
        
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
            
            if response.statusCode == 404 || response.statusCode == 400 {
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
