import Foundation
import AVFoundation
import swift_gemini_api

// Protocol matching what WebRTCManager expects
protocol GeminiLiveClientAdapterDelegate: AnyObject {
    func geminiLiveClientAdapter(_ client: GeminiLiveClientAdapter, didChangeStatus status: ConnectionStatus)
    func geminiLiveClientAdapter(_ client: GeminiLiveClientAdapter, didReceiveMessage message: ConversationItem)
    func geminiLiveClientAdapter(_ client: GeminiLiveClientAdapter, didEncounterError error: Error)
    func geminiLiveClientAdapter(_ client: GeminiLiveClientAdapter, didRequestToolExecution tool: String, args: [String: Any], callId: String)
}

/// Wrapper around the 'swift-gemini-api' library's GeminiLiveClient class.
/// This maintains compatibility with WebRTCManager without manual WebSocket/AV handling.
private final class GeminiSpeechController {
    private let synthesizer = AVSpeechSynthesizer()
    private var pendingText: String = ""
    private var lastUpdate: Date = .distantPast
    private var debounceTimer: Timer?

    var voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "en-US")
    var speechRate: Float = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.25)
    var debounceSeconds: TimeInterval = 0.35

    func stop() {
        DispatchQueue.main.async {
            self.debounceTimer?.invalidate()
            self.debounceTimer = nil
            self.pendingText = ""
            self.lastUpdate = .distantPast
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func appendAndDebounce(_ segment: String) {
        DispatchQueue.main.async {
            let cleanedSegment = segment
            guard !cleanedSegment.isEmpty else { return }

            if self.pendingText.isEmpty {
                self.pendingText = cleanedSegment
            } else if cleanedSegment.hasPrefix(self.pendingText) {
                // Some SDKs send cumulative transcripts; prefer replacing.
                self.pendingText = cleanedSegment
            } else if !self.pendingText.hasSuffix(cleanedSegment) {
                // Otherwise assume incremental segments; append.
                self.pendingText += cleanedSegment
            }

            self.lastUpdate = Date()

            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: self.debounceSeconds, repeats: false) { [weak self] _ in
                self?.flushIfStable()
            }
        }
    }

    private func flushIfStable() {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= debounceSeconds else { return }

        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            pendingText = ""
            return
        }

        pendingText = ""

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        print("🗣️ Speaking Gemini response via iOS TTS (chars: \(text.count), rate: \(String(format: "%.2f", speechRate)))")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}

final class GeminiLiveClientAdapter: NSObject {
    weak var delegate: GeminiLiveClientAdapterDelegate?
    
    private let client: GeminiLiveClient
    private let apiKey: String
    private let audioRecorder = LocalAudioRecorder()
    private let speechController = GeminiSpeechController()
    private var lastMicLevelLogAt: Date = .distantPast
    private var lastMicSilenceWarnAt: Date = .distantPast
    
    // Track connection status locally
    private var _isConnected: Bool = false
    
    init(apiKey: String, model: String, systemPrompt: String, tools: [[String: Any]] = []) {
        self.apiKey = apiKey
        
        // Initialize the library's client.
        // The library handles WebSocket and audio playback internally.
        // Using v1beta (more stable for native audio models) and enabling verbose logging
        self.client = GeminiLiveClient(
            model: model,
            systemPrompt: systemPrompt,
            version: "v1beta",  // Use v1beta instead of v1alpha for better compatibility
            voice: .PUCK,
            onSetupComplete: nil,
            verbose: true,  // Enable verbose logging to debug response issues
            input_audio_transcription: true,
            output_audio_transcription: true,
            automaticActivityDetection: true
        )

        super.init()

        // Use Gemini native audio playback (since we are using the Native Audio model)
        client.playAudio = true

        // Set up callbacks for the library
        setupCallbacks()
        
        // Set up audio recording to send to the client
        setupAudioRecording()
        
        // Add function declarations if tools are provided
        // Convert from OpenAI format to Gemini format
        for tool in tools {
            if let geminiTool = convertToGeminiFormat(tool: tool) {
                print("📝 Adding Gemini tool: \(geminiTool["name"] ?? "unknown")")
                client.addFunctionDeclarations(geminiTool)
            }
        }
    }
    
    /// Convert OpenAI-style tool format to Gemini format
    /// OpenAI: { "type": "function", "name": "...", "description": "...", "parameters": {...} }
    /// Gemini: { "name": "...", "description": "...", "parameters": {...} }
    private func convertToGeminiFormat(tool: [String: Any]) -> [String: Any]? {
        // Skip MCP tools (they have type: "mcp")
        if let type = tool["type"] as? String {
            if type == "mcp" {
                print("⏭️ Skipping MCP tool (not compatible with Gemini Live)")
                return nil
            }
            if type == "function" {
                // OpenAI format - extract the relevant fields
                var geminiTool: [String: Any] = [:]
                if let name = tool["name"] as? String {
                    geminiTool["name"] = name
                }
                if let description = tool["description"] as? String {
                    geminiTool["description"] = description
                }
                if let parameters = tool["parameters"] as? [String: Any] {
                    geminiTool["parameters"] = parameters
                }
                return geminiTool.isEmpty ? nil : geminiTool
            }
        }
        
        // If it's already in Gemini format (has name but no type), use it directly
        if tool["name"] != nil && tool["type"] == nil {
            return tool
        }
        
        return nil
    }
    
    private var audioChunkCount = 0
    
    private func setupAudioRecording() {
        // Forward audio chunks from recorder to the Gemini client
        audioRecorder.onChunk = { [weak self] base64Audio, rms in
            guard let self = self else { return }
            self.audioChunkCount += 1
            
            // Log first few chunks + periodic health check
            if self.audioChunkCount <= 10 || self.audioChunkCount % 500 == 1 {
                let audioBytes = base64Audio.count * 3 / 4 // Approximate decoded size
                
                print("🎙️ Audio chunk #\(self.audioChunkCount) (\(audioBytes) bytes, RMS: \(String(format: "%.1f", rms)))")
            }

            let now = Date()
            if rms >= 150, now.timeIntervalSince(self.lastMicLevelLogAt) >= 0.8 {
                let db = 20.0 * log10(max(Double(rms) / 32768.0, 1e-6))
                let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
                print("🎤 Mic level: RMS \(String(format: "%.1f", rms)) (~\(String(format: "%.0f", db)) dBFS, input: \(inputs))")
                self.lastMicLevelLogAt = now
            } else if rms <= 5, now.timeIntervalSince(self.lastMicSilenceWarnAt) >= 6.0, self.audioChunkCount > 20 {
                let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
                print("🔇 Mic looks near-silent (RMS \(String(format: "%.1f", rms)), input: \(inputs))")
                self.lastMicSilenceWarnAt = now
            }

            self.client.sendAudio(base64: base64Audio)
        }
    }

    private func configureGeminiAudioSession() {
        AudioSessionManager.shared.configureForRecording(sampleRate: 16000)
        AudioSessionManager.shared.forceToSpeaker()
    }

    private func setupCallbacks() {
        // Handle connection status via onSetupComplete
        client.onSetupComplete = { [weak self] success in
            guard let self = self else { return }
            self._isConnected = success
            
            if success {
                print("🎤 Starting audio recording...")
                self.configureGeminiAudioSession()
                self.audioRecorder.startRecording()
                
            } else {
                print("❌ Setup failed, stopping audio recording")
                self.audioRecorder.stopRecording()
                self.speechController.stop()
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let status: ConnectionStatus = success ? .connected : .disconnected
                self.delegate?.geminiLiveClientAdapter(self, didChangeStatus: status)
            }
        }
        
        // Handle output transcription (assistant's response text)
        client.setOutputTranscription { [weak self] text in
            guard let self = self else { return }
            // Disable local TTS since we are using native audio
            // self.speechController.appendAndDebounce(text)
            let item = ConversationItem(
                id: UUID().uuidString,
                role: "assistant",
                text: text
            )
            DispatchQueue.main.async {
                self.delegate?.geminiLiveClientAdapter(self, didReceiveMessage: item)
            }
        }
        
        // Handle input transcription (user's speech)
        client.setInputTranscription { [weak self] text in
            print("🗣️ User speech detected: \(text)")
            guard let self = self else { return }
            let item = ConversationItem(
                id: UUID().uuidString,
                role: "user",
                text: text
            )
            DispatchQueue.main.async {
                self.delegate?.geminiLiveClientAdapter(self, didReceiveMessage: item)
            }
        }
        
        // Handle tool calls
        client.setToolCall { [weak self] name, id, args in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.geminiLiveClientAdapter(self, didRequestToolExecution: name, args: args, callId: id)
            }
        }
    }
    
    // MARK: - Public API matching WebRTCManager usage
    
    func connect() {
        print("🔌 GeminiLiveClientAdapter: Connecting via library...")
        print("🔑 Using API key: \(apiKey.prefix(10))...")
        configureGeminiAudioSession()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.geminiLiveClientAdapter(self, didChangeStatus: .connecting)
        }
        client.connect(apiKey: apiKey)
    }
    
    func disconnect() {
        print("🔌 GeminiLiveClientAdapter: Disconnecting...")
        speechController.stop()
        audioRecorder.stopRecording()
        client.disconnect()
        _isConnected = false
        AudioSessionManager.shared.deactivate()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.geminiLiveClientAdapter(self, didChangeStatus: .disconnected)
        }
    }
    
    func sendText(_ text: String) {
        client.sendTextPrompt(text)
    }
    
    /// Manually signal end of user's speech turn to trigger Gemini response
    func endTurn() {
        print("🎙️ Manually ending turn...")
        client.sendActivityEnd()
    }
    
    func sendToolResponse(callId: String, response: String) {
        // The library expects a dictionary for the function response if possible.
        // We try to parse the string as JSON, otherwise send as "result": string
        var responseMap: [String: Any] = [:]
        
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            responseMap = json
        } else {
            responseMap = ["result": response]
        }
        
        client.sendFunctionResponse(callId, response: responseMap)
    }
    
    var isConnected: Bool {
        return _isConnected
    }
}
