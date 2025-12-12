import SwiftUI
import AVFoundation

let API_KEY = "your_openai_api_key"

struct ContentView: View {
    @StateObject private var webrtcManager = WebRTCManager()
    
    @State private var showOptionsSheet = false
    @FocusState private var isTextFieldFocused: Bool
    
    // Camera preview drag state
    @State private var cameraOffset = CGSize.zero
    @State private var isDragging = false
    
    // AppStorage properties
    @AppStorage("apiKey") private var apiKey = API_KEY
    @AppStorage("customMcpEnabled") private var customMcpEnabled = true
    @AppStorage("customMcpServerUrl") private var customMcpServerUrl = ""
    @AppStorage("customMcpServerLabel") private var customMcpServerLabel = "bluebubbles"
    @AppStorage("customMcpAuthToken") private var customMcpAuthToken = ""
    @AppStorage("systemMessage") private var systemMessage = ""
    
    // Load system prompt
    private func loadSystemPrompt() -> String {
        return """
            Jarvis AI Assistant
            
            You are Jarvis, an AI assistant with iOS device control capabilities.
            
            Core Functions
            
            Device: Brightness, volume, haptic, screenshots, device info
            Media: Music control, playlists, photos, camera
            Productivity: Calendar events, reminders (Reminders app), notes (Notes app), alarms, shortcuts
            Communication: Contacts, location, weather, iMessage via the local MCP server
            Notes Management
            
            LIMITATION: iOS privacy restrictions prevent direct Notes app access. The app uses SiriKit Intents.
            
            Create note: Opens Apple Notes app with creation intent
            Search notes: Opens Apple Notes app with search intent
            View/edit/delete: Opens Apple Notes app for manual action
            Always inform users that the Notes app will open for them to complete the action.
            
            iMessage via MCP (BlueBubbles) is how we send messages

            IMPORTANT UPDATE (2025-12):
            - This setup uses the newer MCP bridge exposing only: `send_imessage`, `fetch_messages`, `get_status`.
            - The legacy `bluebubbles_*` tools and `/api/v1/chat/new` workflow are not available. Ignore any legacy instructions below and use the new tools instead.
            
            Messaging Tools (MCP)
            
            Available MCP tools from the bridge:
            - `send_imessage` – Send an outbound iMessage to a single recipient. Input: `{ to, text }` (field name is `text`, not `message`) where `to` is E.164 or an Apple ID.
            - `fetch_messages` – Fetch messages from BlueBubbles. Use `handle`, `chatGuid`, `since`, `limit` as filters.
            - `get_status` – Get quiet-hours / rate-limit state from the bridge.
            
            Messaging rules:
            
            A. When the user gives a phone number / Apple ID directly
            - Normalize phone numbers to valid E.164 (for US: `+1XXXXXXXXXX`).
            - Call `send_imessage` immediately with the user’s text.
            
            B. When the user gives a name or nickname (“Mom”, “Sweetheart”, etc.)
            - Use `search_contacts` to resolve the name to a specific number.
            - If multiple matches exist, ask the user which one they mean.
            - Then call `send_imessage`.
            
            Important:
            - Do not call any `bluebubbles_*` tools or raw `/api/v1/...` endpoints.
            - Only use tools that appear in MCP `tools/list`.

            Tool Confirmation
            
            CRITICAL: After every tool call, provide verbal confirmation tailored to what you did:
            
            On success:
            “I’ve successfully sent your message to Mom.”
            “I’ve created the reminder for tomorrow at 9 AM.”
            “I’ve opened Notes so you can finish creating this note.”
            On partial success or ambiguity:
            “I found two contacts named Alex. Do you mean Alex Smith or Alex Johnson?”
            On failure:
            “I tried to send the message but encountered an error from the messaging server: [short explanation].”
            Always:
            
            Explain what you just did in simple terms.
            Mention the app you opened when applicable.
            Offer a next step when something goes wrong.
            Communication Style
            
            Conversational and helpful
            Explain what you’re doing as you do it
            Be proactive with suggestions when they are clearly helpful
            Handle errors gracefully and briefly; don’t overwhelm with technical details unless the user asks
            Text Output Control
            
            The app can run in Audio Only Mode where text output is disabled to save API costs.
            
            Audio responses still work normally.
            Text transcripts are not displayed.
            All functionality remains the same.
            Users can toggle this in settings.
            You should behave the same way logically; just be aware that the user may not see text.
            
            Function Capabilities
            
            ALL TOOLS WORK: Use them confidently.
            
            Never say “I can’t do that” for any capability listed here.
            If there’s a constraint (e.g., Notes app privacy), explain the workflow and use the intended tool (like opening Notes via SiriKit).
            For long‑form or token‑heavy writing:
            
            Call delegate_to_gpt4o with the exact prompt you want answered (include any style/system hints you need).
            This uses a higher‑power model (gpt-5-2025-08-07 by default) without spending realtime tokens.
            Use the returned text to brief the user, summarize, or adapt, instead of generating the entire long response in the realtime session.
            Examples
            “Set brightness to 50%” → Use set_brightness.
            “Play Bohemian Rhapsody” → Use music search/play tools.
            “Create a reminder for tomorrow” → Use create_reminder (Reminders app).
            “Create a note with my ideas” → Use create_note (Notes app; explain Notes will open).
	            “Text Mom saying I’ll be late” →
	            Search contacts for “Mom”.
	            If one match, send immediately to their mobile.
	            Normalize the number and call `send_imessage` with the user’s text.
	            Remember: You are having a conversation, not just executing commands. Be helpful, explain your actions, and always confirm what you’ve done.
	            """
    }
    
    // Initialize system message from file
    private func initializeSystemMessage() {
        if systemMessage.isEmpty {
            systemMessage = loadSystemPrompt()
        }
    }
    
    private func sanitizedServerLabel(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let filteredScalars = raw.unicodeScalars.filter { allowed.contains($0) }
        let result = String(filteredScalars)
        return result.isEmpty ? "custom_mcp" : result
    }
    

    @AppStorage("selectedModel") private var selectedModel = "gpt-realtime"
    @AppStorage("selectedVoice") private var selectedVoice = "echo"
    @AppStorage("showTextOutput") private var showTextOutput = true
    @AppStorage("humeApiKey") private var humeApiKey = ""
    @AppStorage("selectedProviderRaw") private var selectedProviderRaw = "OpenAI Realtime" // Default to OpenAI
    
    private var selectedProvider: WebRTCManager.VoiceProvider {
        get { WebRTCManager.VoiceProvider(rawValue: selectedProviderRaw) ?? .openAI }
        set { selectedProviderRaw = newValue.rawValue }
    }
    
    // Constants
    private let modelOptions = [
        "gpt-realtime-mini-2025-10-06",
        "gpt-realtime",
        "gpt-realtime-2025-08-28",
        "gpt-4o-realtime-preview-2025-06-03",
        "gpt-4o-mini-realtime-preview-2024-12-17"
    ]
    private let voiceOptions = ["echo", "ash", "ballad", "coral", "sage", "shimmer", "verse"]
    private let bluebubblesToolNames = [
        "send_imessage",
        "fetch_messages",
        "get_status"
    ]
    
    // Check if current model supports vision
    private var currentModelSupportsVision: Bool {
        return selectedModel.contains("realtime") && !selectedModel.contains("4o")
    }
    
    // Check if current model is a realtime model
    private var isRealtimeModel: Bool {
        return selectedModel.contains("realtime")
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 12) {
                    HeaderView()
                    ConnectionControls()
                    Divider().padding(.vertical, 6)
                    
                    ConversationView()
                    
                    MessageInputView()
                }
                
                // Floating Video Preview - bottom-right corner, draggable (only for vision-supported models)
                if webrtcManager.isVideoEnabled && webrtcManager.isCameraOn && currentModelSupportsVision {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ZStack {
                                VideoPreviewView(webrtcManager: webrtcManager)
                                    .frame(width: 100, height: 130)
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(isDragging ? Color.green : Color.blue, lineWidth: isDragging ? 3 : 2)
                                    )
                                    .shadow(radius: isDragging ? 12 : 8)
                                    .scaleEffect(isDragging ? 1.05 : 1.0)
                                    .animation(.spring(response: 0.3), value: isDragging)
                                    .overlay(
                                        // Camera indicator
                                        VStack {
                                            HStack {
                                                Text(webrtcManager.isUsingFrontCamera ? "Front" : "Back")
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.7))
                                                    .cornerRadius(3)
                                                Spacer()
                                            }
                                            Spacer()
                                        }
                                        .padding(4),
                                        alignment: .topLeading
                                    )
                            }
                            .offset(cameraOffset)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        cameraOffset = value.translation
                                        isDragging = true
                                    }
                                    .onEnded { value in
                                        isDragging = false
                                        print("📹 Camera repositioned")
                                    }
                            )
                            .padding(.trailing, 16)
                            .padding(.bottom, 100)
                        }
                    }
                }
            }
        }
        .onAppear {
            initializeSystemMessage()
            requestMicrophonePermission()
            webrtcManager.requestCalendarPermission()
        }
        .sheet(isPresented: $showOptionsSheet) {
            OptionsView(
                apiKey: $apiKey,
                humeApiKey: $humeApiKey,
                humeSecretKey: $humeSecretKey,
                systemMessage: $systemMessage,
                selectedModel: $selectedModel,
                selectedVoice: $selectedVoice,
                selectedProviderRaw: $selectedProviderRaw,
                showTextOutput: $showTextOutput,
                customMcpEnabled: $customMcpEnabled,
                customMcpServerUrl: $customMcpServerUrl,
                customMcpServerLabel: $customMcpServerLabel,
                customMcpAuthToken: $customMcpAuthToken,
                modelOptions: modelOptions,
                voiceOptions: voiceOptions
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .startConversation)) { _ in
            webrtcManager.startConnection(
                apiKey: apiKey,
                humeApiKey: humeApiKey,
                humeSecretKey: humeSecretKey,
                provider: selectedProvider,
                modelName: selectedModel,
                systemMessage: systemMessage,
                voice: selectedVoice
            )
        }
    }
    
    private func requestMicrophonePermission() {
        // Request microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("🎤 Microphone permission granted: \(granted)")
        }
        
        // Request camera permission
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("📹 Camera permission granted: \(granted)")
        }
        
        // Request contacts permission
        webrtcManager.requestContactsPermission()
        
        if apiKey.isEmpty {
            showOptionsSheet = true
        }
    }
    
    @ViewBuilder
    private func HeaderView() -> some View {
        VStack(spacing: 2) {
            Text("Jarvis with MCP")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 12)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
    
    @ViewBuilder
    private func ConnectionControls() -> some View {
        VStack(spacing: 12) {
            // Top Row: Status and Main Connection Button
            HStack {
                // Connection status indicator
                Circle()
                    .frame(width: 12, height: 12)
                    .foregroundColor(webrtcManager.connectionStatus.color)
                Text(webrtcManager.connectionStatus.description)
                    .foregroundColor(webrtcManager.connectionStatus.color)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: webrtcManager.connectionStatus)
                    .onChange(of: webrtcManager.connectionStatus) { _ in
                        switch webrtcManager.connectionStatus {
                        case .connecting:
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        case .connected:
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        case .disconnected:
                            webrtcManager.eventTypeStr = ""
                        }
                    }
                
                Spacer()
                
                // Main Connection Button
                if webrtcManager.connectionStatus == .connected {
                    Button("Stop Connection") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webrtcManager.stopConnection()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(isRealtimeModel ? "Start Realtime Connection" : "Start Chat Connection") {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        webrtcManager.connectionStatus = .connecting
                        
                        if isRealtimeModel {
                            // Use WebRTC realtime connection for realtime models
                            // Clear any previous MCP tools and configure available servers
                            webrtcManager.clearMCPTools()
                            
                            // Add custom MCP server if configured
                            if customMcpEnabled && !customMcpServerUrl.isEmpty && !customMcpServerLabel.isEmpty {
                                let safeLabel = sanitizedServerLabel(customMcpServerLabel)
                                webrtcManager.addMCPTool(
                                    serverLabel: safeLabel,
                                    serverUrl: customMcpServerUrl,
                                    authorization: customMcpAuthToken.isEmpty ? nil : customMcpAuthToken,
                                    requireApproval: "never",
                                    expectedToolNames: bluebubblesToolNames
                                )
                                print("🔧 Added custom MCP server: \(safeLabel)")
                            }
                            
                            print("🚀 Starting realtime connection with MCP tools and contact search")
                            
                            webrtcManager.startConnection(
                                apiKey: apiKey,
                                humeApiKey: humeApiKey,
                                humeSecretKey: humeSecretKey,
                                provider: selectedProvider,
                                modelName: selectedModel,
                                systemMessage: systemMessage,
                                voice: selectedVoice
                            )
                        } else {
                            // For non-realtime models, show a message that they're not supported yet
                            print("⚠️ Non-realtime models not yet implemented")
                            webrtcManager.connectionStatus = .disconnected
                            
                            // Show alert or message to user
                            DispatchQueue.main.async {
                                // You could show an alert here
                                print("❌ The selected model (\(selectedModel)) is not yet supported. Please use a realtime model (gpt-realtime) for now.")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(webrtcManager.connectionStatus == .connecting)
                }
                
                // Settings button
                Button {
                    showOptionsSheet.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.bordered)
            }
            
            // Bottom Row: Control Buttons (only when connected) - separate row to prevent squishing
            if webrtcManager.connectionStatus == .connected {
                HStack(spacing: 8) {
                    // Mute button
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webrtcManager.toggleMute()
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: webrtcManager.isMicMuted ? "mic.slash.fill" : "mic.fill")
                                .foregroundColor(webrtcManager.isMicMuted ? .red : .primary)
                                .font(.system(size: 14))
                            Text("Mic")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(webrtcManager.isMicMuted ? "Unmute" : "Mute")
                    
                    // Speaker button
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        webrtcManager.forceAudioToSpeaker()
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))
                            Text("Speaker")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Force to Main Speaker")
                    
                    // Video button
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webrtcManager.toggleVideo()
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: webrtcManager.isVideoEnabled ? "video.fill" : "video.slash.fill")
                                .foregroundColor(currentModelSupportsVision ? (webrtcManager.isVideoEnabled ? .blue : .primary) : .gray)
                                .font(.system(size: 14))
                            Text("Video")
                                .font(.system(size: 8))
                .accessibilityLabel(currentModelSupportsVision ? (webrtcManager.isVideoEnabled ? "Disable video" : "Enable video") : "Video not supported by this model")
                    
                    // Camera on/off button (only when video is enabled and vision is supported)
                    if webrtcManager.isVideoEnabled && currentModelSupportsVision {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            webrtcManager.toggleCamera()
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: webrtcManager.isCameraOn ? "eye.fill" : "eye.slash.fill")
                                    .foregroundColor(webrtcManager.isCameraOn ? .green : .red)
                                    .font(.system(size: 14))
                                Text("Camera")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(webrtcManager.isCameraOn ? "Turn camera off" : "Turn camera on")
                    }
                    
                    // Camera rotate button (only when video enabled AND camera is on AND vision is supported)
                    if webrtcManager.isVideoEnabled && webrtcManager.isCameraOn && currentModelSupportsVision {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            webrtcManager.switchCamera()
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: "camera.rotate.fill")
                                    .foregroundColor(.purple)
                                    .font(.system(size: 14))
                                Text("Rotate")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Switch to \(webrtcManager.isUsingFrontCamera ? "Back" : "Front") Camera")
                    }
                    
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Conversation View
    @ViewBuilder
    private func ConversationView() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.headline)
                Spacer()
                Text(webrtcManager.eventTypeStr)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.leading, 16)
            }
            .padding(.horizontal)
            
            if showTextOutput {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(webrtcManager.conversation.filter { $0.role == "user" || $0.role == "assistant" }) { msg in
                            MessageRow(msg: msg)
                        }
                    }
                    .padding()
                }
            } else {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                            Text("Audio Only Mode")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Text output is disabled to save costs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - Message Row
    @ViewBuilder
    private func MessageRow(msg: ConversationItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: msg.roleSymbol)
                .foregroundColor(msg.roleColor)
                .padding(.top, 4)
            Text(msg.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.1), value: msg.text)
        }
        .contextMenu {
            Button("Copy") {
                UIPasteboard.general.string = msg.text
            }
        }
        .padding(.bottom, msg.role == "assistant" ? 24 : 8)
    }
    
    // MARK: - Message Input
    @ViewBuilder
    private func MessageInputView() -> some View {
        HStack {
            TextField("Insert message...", text: $webrtcManager.outgoingMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
            Button("Send") {
                webrtcManager.sendMessage()
                isTextFieldFocused = false
            }
            .disabled(webrtcManager.connectionStatus != .connected)
            .buttonStyle(.bordered)
        }
        .padding([.horizontal, .bottom])
    }
}

struct OptionsView: View {
    @Binding var apiKey: String
    @Binding var humeApiKey: String
    @Binding var humeSecretKey: String
    @Binding var systemMessage: String
    @Binding var selectedModel: String
    @Binding var selectedVoice: String
    @Binding var selectedProviderRaw: String
    @Binding var showTextOutput: Bool
    @Binding var customMcpEnabled: Bool
    @Binding var customMcpServerUrl: String
    @Binding var customMcpServerLabel: String
    @Binding var customMcpAuthToken: String
    
    let modelOptions: [String]
    let voiceOptions: [String]
    
    // Check if current model supports vision
    private var currentModelSupportsVision: Bool {
        return selectedModel.contains("realtime") && !selectedModel.contains("4o")
    }
    
    // Check if current model is a realtime model
    private var isRealtimeModel: Bool {
        return selectedModel.contains("realtime")
    }
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Voice Provider")) {
                    Picker("Provider", selection: $selectedProviderRaw) {
                        ForEach(WebRTCManager.VoiceProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                if selectedProviderRaw == WebRTCManager.VoiceProvider.hume.rawValue {
                   Section(header: Text("Hume AI Configuration")) {
                       TextField("Enter Hume API Key", text: $humeApiKey)
                           .autocapitalization(.none)
                       
                       SecureField("Enter Hume Secret Key", text: $humeSecretKey)
                           .autocapitalization(.none)
                       
                       Text("The Secret Key is used to generate a secure access token.")
                           .font(.caption)
                           .foregroundColor(.secondary)
                   }
                }
                
                if selectedProviderRaw == WebRTCManager.VoiceProvider.openAI.rawValue {
                    Section(header: Text("OpenAI API Key")) {
                        TextField("Enter OpenAI API Key", text: $apiKey)
                            .autocapitalization(.none)
                    }
                    
                    Section(header: Text("Model")) {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(modelOptions, id: \.self) { model in
                                HStack {
                                    Text(model)
                                    Spacer()
                                    if model.contains("realtime") && !model.contains("4o") {
                                        Image(systemName: "eye.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                    } else if model.contains("realtime") {
                                        Image(systemName: "eye.slash.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                    } else {
                                        Image(systemName: "eye.slash.fill")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        
                        // Vision capability info
                        if !currentModelSupportsVision {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.orange)
                                Text("This model doesn't support video/vision. Video features will be disabled.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        
                        if !isRealtimeModel {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("This model is not yet supported. Please use a realtime model (gpt-realtime) for now.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    
                    Section(header: Text("Voice")) {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(voiceOptions, id: \.self) { voice in
                                Text(voice.capitalized)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                Section(header: Text("System Message")) {
                    TextEditor(text: $systemMessage)
                        .frame(minHeight: 100)
                        .cornerRadius(5)
                }
                
                Section(header: Text("Custom MCP Server")) {
                    Toggle("Enable Custom MCP Server", isOn: $customMcpEnabled)
                    
                    if customMcpEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server Label (e.g. bluebubbles)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("server_label", text: $customMcpServerLabel)
                                .autocapitalization(.none)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL (SSE Endpoint)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("https://example.com/sse", text: $customMcpServerUrl)
                                .autocapitalization(.none)
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Auth Token (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Bearer token or API key", text: $customMcpAuthToken)
                                .autocapitalization(.none)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Text("Note: Your custom MCP server will be added alongside the built-in Zapier integration.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                
                Section(header: Text("Preferences")) {
                    Toggle("Show Text Transcript", isOn: $showTextOutput)
                    Text("Disable text output to save API costs. Audio will still work.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Options")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Models and Enums

struct ConversationItem: Identifiable {
    let id: String       // item_id from the JSON
    let role: String     // "user" / "assistant"
    var text: String     // transcript
    
    var roleSymbol: String {
        role.lowercased() == "user" ? "person.fill" : "sparkles"
    }
    
    var roleColor: Color {
        role.lowercased() == "user" ? .blue : .purple
    }
}

enum ConnectionStatus: String {
    case connected
    case connecting
    case disconnected
    
    var color: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }
    
    var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Not Connected"
        }
    }
}

// MARK: - Video Preview View
struct VideoPreviewView: UIViewRepresentable {
    let webrtcManager: WebRTCManager
    
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = UIColor.black
        containerView.layer.cornerRadius = 12
        containerView.clipsToBounds = true
        
        // Add a loading indicator
        let loadingLabel = UILabel()
        loadingLabel.text = "📹 Starting Camera..."
        loadingLabel.textColor = .white
        loadingLabel.font = UIFont.systemFont(ofSize: 12)
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 0
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(loadingLabel)
        
        NSLayoutConstraint.activate([
            loadingLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Always try to get the latest preview layer
        DispatchQueue.main.async {
            // Remove any existing preview layers
            uiView.layer.sublayers?.removeAll { $0 is AVCaptureVideoPreviewLayer }
            
            // Add new preview layer if available
            if let previewLayer = webrtcManager.getPreviewLayer() {
                previewLayer.frame = uiView.bounds
                previewLayer.videoGravity = .resizeAspectFill
                uiView.layer.insertSublayer(previewLayer, at: 0)
                
                // Hide loading label when camera feed is ready
                uiView.subviews.forEach { view in
                    if let label = view as? UILabel {
                        label.isHidden = true
                    }
                }
                
                print("📹 ✅ Live camera preview active")
            } else {
                // Show loading label when no preview available
                uiView.subviews.forEach { view in
                    if let label = view as? UILabel {
                        label.isHidden = false
                    }
                }
                
                // Keep trying to get the preview layer
                if webrtcManager.isVideoEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Trigger another UI update
                        if let _ = webrtcManager.getPreviewLayer() {
                            // Force SwiftUI to call updateUIView again
                            webrtcManager.objectWillChange.send()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
