import AppIntents
import SwiftUI

struct StartConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Conversation"
    static var description = IntentDescription("Starts a conversation with Jarvis.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // This is where you would put the logic to open the app and start the conversation.
        // Since we can't directly control the UI from here, we will use a notification
        // to signal the main app to start the connection.
        NotificationCenter.default.post(name: .startConversation, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let startConversation = Notification.Name("startConversation")
}
