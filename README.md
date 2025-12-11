# Jarvis - AI Assistant with MCP

A voice-activated AI assistant iOS app powered by OpenAI's Realtime API with Model Context Protocol (MCP) integrations for device control and iMessage via BlueBubbles.

## Features

- **Voice Interaction**: Real-time voice conversations using WebRTC
- **Device Control**: Brightness, volume, haptics, screenshots
- **Media**: Apple Music control, playlists, photos, camera
- **Productivity**: Calendar events, reminders, notes, alarms, shortcuts
- **iMessage**: Send and receive messages via BlueBubbles MCP bridge

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Jarvis iOS    │◄───►│  OpenAI Realtime │◄───►│   MCP Servers   │
│      App        │     │       API        │     │  (BlueBubbles)  │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

## Requirements

- iOS 17.0+
- Xcode 15+
- OpenAI API key with Realtime API access
- Mac mini with BlueBubbles (for iMessage)

## Setup

1. Open `Jarvis with MCP.xcodeproj` in Xcode
2. Build and run on your iOS device
3. Configure your OpenAI API key in Settings
4. (Optional) Configure BlueBubbles MCP server URL for iMessage

## Project Structure

```
├── VoiceModeWebRTCSwift/
│   ├── ContentView.swift        # Main UI
│   ├── WebRTCManager.swift      # WebRTC/OpenAI connection
│   ├── SystemPrompt.md          # AI system instructions
│   └── Assets.xcassets/         # App icons and assets
├── Jarvis with MCP.xcodeproj/   # Xcode project
└── AGENTS.md                    # AI agent guidelines
```

## iMessage via BlueBubbles

The app supports iMessage through a BlueBubbles MCP bridge running on a Mac mini. See [AGENTS.md](AGENTS.md) for setup instructions.

## License

Private repository - all rights reserved.

