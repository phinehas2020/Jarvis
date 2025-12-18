import Foundation
import UIKit
import Contacts
import EventKit
import MediaPlayer

/// Centralized manager for executing AI-driven tools and functions.
/// This decouples tool logic from WebRTC handling.
class ToolManager {
    static let shared = ToolManager()
    
    // Dependencies
    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()
    
    private init() {}
    
    // MARK: - Local Tools Registry
    
    /// Returns the list of available local tools for the AI model.
    func getLocalToolsDefinitions() -> [[String: Any]] {
        return [
            [
                "name": "search_contacts",
                "description": "Search for contacts by name or phone number",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Name or part of a name to search for"],
                        "limit": ["type": "integer", "description": "Max results to return", "default": 20]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "set_brightness",
                "description": "Set the screen brightness level (0.0 to 1.0)",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "level": ["type": "number", "description": "Brightness level between 0.0 and 1.0"]
                    ],
                    "required": ["level"]
                ]
            ],
            [
                "name": "set_volume",
                "description": "Set the system volume level (0.0 to 1.0)",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "level": ["type": "number", "description": "Volume level between 0.0 and 1.0"]
                    ],
                    "required": ["level"]
                ]
            ],
            [
                "name": "create_note",
                "description": "Create a new note in the Notes app",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Title of the note"],
                        "content": ["type": "string", "description": "Body content of the note"]
                    ],
                    "required": ["title", "content"]
                ]
            ],
            [
                "name": "create_reminder",
                "description": "Create a new reminder",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Title of the reminder"],
                        "due_date": ["type": "string", "description": "Optional due date/time as a string (e.g. 'tomorrow at 10am')"]
                    ],
                    "required": ["title"]
                ]
            ]
        ]
    }
    
    // MARK: - Tool Implementation: Contacts
    
    func searchContacts(query: String, limit: Int = 20) -> [[String: String]] {
        let keysToFetch = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ] as [CNKeyDescriptor]
        
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var results: [[String: String]] = []
        
        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                if fullName.lowercased().contains(query.lowercased()) {
                    var dict = ["name": fullName]
                    if let firstPhone = contact.phoneNumbers.first?.value.stringValue {
                        dict["phone"] = firstPhone
                    }
                    if let firstEmail = contact.emailAddresses.first?.value as String? {
                        dict["email"] = firstEmail
                    }
                    results.append(dict)
                }
                
                if results.count >= limit { return }
            }
        } catch {
            print("❌ Contact Search Error: \(error)")
        }
        
        return results
    }
    
    // MARK: - Tool Implementation: System Controls
    
    func setBrightness(to level: Float) -> [String: Any] {
        DispatchQueue.main.async {
            UIScreen.main.brightness = CGFloat(max(0, min(1, level)))
        }
        return ["status": "success", "new_level": level]
    }
    
    func setVolume(to level: Float) -> [String: Any] {
        DispatchQueue.main.async {
            let volumeView = MPVolumeView()
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = level
            }
        }
        return ["status": "success", "new_level": level]
    }
    
    // MARK: - Tool Implementation: Events & Reminders
    
    func createReminder(title: String, dueDate: Date? = nil) async -> [String: Any] {
        do {
            let granted = try await eventStore.requestAccess(to: .reminder)
            guard granted else { return ["error": "Permission denied for Reminders"] }
            
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = title
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
            
            if let date = dueDate {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.dueDateComponents = components
            }
            
            try eventStore.save(reminder, commit: true)
            return ["status": "success", "title": title]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
    
    // MARK: - Tool Implementation: Notes (via URL Scheme)
    
    func createNote(title: String, content: String) -> [String: Any] {
        // iOS doesn't have a direct private Notes API, but we can open the app or use ActivityViewController
        // For a seamless "Jarvis" feel, we can try to use AppleScript (on macOS) or Shortcuts.
        // On iOS, we'll use a URL scheme if possible, or simple confirmation.
        print("📝 Jarvis: Creating note '\(title)': \(content)")
        
        // Practical fallback: Just store it or use a URL scheme to open Notes
        // mobilenotes://create?title=...&content=...
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "mobilenotes://create?title=\(encodedTitle)&body=\(encodedBody)"
        
        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
            return ["status": "success", "action": "Opened Notes app to create note"]
        }
        
        return ["status": "failed", "error": "Could not open Notes app"]
    }
}
