import AppIntents
import SwiftUI

struct ToggleMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Mute"
    static var description = IntentDescription("Mutes or unmutes the Jarvis microphone.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // AppIntents in Live Activities run in the main app process.
        // We use NotificationCenter to avoid the Widget target needing a dependency on WebRTCManager.
        NotificationCenter.default.post(name: .toggleMuteFromIntent, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let toggleMuteFromIntent = Notification.Name("toggleMuteFromIntent")
}
