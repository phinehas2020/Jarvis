import Foundation
import AVFoundation
import UIKit

protocol GeminiLiveClientDelegate: AnyObject {
    func geminiLiveClient(_ client: GeminiLiveClient, didChangeStatus status: ConnectionStatus)
    func geminiLiveClient(_ client: GeminiLiveClient, didReceiveMessage message: ConversationItem)
    func geminiLiveClient(_ client: GeminiLiveClient, didEncounterError error: Error)
}

/// Minimal Gemini Live client for BidiGenerateContent.
/// Connects to the v1beta WS, sends setup, streams 16k PCM, and plays 24k PCM responses.
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
    private var tapCallbackCount = 0
    private var audioChunkCounter = 0
    private let maximumMicGain: Float = 10.0
    private var nextRmsLogUptime: TimeInterval = 0

    init(apiKey: String, model: String, systemPrompt: String) {
        self.apiKey = apiKey
        self.model = model.hasPrefix("models/") ? model : "models/\(model)"
        self.systemPrompt = systemPrompt
        self.endpointUrlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        super.init()
        setupAudioSession()
    }

    deinit {
        audioEngine.stop()
        inputNode?.removeTap(onBus: 0)
        playerNode?.stop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: - Public API
    func connect() {
        teardownConnection(notify: false)

        guard !apiKey.isEmpty else {
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is missing"])
            )
            return
        }

        guard let url = URL(string: endpointUrlString) else {
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini Live endpoint URL"])
            )
            return
        }

        delegate?.geminiLiveClient(self, didChangeStatus: .connecting)

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")

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

        let completeMessage: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]
        sendJSON(completeMessage)

        isAwaitingModelResponse = true
    }

    // MARK: - Setup
    private func sendSetup() {
        guard isConnected else { return }

        let setupDict: [String: Any] = [
            "model": model,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": "Puck"
                        ]
                    ]
                ]
            ],
            "systemInstruction": systemPrompt
        ]

        let message: [String: Any] = [
            "setup": setupDict
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Setup JSON: \(jsonString)")
        }
        sendJSON(message)
    }

    // MARK: - Audio capture
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("🎤 Audio session initialized at \(session.sampleRate)Hz")
        } catch {
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }
    }

    private func startAudio() {
        guard isReadyForAudio else { return }
        stopAudio()
        tapCallbackCount = 0

        inputNode = audioEngine.inputNode
        guard let inputNode else { return }

        let tapFormat = inputNode.outputFormat(forBus: 0)
        converterInputFormat = tapFormat

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: desiredInputSampleRate,
            channels: 1,
            interleaved: false
        )
        converterOutputFormat = targetFormat
        if let targetFormat {
            audioConverter = AVAudioConverter(from: tapFormat, to: targetFormat)
        } else {
            audioConverter = nil
        }

        let bufferSize = UInt32(tapFormat.sampleRate / 10)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioInput(buffer: buffer)
        }

        playerNode = AVAudioPlayerNode()
        if let playerNode {
            audioEngine.attach(playerNode)
            let defaultPlaybackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
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
        guard isConnected, isReadyForAudio else { return }

        // Simple limiter
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

        // Optional RMS logging
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextRmsLogUptime {
            nextRmsLogUptime = now + 5.0
            let rawRms = listAudioLevels(buffer)
            print("🎤 Audio Input RMS: \(rawRms) (streaming)")
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

            if conversionError != nil || outputStatus == .error {
                return
            }

            convertedBuffer.frameLength = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let int16Channel = convertedBuffer.int16ChannelData?[0] else { return }
            let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
            let pcmData = Data(bytes: int16Channel, count: byteCount)
            sendAudioChunk(pcmData, sampleRate: Int(outputFormat.sampleRate))
            return
        }

        guard let pcmData = pcm16Data(from: buffer) else { return }
        sendAudioChunk(pcmData, sampleRate: Int(buffer.format.sampleRate))
    }

    private func listAudioLevels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        return sqrt(sum / Float(frameLength))
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

    // MARK: - Send / Receive
    private func sendAudioChunk(_ pcm16Data: Data, sampleRate: Int) {
        guard isConnected else { return }
        guard isReadyForAudio else { return }

        audioChunkCounter += 1
        if audioChunkCounter == 1 {
            print("🎤 Streaming audio to Gemini Live (\(pcm16Data.count) bytes @ \(sampleRate)Hz)")
        }
        if audioChunkCounter % 100 == 0 {
            print("🎤 Sent \(audioChunkCounter) audio chunks")
        }

        let pcmDataToSend = pcm16Data
        webSocketSendQueue.async { [weak self] in
            guard let self else { return }
            let base64 = pcmDataToSend.base64EncodedString()
            let message: [String: Any] = [
                "realtimeInput": [
                    "mediaChunks": [
                        [
                            "mimeType": "audio/pcm;rate=16000",
                            "data": base64
                        ]
                    ]
                ]
            ]
            self.sendJSONOnSendQueue(message)
        }
    }

    private func sendAudioStreamEnd() {
        guard isConnected else { return }
        guard isReadyForAudio else { return }
        print("📤 Ending speech turn and sending turnComplete")

        let turnComplete: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]
        sendJSON(turnComplete)
        isAwaitingModelResponse = true
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
                self.delegate?.geminiLiveClient(self, didEncounterError: nsError)
            } else {
                // Success (omit logging spam)
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
                let nsError = error as NSError
                print("❌ WebSocket receive error: \(error.localizedDescription)")
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

        // setupComplete
        if json["setupComplete"] != nil {
            print("✅ Setup complete - ready to stream audio")
            isReadyForAudio = true
            startAudio()
            return
        }

        // errors
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = (error["message"] as? String) ?? "Gemini Live error"
            delegate?.geminiLiveClient(
                self,
                didEncounterError: NSError(domain: "GeminiLiveClient", code: code, userInfo: [
                    NSLocalizedDescriptionKey: message,
                    "fullError": error
                ])
            )
            return
        }

        // serverContent
        guard let serverContent = json["serverContent"] as? [String: Any] else { return }

        if serverContent["turnComplete"] != nil {
            isAwaitingModelResponse = false
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
        guard let rateRange = mimeType.range(of: "rate=") else { return nil }
        let rateString = mimeType[rateRange.upperBound...]
        return Int(rateString)
    }

    // MARK: - Playback
    private func playAudio(data: Data, sampleRate: Double) {
        guard let playerNode else { return }

        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)

        if playbackFormat?.sampleRate != desiredFormat?.sampleRate {
            playbackStateLock.lock()
            pendingPlaybackBuffers = 0
            playbackStateLock.unlock()

            playerNode.stop()
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.disconnectNodeOutput(playerNode)
            playbackFormat = desiredFormat

            if let desiredFormat {
                audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: desiredFormat)
            }

            if !audioEngine.isRunning {
                reinstallInputTapAndStartEngine()
            }
        }

        guard let format = playbackFormat else { return }
        let frameCapacity = UInt32(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        buffer.frameLength = frameCapacity

        guard let int16Channel = buffer.int16ChannelData?[0] else { return }
        let byteCount = min(data.count, Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            memcpy(int16Channel, base, byteCount)
        }

        incrementPendingPlaybackBuffers()
        playerNode.scheduleBuffer(buffer, completionHandler: { [weak self] in
            self?.decrementPendingPlaybackBuffers()
        })

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func reinstallInputTapAndStartEngine() {
        audioEngine.stop()
        inputNode?.removeTap(onBus: 0)
        let inputNode = audioEngine.inputNode
        let tapFormat = inputNode.outputFormat(forBus: 0)
        let bufferSize = UInt32(tapFormat.sampleRate / 10)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioInput(buffer: buffer)
        }
        do {
            try audioEngine.start()
        } catch {
            delegate?.geminiLiveClient(self, didEncounterError: error)
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

    // MARK: - Connection teardown
    private func teardownConnection(notify: Bool) {
        let hadActiveTask = (webSocketTask != nil)

        isConnected = false
        isReadyForAudio = false
        isAwaitingModelResponse = false
        stopAudio()

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

    private var responseTimeoutTimer: Timer?
}

extension GeminiLiveClient: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        print("✅ Gemini Live WebSocket opened successfully (protocol: \(proto ?? "none"))")
        isConnected = true
        isReadyForAudio = false
        isAwaitingModelResponse = false
        delegate?.geminiLiveClient(self, didChangeStatus: .connected)

        receiveMessage()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.isConnected else { return }
            self.sendSetup()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === urlSession, webSocketTask === self.webSocketTask else { return }
        print("🔌 WebSocket closed code=\(closeCode.rawValue)")
        teardownConnection(notify: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === urlSession, task === webSocketTask else { return }
        if let error {
            delegate?.geminiLiveClient(self, didEncounterError: error)
        }
        teardownConnection(notify: true)
    }
}
