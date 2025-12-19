import SwiftUI
import AVFoundation

let API_KEY = "your_openai_api_key"

struct ContentView: View {
    @StateObject private var webrtcManager = WebRTCManager.shared
    
    @State private var showOptionsSheet = false
    @FocusState private var isTextFieldFocused: Bool
    
    // Camera preview drag state
    @State private var cameraOffset = CGSize.zero
    @State private var isDragging = false
    
    // AppStorage properties
    @AppStorage("apiKey") private var apiKey = API_KEY
    @AppStorage("xaiApiKey") private var xaiApiKey = ""
    @AppStorage("geminiApiKey") private var geminiApiKey = ""
    // gemini-2.5-flash-native-audio-preview-12-2025 is the GA native audio model for Live API voice conversations
    @AppStorage("geminiModel") private var geminiModel = "gemini-2.5-flash-native-audio-preview-12-2025"
    @AppStorage("didMigrateGeminiModelDefault") private var didMigrateGeminiModelDefault = false
    @AppStorage("didMigrateGeminiModelDefaultV2") private var didMigrateGeminiModelDefaultV2 = false
    @AppStorage("didMigrateGeminiModelDefaultV3") private var didMigrateGeminiModelDefaultV3 = false
    @AppStorage("didMigrateGeminiModelDefaultV4") private var didMigrateGeminiModelDefaultV4 = false
    @AppStorage("didMigrateGeminiModelDefaultV5") private var didMigrateGeminiModelDefaultV5 = false
    @AppStorage("geminiLiveEndpoint") private var geminiLiveEndpoint = ""
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
            This uses a high-performance model (grok-4-1-fast-non-reasoning by default) for high-quality text generation without spending realtime tokens.
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

    private func migrateGeminiModelIfNeeded() {
        // Migration V1: 2.0-flash-exp -> 2.5-flash-09-2025
        if !didMigrateGeminiModelDefault {
            didMigrateGeminiModelDefault = true
            let trimmed = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyModels = Set([
                "models/gemini-2.0-flash-exp",
                "gemini-2.0-flash-exp"
            ])
            if legacyModels.contains(trimmed) {
                geminiModel = "gemini-2.5-flash-native-audio-preview-09-2025"
            }
        }

        // Migration V2: (legacy - already ran for existing users)
        if !didMigrateGeminiModelDefaultV2 {
            didMigrateGeminiModelDefaultV2 = true
        }

        // Migration V3: (legacy)
        if !didMigrateGeminiModelDefaultV3 {
            didMigrateGeminiModelDefaultV3 = true
        }

        // Migration V4: (legacy - superseded by V5)
        if !didMigrateGeminiModelDefaultV4 {
            didMigrateGeminiModelDefaultV4 = true
        }

        // Migration V5: Upgrade to Gemini 2.5 Flash Native Audio (latest model for Live API)
        if !didMigrateGeminiModelDefaultV5 {
            didMigrateGeminiModelDefaultV5 = true
            let trimmed = geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // Migrate from older models to the latest native audio model
            let oldModels = Set([
                "gemini-2.0-flash-exp",
                "models/gemini-2.0-flash-exp",
                "gemini-2.5-flash-native-audio-preview-09-2025"
            ])
            if oldModels.contains(trimmed) || trimmed.contains("native-audio-preview") {
                geminiModel = "gemini-2.5-flash-native-audio-preview-12-2025"
                print("🔄 Migrated model to gemini-2.5-flash-native-audio-preview-12-2025 (latest Live API model)")
            }
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
        "get_recent_messages",
        "send_tapback",
        "rename_group",
        "mark_chat_read",
        "get_handles",
        "execute_task",
        "get_status"
    ]
    
    // MARK: - Design System
    private let jarvisPurple = Color(red: 0.5, green: 0.3, blue: 0.9)
    private let jarvisBlue = Color(red: 0.1, green: 0.4, blue: 0.9)
    private let jarvisGreen = Color(red: 0.2, green: 0.8, blue: 0.5)
    private let glassBackground = Color.primary.opacity(0.05)
    private let cornerRadius: CGFloat = 16
    
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
                VStack(spacing: 20) {
                    HeaderView()
                    ConnectionControls()
                    
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
            migrateGeminiModelIfNeeded()
            requestMicrophonePermission()
            webrtcManager.requestCalendarPermission()
        }
        .sheet(isPresented: $showOptionsSheet) {
            OptionsView(
                apiKey: $apiKey,
                geminiApiKey: $geminiApiKey,
                xaiApiKey: $xaiApiKey,
                geminiModel: $geminiModel,
                geminiLiveEndpoint: $geminiLiveEndpoint,
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
                provider: selectedProvider,
                modelName: selectedModel,
                systemMessage: systemMessage,
                voice: selectedVoice,
                geminiApiKey: geminiApiKey,
                geminiModel: geminiModel,
                geminiLiveEndpoint: geminiLiveEndpoint,
                xaiApiKey: xaiApiKey
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
        
        if selectedProvider == .openAI, apiKey.isEmpty {
            showOptionsSheet = true
        } else if selectedProvider == .gemini, geminiApiKey.isEmpty {
            showOptionsSheet = true
        }
    }
    
    @ViewBuilder
    private func HeaderView() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jarvis")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                HStack(spacing: 6) {
                    Circle()
                        .frame(width: 8, height: 8)
                        .foregroundColor(webrtcManager.connectionStatus.color)
                        .shadow(color: webrtcManager.connectionStatus.color.opacity(0.5), radius: 4)
                    Text(webrtcManager.connectionStatus.description)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button {
                showOptionsSheet.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(glassBackground)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
    
    @ViewBuilder
    private func ConnectionControls() -> some View {
        VStack(spacing: 16) {
            if webrtcManager.connectionStatus == .connected {
                HStack(spacing: 12) {
                    // Media Control Group
                    HStack(spacing: 0) {
                        MediaControlButton(
                            icon: webrtcManager.isMicMuted ? "mic.slash.fill" : "mic.fill",
                            label: "Mic",
                            color: webrtcManager.isMicMuted ? .red : jarvisBlue,
                            action: webrtcManager.toggleMute
                        )
                        
                        Divider().frame(height: 24).padding(.horizontal, 8)
                        
                        MediaControlButton(
                            icon: "speaker.wave.3.fill",
                            label: "Speaker",
                            color: .orange,
                            action: webrtcManager.forceAudioToSpeaker
                        )
                        
                        Divider().frame(height: 24).padding(.horizontal, 8)
                        
                        MediaControlButton(
                            icon: webrtcManager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                            label: "Video",
                            color: currentModelSupportsVision ? (webrtcManager.isVideoEnabled ? jarvisPurple : .secondary) : .gray.opacity(0.5),
                            action: webrtcManager.toggleVideo
                        )
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(glassBackground)
                    .cornerRadius(12)
                    
                    Spacer()
                    
                    // Waveform
                    WaveformView(
                        amplitudes: webrtcManager.waveformGenerator.amplitudes,
                        isActive: !webrtcManager.isMicMuted,
                        accentColor: webrtcManager.isMicMuted ? .red : jarvisBlue,
                        barCount: 10
                    )
                    .frame(width: 60, height: 32)
                    
                    Spacer()
                    
                    // Stop Button
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webrtcManager.stopConnection()
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red)
                            .clipShape(Circle())
                            .shadow(color: Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                // Start Connection Button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    startConnectionFlow()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                        Text(isRealtimeModel ? "Start Jarvis" : "Chat with Jarvis")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [jarvisBlue, jarvisPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                    .shadow(color: jarvisBlue.opacity(0.3), radius: 10, x: 0, y: 5)
                }
                .disabled(webrtcManager.connectionStatus == .connecting)
                .opacity(webrtcManager.connectionStatus == .connecting ? 0.6 : 1.0)
                .overlay(
                    Group {
                        if webrtcManager.connectionStatus == .connecting {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: webrtcManager.connectionStatus)
    }
    
    @ViewBuilder
    private func MediaControlButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(width: 48)
        }
    }
    
    private func startConnectionFlow() {
        webrtcManager.connectionStatus = .connecting
        
        if isRealtimeModel {
            webrtcManager.clearMCPTools()
            
            if customMcpEnabled && !customMcpServerUrl.isEmpty && !customMcpServerLabel.isEmpty {
                let safeLabel = sanitizedServerLabel(customMcpServerLabel)
                webrtcManager.addMCPTool(
                    serverLabel: safeLabel,
                    serverUrl: customMcpServerUrl,
                    authorization: customMcpAuthToken.isEmpty ? nil : customMcpAuthToken,
                    requireApproval: "never",
                    expectedToolNames: bluebubblesToolNames
                )
            }
            
            webrtcManager.startConnection(
                apiKey: apiKey,
                provider: selectedProvider,
                modelName: selectedModel,
                systemMessage: systemMessage,
                voice: selectedVoice,
                geminiApiKey: geminiApiKey,
                geminiModel: geminiModel,
                geminiLiveEndpoint: geminiLiveEndpoint,
                xaiApiKey: xaiApiKey
            )
        } else {
            print("⚠️ Non-realtime models not yet implemented")
            webrtcManager.connectionStatus = .disconnected
        }
    }
    
    // MARK: - Conversation View
    @ViewBuilder
    private func ConversationView() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if !webrtcManager.eventTypeStr.isEmpty {
                    Text(webrtcManager.eventTypeStr)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(jarvisBlue.opacity(0.1))
                        .foregroundColor(jarvisBlue)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            
            if showTextOutput {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(webrtcManager.conversation.filter { $0.role == "user" || $0.role == "assistant" }) { msg in
                                MessageBubble(msg: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: webrtcManager.conversation.count) { _ in
                        if let lastId = webrtcManager.conversation.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                AudioOnlyPlaceholder()
            }
        }
    }
    
    @ViewBuilder
    private func AudioOnlyPlaceholder() -> some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(jarvisBlue.opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: "waveform")
                        .font(.system(size: 30))
                        .foregroundColor(jarvisBlue)
                }
                
                VStack(spacing: 4) {
                    Text("Audio Only Mode")
                        .font(.headline)
                    Text("Text output is disabled in settings")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }
    
    // MARK: - Message Row
    @ViewBuilder
    private func MessageBubble(msg: ConversationItem) -> some View {
        let isUser = msg.role.lowercased() == "user"
        
        HStack {
            if isUser { Spacer() }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !isUser {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundColor(jarvisPurple)
                    }
                    Text(isUser ? "You" : "Jarvis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                    if isUser {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12))
                            .foregroundColor(jarvisBlue)
                    }
                }
                .padding(.horizontal, 4)
                
                Text(msg.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 16))
                    .foregroundColor(isUser ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? 
                        LinearGradient(colors: [jarvisBlue, jarvisBlue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                        LinearGradient(colors: [glassBackground, glassBackground.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .cornerRadius(18, corners: isUser ? [.topLeft, .bottomLeft, .bottomRight] : [.topRight, .bottomLeft, .bottomRight])
                    .shadow(color: isUser ? jarvisBlue.opacity(0.2) : Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            }
            .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            
            if !isUser { Spacer() }
        }
        .contextMenu {
            Button("Copy") {
                UIPasteboard.general.string = msg.text
            }
        }
    }
    
    // MARK: - Message Input
    @ViewBuilder
    private func MessageInputView() -> some View {
        HStack(spacing: 12) {
            TextField("Message Jarvis...", text: $webrtcManager.outgoingMessage, axis: .vertical)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(glassBackground)
                .cornerRadius(20)
                .focused($isTextFieldFocused)
            
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                webrtcManager.sendMessage()
                isTextFieldFocused = false
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(webrtcManager.connectionStatus == .connected ? jarvisBlue : .secondary)
            }
            .disabled(webrtcManager.connectionStatus != .connected || webrtcManager.outgoingMessage.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}



struct OptionsView: View {
    @Binding var apiKey: String
    @Binding var geminiApiKey: String
    @Binding var xaiApiKey: String // Added
    @Binding var geminiModel: String
    @Binding var geminiLiveEndpoint: String
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
                
                if selectedProviderRaw == WebRTCManager.VoiceProvider.gemini.rawValue {
                    Section(header: Text("Gemini Configuration")) {
                        SecureField("Enter Gemini API Key", text: $geminiApiKey)
                            .autocapitalization(.none)

                        TextField("Model (e.g. gemini-2.5-flash-native-audio)", text: $geminiModel)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        TextField("Live WebSocket URL", text: $geminiLiveEndpoint)
                            .autocapitalization(.none)

                        Text("Tip: Use a Gemini native-audio model. Jarvis sends a response after you stop speaking (~0.5s silence).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if selectedProviderRaw == WebRTCManager.VoiceProvider.xai.rawValue {
                    Section(header: Text("xAI Configuration")) {
                        SecureField("Enter xAI API Key", text: $xaiApiKey)
                            .autocapitalization(.none)
                        
                        Text("Using model: grok-beta")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("Uses Grok Native Audio via WebSocket.")
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
                
                Section(header: HStack {
                    Text("System Message")
                    Spacer()
                    Button(action: {
                        systemMessage = ""
                    }) {
                        Text("Clear")
                            .font(.caption)
                    }
                }) {
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

// MARK: - Helper Extensions

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
