# Repository Guidelines

## Project Structure & Module Organization
- `VoiceModeWebRTCSwift/` contains the SwiftUI app. Key files: `ContentView.swift` (conversation UI), `WebRTCManager.swift` (Realtime/WebRTC engine), and `SystemPrompt.md` (default system messaging). Assets and previews live in `Assets.xcassets/` and `Preview Content/`.
- `VoiceModeWebRTCSwift.xcodeproj/` and `Jarvis with MCP.xcodeproj/` store Xcode project settings. Use the SwiftUI target `VoiceModeWebRTCSwiftApp` for runtime changes.

## Build, Test, and Development Commands
- `open VoiceModeWebRTCSwift.xcodeproj` launches the project in Xcode for iterative development.
- `xcodebuild -scheme VoiceModeWebRTCSwift -destination 'platform=iOS Simulator,name=iPhone 15' build` performs a CI-friendly build.
- `xcodebuild -scheme VoiceModeWebRTCSwift -destination 'platform=iOS Simulator,name=iPhone 15' test` runs XCTest targets when present.
- `swift package update` refreshes Swift Package Manager dependencies if WebRTC or other packages are bumped.

## Coding Style & Naming Conventions
- Swift source uses 4-space indentation and `lowerCamelCase` for properties/functions, `UpperCamelCase` for types.
- Prefer SwiftUI modifiers in logical blocks and keep view structs small—extract helper views under `VoiceModeWebRTCSwift/` as needed.
- Maintain `SystemPrompt.md` content in Markdown; keep prompts concise and version changes in commits.
- Run `xcodebuild -scheme VoiceModeWebRTCSwift build` before pushing to catch obvious lint or compile issues (SwiftLint is not currently configured).

## Testing Guidelines
- Add unit/UI tests under a `VoiceModeWebRTCSwiftTests/` target mirroring the source tree. Name files `<Feature>Tests.swift` and use descriptive `testShould...` methods.
- Favor dependency injection for `WebRTCManager` so audio/network behaviors can be mocked.
- Ensure new features include basic simulator coverage; attach simulator logs for regressions affecting AV or signaling.

## Commit & Pull Request Guidelines
- Follow the existing history: concise, present-tense summaries (e.g., `Add microphone access to Info.plist`).
- Group related Swift/UI updates into a single commit with a clear scope; include API key handling updates separately.
- PRs should list testing steps (build target, simulator/device), reference related issues, and add screenshots/GIFs for UI-affecting changes.
- Note any API key handling changes or new configuration requirements in the PR body to aid reviewers.

## Configuration & Security Tips
- Never commit real API keys; keep placeholders like `let API_KEY = "your_openai_api_key"` and rely on runtime input in `OptionsView`.
- Document new configurable values in `README.md` and, if persistent storage is added, mention reset steps for contributors.

## iMessage Bridge (BlueBubbles MCP)
- A dedicated Mac mini runs the BlueBubbles bridge plus a local MCP WebSocket server (`imessage-bridge`).  
- The bridge listens on `ws://<MacMiniLANIP>:9797/mcp` with bearer auth (`MCP_BEARER`). Set `MCP_HOST`, `MCP_PORT`, and `MCP_BEARER` in `/opt/imessage-bridge/.env` and restart via `pm2 restart imessage-bridge --update-env`.
- Tools exposed: `send_imessage`, `fetch_messages`, and `get_status`. All iMessage actions must use these; the Zapier tool is only kept for legacy reference.
- Test locally with `npm run test:mcp` (requires `MCP_TEST_BEARER`). The script attempts a send (expected to fail for the dummy number) and verifies message fetch.
- When configuring the iOS client, add a custom MCP server with the LAN URL and bearer token; the system prompt already instructs Jarvis to prefer this path.
