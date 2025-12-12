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
        startAudio()
        
        // Send initial session settings if needed
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
        
        // Install tap on input node to capture audio
        // Hume expects: Linear PCM, 16-bit, mono/stereo (usually 44.1 or 48kHz is fine, will be resampled)
        // We'll send raw bytes encoded in Base64 via JSON "audio_input" message
        
        inputNode?.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] (buffer, time) in
            self?.processAudioInput(buffer: buffer)
        }
        
        // Setup player node
        playerNode = AVAudioPlayerNode()
        guard let playerNode = playerNode else { return }
        audioEngine.attach(playerNode)
        
        // Default output format (usually 44.1kHz or 48kHz)
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: audioEngine.outputNode, format: outputFormat)
        
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
        
        // Convert buffer to Data (PCM 16-bit little endian usually preferred)
        let audioData = buffer.toData()
        let base64 = audioData.base64EncodedString()
        
        let message: [String: Any] = [
            "type": "audio_input",
            "data": base64
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask.send(wsMessage) { error in
                if let error = error {
                    print("❌ Failed to send audio: \(error)")
                }
            }
        }
    }
    
    private func playAudio(data: Data) {
        // Convert Data back to PCM Buffer for playback
        // Note: We need to know the format sent by Hume.
        // Usually EVI sends 24kHz or 48kHz mono PCM 16-bit.
        
        // For simplicity, assuming 24kHz mono 16-bit (common EVI default):
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false) else { return }
        
        if let buffer = data.toPCMBuffer(format: format) {
            playerNode?.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !(playerNode?.isPlaying ?? false) {
                playerNode?.play()
            }
        }
    }
}

// MARK: - Audio Helpers

extension AVAudioPCMBuffer {
    func toData() -> Data {
        let channelCount = 1  // force mono for upload
        let channels = UnsafeBufferPointer(start: self.int16ChannelData, count: channelCount)
        let ch0Data = NSData(bytes: channels[0], length:Int(self.frameCapacity * self.format.streamDescription.pointee.mBytesPerFrame))
        return ch0Data as Data
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
