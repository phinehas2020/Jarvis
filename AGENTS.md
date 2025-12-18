# Jarvis - Capabilities & Tools Guide

This guide describes what Jarvis can do and the tools it uses to interact with your world.

## 🛠️ Native iOS Tools
These tools run directly on your iPhone.

| Tool | Description |
| :--- | :--- |
| `get_brightness` / `set_brightness` | Adjust screen brightness. |
| `get_volume` / `set_volume` | Adjust system volume. |
| `play_music` | Play songs, albums, or playlists. |
| `get_calendar_events` | Check your schedule for today or tomorrow. |
| `create_reminder` | Add items to your Reminders app. |
| `capture_photo` | Take a photo with the camera. |
| `screen_shot` | Capture your iPhone's current screen. |

## 🖥️ Mac Mini Bridge Tools (BlueBubbles)
These tools require the Mac Mini bridge to be online.

### iMessage Management
- **`send_imessage`**: Send clear, native iMessages. Use this for sending files or links.
- **`send_tapback`**: React to messages with Love, Like, Dislike, Laugh, or Emphasize.
- **`rename_group`**: Instantly change the name of any group chat.
- **`mark_chat_read`**: Clear your notifications by marking chats as read.
- **`fetch_messages`**: Search through your message history.

### Desktop Automation (The Computer Agent)
- **`execute_task`**: Jarvis's most powerful tool. You can ask him to:
  - "Organize my Downloads folder."
  - "Find that email about the flight and save it to a PDF."
  - "Check the price of Bitcoin every 5 minutes and text me if it drops."
  
> [!IMPORTANT]
> When `background: true` is set, Jarvis will perform the task silently and send you a notification (and an iMessage) when completed.

## 🧠 System Prompt
The "brain" of Jarvis lives in `VoiceModeWebRTCSwift/SystemPrompt.md`. This file tells Jarvis how to behave, what tone to use, and when to suggest background tasks.

## 🚀 Speed Secrets
For the best experience, Jarvis is configured by default with:
- `grok-4-1-fast-non-reasoning`: To ensure sub-second response times.
- `low` image detail: To speed up screen analysis.
- Concise thought patterns: To reduce audio latency.
