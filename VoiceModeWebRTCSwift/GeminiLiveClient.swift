import Foundation
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
final class GeminiLiveClientAdapter: NSObject {
    weak var delegate: GeminiLiveClientAdapterDelegate?
    
    private let client: GeminiLiveClient
    private let apiKey: String
    private let audioRecorder = AudioRecorder()
    
    // Track connection status locally
    private var _isConnected: Bool = false
    
    init(apiKey: String, model: String, systemPrompt: String, tools: [[String: Any]] = []) {
        self.apiKey = apiKey
        
        // Initialize the library's client.
        // The library handles WebSocket and audio playback internally.
        self.client = GeminiLiveClient(
            model: model,
            systemPrompt: systemPrompt,
            voice: .PUCK,
            onSetupComplete: nil
        )
        
        super.init()
        
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
    
    private func setupAudioRecording() {
        // Forward audio chunks from recorder to the Gemini client
        audioRecorder.setOnChunk { [weak self] base64Audio in
            self?.client.sendAudio(base64: base64Audio)
        }
    }
    
    private func setupCallbacks() {
        // Handle connection status via onSetupComplete
        client.onSetupComplete = { [weak self] success in
            guard let self = self else { return }
            self._isConnected = success
            
            if success {
                print("🎤 Starting audio recording...")
                // Send activity start signal before sending audio
                self.client.sendActivityStart()
                self.audioRecorder.startRecording()
            } else {
                print("❌ Setup failed, stopping audio recording")
                self.audioRecorder.stopRecording()
            }
            
            DispatchQueue.main.async {
                let status: ConnectionStatus = success ? .connected : .disconnected
                self.delegate?.geminiLiveClientAdapter(self, didChangeStatus: status)
            }
        }
        
        // Handle output transcription (assistant's response text)
        client.setOutputTranscription { [weak self] text in
            guard let self = self else { return }
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.geminiLiveClientAdapter(self, didChangeStatus: .connecting)
        }
        client.connect(apiKey: apiKey)
    }
    
    func disconnect() {
        print("🔌 GeminiLiveClientAdapter: Disconnecting...")
        audioRecorder.stopRecording()
        client.disconnect()
        _isConnected = false
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
