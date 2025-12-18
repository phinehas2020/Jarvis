import AppIntents
import SwiftUI

struct StartJarvisIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Jarvis"
    static var description = IntentDescription("Starts a new Jarvis session.")

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .startJarvisFromIntent, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let startJarvisFromIntent = Notification.Name("startJarvisFromIntent")
}
