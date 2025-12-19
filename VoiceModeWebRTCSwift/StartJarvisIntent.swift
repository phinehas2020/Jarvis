import AppIntents
import SwiftUI

struct StartJarvisIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Jarvis"
    static var description = IntentDescription("Starts a new Jarvis session.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // AppIntents in Live Activities run in the main app process.
        // We use NotificationCenter to avoid the Widget target needing a dependency on WebRTCManager.
        NotificationCenter.default.post(name: .startJarvisFromIntent, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let startJarvisFromIntent = Notification.Name("startJarvisFromIntent")
}
