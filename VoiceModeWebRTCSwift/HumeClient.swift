import Foundation
import AVFoundation

protocol HumeClientDelegate: AnyObject {
    func humeClient(_ client: HumeClient, didChangeStatus status: ConnectionStatus)
    func humeClient(_ client: HumeClient, didReceiveMessage message: ConversationItem)
    func humeClient(_ client: HumeClient, didEncounterError error: Error)
}

class HumeClient: NSObject {
    weak var delegate: HumeClientDelegate?
    
    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    
    // Audio Engine
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    
    // State
    private var isConnected = false
    private let apiKey: String
    private let secretKey: String
    
    // Constants
    private let humeWssUrl = "wss://api.hume.ai/v0/evi/chat"
    
    init(apiKey: String, secretKey: String) {
        self.apiKey = apiKey
        self.secretKey = secretKey
        super.init()
        setupAudioSession()
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        guard !apiKey.isEmpty else {
            delegate?.humeClient(self, didEncounterError: NSError(domain: "HumeClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key is missing"]))
            return
        }
        
        Task {
            // In a real app, we would use the secret key to mint an access token on the backend.
            // For now, if Hume supports API Key in headers or query params for WebSocket, we use that.
            // NOTE: Hume EVI usually requires an access token for the WebSocket.
            // We will attempt to fetch an access token first if possible, or use the API Key if the endpoint allows.
            
            // For this implementation, we'll try to get an access token first.
            let accessToken = await fetchAccessToken()
            guard let token = accessToken else {
                delegate?.humeClient(self, didEncounterError: NSError(domain: "HumeClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Failed to generate Access Token"]))
                return
            }
            
            startWebSocket(accessToken: token)
        }
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        stopAudio()
        isConnected = false
        delegate?.humeClient(self, didChangeStatus: .disconnected)
    }
    
    // MARK: - Access Token
    
    private func fetchAccessToken() async -> String? {
        // This is a minimal implementation to fetch an access token via the Secret Key
        // Endpoint: POST https://api.hume.ai/oauth2-cc/token
        // Auth: Basic <base64(apiKey:secretKey)>
        
        guard let url = URL(string: "https://api.hume.ai/oauth2-cc/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let authString = "\(apiKey):\(secretKey)"
        if let authData = authString.data(using: .utf8) {
            let base64Auth = authData.base64EncodedString()
            request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("❌ Hume Auth Failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
                return nil
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessToken = json["access_token"] as? String {
                return accessToken
            }
        } catch {
            print("❌ Hume Auth Error: \(error)")
        }
        
        return nil
    }
    
    // MARK: - WebSocket
    
    private func startWebSocket(accessToken: String) {
        guard let url = URL(string: "\(humeWssUrl)?access_token=\(accessToken)") else { return }
        
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        delegate?.humeClient(self, didChangeStatus: .connected)
        
        receiveMessage()
        
        // 1. Send session settings first
        sendSessionSettings()
        
        // 2. Start audio capture only after connection is established
        // 2. Start audio capture with a slight delay to ensure settings are processed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startAudio()
        }
    }
    
    private func sendSessionSettings() {
        // Configure for typical iOS mic input: 44.1kHz or 48kHz.
        // Hume processes raw audio (Linear PCM).
        // Sending session_settings is best practice.
        let settings: [String: Any] = [
            "type": "session_settings",
            "audio": [
                "encoding": "linear16",
                "sample_rate": 48000, // Matching higher quality default
                "channels": 1
            ],
            "context": [
                "text": "You are Jarvis, a helpful, witty, and concise AI assistant."
            ],
            "system_prompt": "You are Jarvis. Be concise, helpful, and friendly. Do not be verbose.",
            "event_messages": [
                "on_new_chat": [
                    "enabled": true,
                    "text": "Hello! I'm listening."
                ]
            ]
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: settings),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    print("❌ Failed to send session settings: \(error)")
                } else {
                    print("✅ Hume session settings sent")
                }
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    self.handleBinaryMessage(data)
                @unknown default:
                    break
                }
                
                if self.isConnected {
                    self.receiveMessage()
                }
                
            case .failure(let error):
                print("❌ Hume WebSocket Error: \(error)")
                self.disconnect()
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "user_message":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                let item = ConversationItem(id: UUID().uuidString, role: "user", text: content)
                delegate?.humeClient(self, didReceiveMessage: item)
            }
            
        case "assistant_message":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                let item = ConversationItem(id: UUID().uuidString, role: "assistant", text: content)
                delegate?.humeClient(self, didReceiveMessage: item)
            }
            
        case "audio_output":
            if let dataStr = json["data"] as? String,
               let audioData = Data(base64Encoded: dataStr) {
                playAudio(data: audioData)
            }
            
        case "error":
            if let errorMessage = json["message"] as? String {
                print("❌ Hume API Error: \(errorMessage)")
            }
            
        default:
            break
        }
    }
    
    private func handleBinaryMessage(_ data: Data) {
        // Binary messages are usually audio output in PCM Linear 16-bit 24kHz or 48kHz
        // For EVI, audio output often comes as base64 string in JSON, but if binary:
        playAudio(data: data)
    }
    
    // MARK: - Audio Handling
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }
    
    private func startAudio() {
        // Reset engine
        stopAudio()
        
        inputNode = audioEngine.inputNode
        let inputFormat = inputNode?.outputFormat(forBus: 0)
        
        // Target format: 44.1kHz, mono, Int16 (Hume expects Linear PCM 16-bit)
        // We will tap the node, then downconvert/upconvert if needed in processAudioInput
        // For simplicity, we just use the native hardware format but ensure we cast to Int16
        
        // Note: installTap gives us Float32 buffers usually. We MUST convert to Int16 before sending to Hume.
        
        inputNode?.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            self?.processAudioInput(buffer: buffer)
        }
        
        // Setup player node
        playerNode = AVAudioPlayerNode()
        guard let playerNode = playerNode else { return }
        audioEngine.attach(playerNode)
        
        // Default output format (usually 44.1kHz or 48kHz Stereo)
        // We MUST connect the player node with the format we intend to play.
        // Since audio sounded slow/deep at 24kHz setting, the data is likely 48kHz.
        
        let humeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)
        // SAFEST APPROACH: Connect to mainMixerNode, not outputNode directly. 
        // The mixer handles resampling and channel mixing automatically.
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: humeFormat)
        
        do {
            try audioEngine.start()
        } catch {
            print("❌ Audio Engine Error: \(error)")
        }
    }
    
    private func stopAudio() {
        audioEngine.stop()
        inputNode?.removeTap(onBus: 0)
        playerNode?.stop()
    }
    
    private func processAudioInput(buffer: AVAudioPCMBuffer) {
        guard isConnected, let webSocketTask = webSocketTask else { return }
        
        // Anti-Echo Gate: Do not send audio if the AI is currently speaking.
        // This prevents the AI from hearing itself and interrupting itself.
        if let player = playerNode, player.isPlaying {
            return
        }
        
        // Convert Float32 buffer (standard iOS mic) to Int16 for Hume
        guard let pcmBuffer = convertToPCMInt16(buffer: buffer) else { return }
        
        let audioData = pcmBuffer.toData()
        let base64 = audioData.base64EncodedString()
        
        // Debug: print audio packet size periodically (e.g. random sample) to confirm data flow
        // if Int.random(in: 0...50) == 0 {
        //    print("🎤 Sending audio packet: \(audioData.count) bytes")
        // }
        
        let message: [String: Any] = [
            "type": "audio_input",
            "data": base64
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask.send(wsMessage) { error in
                if let error = error {
                    // print("❌ Failed to send audio: \(error)")
                }
            }
        }
    }
    
    private func playAudio(data: Data) {
        // Convert Data back to PCM Buffer for playback
        // Note: We need to know the format sent by Hume.
        // Usually EVI sends 24kHz or 48kHz mono PCM 16-bit.
        
        // Use the format from the audio engine's output node to ensure compatibility
        // But the data ITSELF is likely 24kHz mono. We must create a buffer that matches the DATA.
        // Then we can let the engine mix it, or we converter it.
        // AVAudioPlayerNode will crash if we schedule a buffer with channel count != output format channel count IF it is not connected properly.
        // However, usually AVAudioEngine handles mixing if connected with the right format.
        
        // Let's stick to declaring the data format as 48kHz Mono Int16.
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false) else { return }
        
        if let buffer = data.toPCMBuffer(format: pcmFormat) {
            // Check if we need to connect the player node with this specific format first
            // If the player node is already connected to the mixer (which might be stereo), 
            // the engine *should* handle the upmix from mono to stereo automatically.
            
            playerNode?.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !(playerNode?.isPlaying ?? false) {
                playerNode?.play()
            }
        }
    }
    // Convert typical Float32 buffers to Int16 for streaming
    private func convertToPCMInt16(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        // If already int16, return strictly
        if format.commonFormat == .pcmFormatInt16 {
            return buffer
        }
        
        // Targeted format: Same sample rate, same channels, but Int16
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: false) else { return nil }
        
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else { return nil }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameLength) else { return nil }
        
        var error: NSError? = nil
        let status = converter.convert(to: outputBuffer, error: &error) { packetCount, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if status == .error || error != nil {
            return nil
        }
        
        return outputBuffer
    }
}

// MARK: - Audio Helpers

extension AVAudioPCMBuffer {
    func toData() -> Data {
        let channelCount = 1  // force mono for upload
        guard let int16ChannelData = self.int16ChannelData else { return Data() }
        let channels = UnsafeBufferPointer(start: int16ChannelData, count: channelCount)
        if let channelData = channels.first {
            let data = NSData(bytes: channelData, length: Int(self.frameCapacity * 2)) // 2 bytes per sample for Int16
            return data as Data
        }
        return Data()
    }
}

extension Data {
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Helper to convert raw Data -> AVAudioPCMBuffer
        // This requires knowing the format exactly matches the data
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(self.count) / format.streamDescription.pointee.mBytesPerFrame) else { return nil }
        
        buffer.frameLength = buffer.frameCapacity
        let channels = UnsafeBufferPointer(start: buffer.int16ChannelData, count: Int(format.channelCount))
        
        self.withUnsafeBytes { (videoBytes: UnsafeRawBufferPointer) in
            if let baseAddress = videoBytes.baseAddress {
                // Copy data into the audio buffer
                // This is a rough copy; in prod, careful memory alignment is needed
                memcpy(channels[0], baseAddress, self.count)
            }
        }
        
        return buffer
    }
}
