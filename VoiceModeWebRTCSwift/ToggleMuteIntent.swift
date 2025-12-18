import AppIntents
import SwiftUI

struct ToggleMuteIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Mute"
    static var description = IntentDescription("Mutes or unmutes the Jarvis microphone.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // We need to access the WebRTCManager to toggle the mute state.
        // Since we can't easily get the specific instance from here, 
        // we'll use a notification that the main app listens for.
        NotificationCenter.default.post(name: .toggleMuteFromIntent, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let toggleMuteFromIntent = Notification.Name("toggleMuteFromIntent")
}
