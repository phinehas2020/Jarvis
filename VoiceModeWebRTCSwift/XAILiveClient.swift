import Foundation
import AVFoundation

/// A client for interacting with xAI's Grok Realtime API via WebSocket.
/// Features:
/// - Connects to wss://api.x.ai/v1/realtime
/// - Sends Microphone Audio (PCM16 16kHz)
/// - Receives & Plays Response Audio (PCM16 24kHz likely, converted to Float32)
/// - Handles native Voice VAD
class XAILiveClient: NSObject {
    
    // MARK: - Types
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }
    
    // MARK: - Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String
    private var isConnected = false
    private var sessionConfirmed = false
    
    // Audio Input (Mic) - Using LocalAudioRecorder (AVAudioEngine-based) instead of CaptureSessionRecorder
    // to avoid FigAudioSession conflicts when using AVAudioEngine for playback
    private let audioRecorder = LocalAudioRecorder()
    private var isRecording = false
    
    // Audio Output (Speaker)
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // xAI/OpenAI Standard Output is usually 24kHz PCM16 (Int16 in JSON)
    // We configure the player for 24kHz.
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    
    // Decoding State
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    
    // Audio chunk counter for debugging
    private var receivedAudioChunks = 0
    
    // Tools for function calling
    private var tools: [[String: Any]] = []
    
    // Callbacks
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    var onMessageReceived: ((_ role: String, _ text: String) -> Void)?
    var onToolCall: ((_ name: String, _ callId: String, _ arguments: String) -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    
    // MARK: - Init
    
    init(apiKey: String, model: String = "grok-beta", voice: String = "Cove", instructions: String = "You are a helpful and charming assistant named Jarvis.", tools: [[String: Any]] = []) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.tools = tools
        super.init()
        
        // NOTE: Audio recorder setup happens in startAudio() since LocalAudioRecorder
        // configures its own audio session when starting
        setupAudioInterruptionHandling()
    }
    
    private func configureAudioSession() {
        AudioSessionManager.shared.configureForVoiceChat(sampleRate: 24000)
    }
    
    private func setupAudioInterruptionHandling() {
        AudioSessionManager.shared.setInterruptionHandlers(
            began: { [weak self] in
                self?.playerNode.pause()
            },
            ended: { [weak self] in
                self?.restartAudioEngineIfNeeded()
            }
        )
    }
    
    private func restartAudioEngineIfNeeded() {
        if !audioEngine.isRunning {
            do {
                configureAudioSession()
                try audioEngine.start()
                print("✅ XAI: Audio engine restarted")
            } catch {
                print("❌ XAI: Failed to restart audio engine: \(error)")
            }
        }
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Public API
    
    func connect() {
        guard !isConnected else { return }
        
        // xAI Realtime Endpoint
        guard let url = URL(string: "wss://api.x.ai/v1/realtime") else {
            onError?(NSError(domain: "XAILiveClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("GrokClient/1.0", forHTTPHeaderField: "User-Agent")
        
        print("🔌 XAI: Connecting to \(url.absoluteString) with key prefix: \(apiKey.prefix(4))...")
        onConnectionStateChange?(.connecting)
        
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        
        isConnected = true
        sessionConfirmed = false
        receivedAudioChunks = 0
        receiveMessage()
        
        // Send session update immediately - the API will respond with session.created/updated
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendSessionUpdate()
        }
    }
    
    func disconnect() {
        stopAudio()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        sessionConfirmed = false
        onConnectionStateChange?(.disconnected)
        AudioSessionManager.shared.deactivate()
    }
    
    func sendText(_ text: String) {
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        sendJSON(event)
        sendJSON(["type": "response.create"])
    }
    
    // MARK: - Audio Setup
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        do {
            try audioEngine.start()
            print("✅ XAI: Audio engine started, format: \(audioFormat)")
        } catch {
            print("❌ XAI Audio Engine Error: \(error)")
        }
    }
    
    private func setupAudioRecorder() {
        // LocalAudioRecorder doesn't need prepare() - it sets up when startRecording() is called
        var chunkCount = 0
        audioRecorder.onChunk = { [weak self] base64, rms in
            guard let self = self, self.isConnected else { return }
            
            chunkCount += 1
            
            // Log first 5 chunks immediately, then every 50th
            if chunkCount <= 5 {
                print("🎤 XAI: Audio chunk #\(chunkCount) (\(base64.count) bytes, RMS: \(String(format: "%.1f", rms)))")
            } else if chunkCount % 50 == 0 {
                print("🎤 XAI: Sending audio chunk #\(chunkCount) (RMS: \(String(format: "%.1f", rms)))")
            }
            
            // Report audio level for visualization
            DispatchQueue.main.async {
                self.onAudioLevel?(rms)
            }
            
            // Send mic audio as input_audio_buffer.append
            let event: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": base64
            ]
            self.sendJSON(event)
        }
    }
    
    private func startAudio() {
        guard !isRecording else { return }
        print("🎙️ XAI: Starting audio pipeline...")
        
        // Set up the audio recorder callback first
        setupAudioRecorder()
        
        // LocalAudioRecorder configures its own audio session and uses AVAudioEngine for input
        // This is compatible with our AVAudioEngine for output
        audioRecorder.startRecording()
        isRecording = true
        
        // Start the playback engine after a brief delay to let input stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.setupAudioEngine()
            print("🎙️ XAI: Audio pipeline fully started")
        }
    }
    
    private func stopAudio() {
        print("⏹️ Stopping Audio Recorder...")
        audioRecorder.stopRecording()
        isRecording = false
    }
    
    // MARK: - WebSocket Handling
    
    private func sendSessionUpdate() {
        // xAI Grok Realtime API uses OpenAI-compatible session.update format
        var sessionConfig: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": voice,
            "instructions": instructions,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": "whisper-1"
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500
            ]
        ]
        
        // Add tools if provided
        if !tools.isEmpty {
            sessionConfig["tools"] = tools
            sessionConfig["tool_choice"] = "auto"
            print("🔧 XAI: Adding \(tools.count) tools to session")
        }
        
        let event: [String: Any] = [
            "type": "session.update",
            "session": sessionConfig
        ]
        print("📤 XAI: Sending session.update with voice='\(voice)'")
        sendJSON(event)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        
        // Don't log every audio append
        if dict["type"] as? String != "input_audio_buffer.append" {
             // print("📤 Sending JSON: \(string)") // Optional: verbose logging
        }
        
        let message = URLSessionWebSocketTask.Message.string(string)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("❌ XAI Send Error: \(error.localizedDescription)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isConnected else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleEvent(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleEvent(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
                
            case .failure(let error):
                print("❌ XAI Receive Error: \(error.localizedDescription)")
                self.disconnect()
                self.onError?(error)
            }
        }
    }
    
    private func handleEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        
        // VERBOSE: Log ALL events to debug what xAI is sending
        // Filter out only the most frequent ones
        if type != "ping" && !type.contains("input_audio_buffer.append") {
            if type.contains("audio") || type.contains("response") {
                print("📥 XAI Event: \(type) - Keys: \(event.keys.sorted())")
            } else if !type.contains("delta") {
                print("📥 XAI Event: \(type)")
            }
        }
        
        switch type {
        case "session.created", "session.updated":
            print("✅ XAI: Session confirmed - \(type)")
            if let session = event["session"] as? [String: Any] {
                print("   Voice: \(session["voice"] ?? "unknown")")
                print("   Input format: \(session["input_audio_format"] ?? "unknown")")
                print("   Output format: \(session["output_audio_format"] ?? "unknown")")
            }
            if !sessionConfirmed {
                sessionConfirmed = true
                onConnectionStateChange?(.connected)
                startAudio()
            }
            
        // xAI uses "response.output_audio.delta" instead of OpenAI's "response.audio.delta"
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String {
                receivedAudioChunks += 1
                if receivedAudioChunks == 1 {
                    print("🔊 XAI: First audio chunk received!")
                } else if receivedAudioChunks % 50 == 0 {
                    print("🔊 XAI: Received \(receivedAudioChunks) audio chunks")
                }
                playAudioDelta(base64: delta)
            }
            
        // xAI uses "response.output_audio_transcript.delta" for streaming transcript
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                self.onMessageReceived?("assistant", delta)
            }
            
        // xAI sends full transcript in "response.output_audio_transcript.done"
        case "response.output_audio_transcript.done":
            if let transcript = event["transcript"] as? String {
                print("📝 XAI: Assistant said: \(transcript)")
            }
            
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String {
                print("🎤 XAI: User said: \(transcript)")
                self.onMessageReceived?("user", transcript)
            }
            
        case "input_audio_buffer.speech_started":
            print("🗣️ XAI: Speech Started detected by Server - Interrupting...")
            // 1. Stop local playback immediately
            playerNode.stop()
            
            // 2. Clear any pending completion handler or buffers if valid
            // (AVAudioPlayerNode.stop() clears its internal buffer)
            
            // 3. Send cancellation to server to stop generation
            sendJSON(["type": "response.cancel"])
            
            receivedAudioChunks = 0  // Reset counter for new response
            
        case "input_audio_buffer.speech_stopped":
            print("🤫 XAI: Speech Stopped detected by Server")
            
        case "response.created":
            print("💬 XAI: Response generation started")
            receivedAudioChunks = 0  // Reset counter for new response
            
        case "response.done":
            print("✅ XAI: Response complete (received \(receivedAudioChunks) audio chunks total)")
            
        // Handle function/tool calls - xAI may use different event names
        case "response.function_call_arguments.done":
            // OpenAI-style function call completion
            if let callId = event["call_id"] as? String,
               let name = event["name"] as? String,
               let arguments = event["arguments"] as? String {
                print("🔧 XAI: Function call: \(name) with callId: \(callId)")
                self.onToolCall?(name, callId, arguments)
            }
            
        case "response.output_item.added":
            // Check if this is a function call item
            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "function_call" {
                print("🔧 XAI: Function call item detected")
                // The actual arguments come in response.function_call_arguments.done
            }
            
        case "response.output_item.done":
            // Check if this is a completed function call
            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                // Get arguments - might be in different places
                let arguments = item["arguments"] as? String ?? "{}"
                print("🔧 XAI: Function call complete: \(name)")
                self.onToolCall?(name, callId, arguments)
            }
            
        case "error":
            print("❌ XAI API Error: \(event)")
            if let errorObj = event["error"] as? [String: Any] {
                print("   Type: \(errorObj["type"] ?? "unknown")")
                print("   Message: \(errorObj["message"] ?? "unknown")")
            }
            
        default:
            break
        }
    }
    
    // MARK: - Tool Call Response
    
    /// Send the result of a tool/function call back to the API
    func sendToolResult(callId: String, result: String) {
        let event: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ]
        ]
        print("🔧 XAI: Sending tool result for callId: \(callId)")
        sendJSON(event)
        
        // Trigger a response after sending the tool result
        sendJSON(["type": "response.create"])
    }
    
    // MARK: - Playback Logic
    
    private func playAudioDelta(base64: String) {
        guard let data = Data(base64Encoded: base64) else {
            print("⚠️ XAI: Failed to decode base64 audio")
            return
        }
        
        // Ensure audio engine is running
        restartAudioEngineIfNeeded()
        
        // Data is Int16 (pcm16). Convert to PCMBuffer compatible with engine (Float32).
        let frameCount = data.count / 2
        guard frameCount > 0 else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("⚠️ XAI: Failed to create PCM buffer")
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        guard let floatChannel = pcmBuffer.floatChannelData?[0] else {
            print("⚠️ XAI: No float channel data")
            return
        }
        
        data.withUnsafeBytes { (rawBytes: UnsafeRawBufferPointer) in
            guard let pointer = rawBytes.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                // Convert Int16 to Float [-1.0, 1.0]
                floatChannel[i] = Float(pointer[i]) / 32768.0
            }
        }
        
        playerNode.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
        
        if !playerNode.isPlaying {
            print("▶️ XAI: Starting audio playback")
            playerNode.play()
        }
    }
}
