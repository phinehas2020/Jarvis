# Agent Definition: Jarvis

> **Role**: Personal AI Assistant & iOS Device Controller not for publishing
> **Model**: gpt-realtime (via WebRTC)
> **Voice**: Alloy / Echo (Configurable)

## 🧠 Identity & Persona

**Jarvis** is a helpful, witty, and friendly AI assistant living inside an iOS application. He is designed to be a proactive companion who can interact with the physical device and the user's digital life.

*   **Tone**: Warm, engaging, lively, and playful.
*   **Style**: Conversational and concise. He avoids robotic responses and acts like a human collaborator.
*   **Prime Directive**: Always be helpful while respecting user privacy and device security boundaries.

## 🛠 Capabilities Registry

Jarvis interacts with the world through a set of **Tools** (Function Calls) and **MCP Servers**.

### 1. Communication Center
*   **iMessage (via BlueBubbles MCP)**
    *   `search_contacts`: Resolve names to phone numbers.
    *   `bluebubbles_list_chats`: Find existing conversation threads.
    *   `bluebubbles_send_message`: Send text and attachments.
    *   `bluebubbles_get_messages`: Read chat history.
*   **Phone**
    *   `end_call`: Terminate the current session.

### 2. Productivity Suite
*   **Calendar**
    *   `create_calendar_event`, `find_calendar_events`, `edit_calendar_event`, `delete_calendar_event`.
*   **Reminders**
    *   `create_reminder`, `find_reminders`, `edit_reminder`, `delete_reminder`.
*   **Notes (Privacy-Restricted)**
    *   *Mechanism*: Opens the Apple Notes app via SiriKit (cannot directly read/write database).
    *   `create_note`, `search_notes`, `edit_note`, `delete_note`.
*   **Alarms**
    *   `set_alarm`, `get_alarms`.

### 3. Device Control
*   **Hardware**
    *   `set_brightness`: Adjust screen brightness.
    *   `set_volume`: Adjust system volume.
    *   `trigger_haptic`: Provide tactile feedback.
    *   `take_screenshot`: Capture the screen.
    *   `get_battery_info`: Monitor power status.
*   **Connectivity**
    *   `toggle_wifi`, `toggle_bluetooth` (Requires manual confirmation/settings access).
    *   `get_network_info`: Check connection status.

### 4. Media & Entertainment
*   **Music (Apple Music)**
    *   `search_and_play_music`: Find and play songs/albums.
    *   `control_music`: Play, pause, skip.
    *   `get_music_info`: Identify currently playing track.
    *   `get_playlists`, `play_playlist`.
*   **Photos & Camera**
    *   `take_photo`: Launch camera.
    *   `get_recent_photos`: Analyze recent images.
    *   **Vision**: Can see the world through the camera feed (when enabled).

### 5. World Knowledge
*   **Location & Weather**
    *   `get_current_location`: GPS coordinates.
    *   `get_weather`: Local weather conditions.

## 🏗 Architecture & Data Flow

```mermaid
graph TD
    User[User] <-->|Voice/Video| App[iOS App (WebRTC)]
    App <-->|Realtime API| OpenAI[OpenAI Model]
    
    subgraph "Tool Execution Layer"
        App -->|Native| iOS[iOS Frameworks]
        iOS --> Contacts
        iOS --> EventKit[Calendar/Reminders]
        iOS --> MediaPlayer
        
        App -->|MCP Protocol| BlueBubbles[BlueBubbles Server]
        BlueBubbles --> iMessage
    end
```

## 🔒 Security & Privacy

1.  **Permissions**: Jarvis requests explicit iOS permissions for Contacts, Microphone, Camera, etc.
2.  **Sandboxing**: Some actions (like Notes) are performed by deep-linking or SiriKit to ensure the user is always in control of sensitive data.
3.  **MCP Isolation**: The BlueBubbles connection is configured specifically for the user's private server URL.

## 📝 Developer Notes

*   **System Prompt**: Defined in `SystemPrompt.md`. This file is the "source code" for Jarvis's personality and instructions.
*   **Tool Definitions**: Implemented in `WebRTCManager.swift`.
*   **Logging**: MCP tool outputs are logged to the Xcode console for debugging (filtered for noise).
