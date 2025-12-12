import Foundation
import WebRTC
import AVFoundation
import UIKit
import CoreImage
import Contacts
import EventKit
import CoreLocation
import MediaPlayer
import Photos
import SystemConfiguration
import CoreTelephony
import Intents
import UserNotifications
import IntentsUI

// MARK: - WebRTCManager
class WebRTCManager: NSObject, ObservableObject {
    // UI State
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var eventTypeStr: String = ""
    @Published var isMicMuted: Bool = false
    @Published var isVideoEnabled: Bool = false
    @Published var isCameraOn: Bool = false
    @Published var isUsingFrontCamera: Bool = true
    
    // Basic conversation text
    @Published var conversation: [ConversationItem] = []
    @Published var outgoingMessage: String = ""
    
    // We'll store items by item_id for easy updates
    private var conversationMap: [String : ConversationItem] = [:]
    private var awaitingToolResponse = false
    
    // Model & session config
    private var modelName: String = "gpt-4o-mini-realtime-preview-2024-12-17"
    private var systemInstructions: String = ""
    private var voice: String = "alloy"
    private var currentApiKey: String = ""
    
    // MCP Tools configuration
    private var mcpTools: [[String: Any]] = []
    private var mcpExpectedToolNames: Set<String> = []
    private let localToolNames: Set<String> = [
        "search_contacts",
        "create_calendar_event",
        "delete_calendar_event",
        "edit_calendar_event",
        "find_calendar_events",
        "create_reminder",
        "delete_reminder",
        "edit_reminder",
        "find_reminders",
        "get_device_info",
        "get_battery_info",
        "get_storage_info",
        "get_network_info",
        "set_brightness",
        "set_volume",
        "trigger_haptic",
        "take_screenshot",
        "get_music_info",
        "control_music",
        "search_and_play_music",
        "end_call",
        "delegate_to_gpt4o",
        "toggle_wifi",
        "toggle_bluetooth",
        "set_do_not_disturb",
        "set_alarm",
        "get_alarms",
        "take_photo",
        "get_recent_photos",
        "get_current_location",
        "get_weather",
        "get_playlists",
        "play_playlist",
        "toggle_shuffle",
        "toggle_repeat",
        "create_note",
        "search_notes",
        "edit_note",
        "delete_note",
        "get_all_notes",
        "run_shortcut"
    ]
    
    // Voice Provider Configuration
    enum VoiceProvider: String, CaseIterable, Identifiable {
        case openAI = "OpenAI Realtime"
        case hume = "Hume AI (EVI)"
        
        var id: String { self.rawValue }
    }
    
    @Published var currentProvider: VoiceProvider = .openAI
    private var humeApiKey: String = ""
    private var humeSecretKey: String = ""
    private var humeClient: HumeClient?
    
    // WebRTC references
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    
    // Camera setup
    private var cameraSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentCameraInput: AVCaptureDeviceInput?
    
    // MARK: - Public Methods
    
    /// Configure MCP tools for the session
    func configureMCPTools(_ tools: [[String: Any]]) {
        mcpTools = tools
    }
    
    /// Clear all MCP tools
    func clearMCPTools() {
        mcpTools.removeAll()
        print("🔧 Cleared all MCP tools")
    }
    
    /// Add a single MCP tool
    func addMCPTool(
        serverLabel: String,
        serverUrl: String,
        authorization: String? = nil,
        requireApproval: String = "never",
        expectedToolNames: [String]? = nil
    ) {
        var tool: [String: Any] = [
            "type": "mcp",
            "server_label": serverLabel,
            "server_url": serverUrl,
            "require_approval": requireApproval
        ]
        
        if let auth = authorization {
            tool["authorization"] = auth
        }
        
        mcpTools.append(tool)
        print("🔧 Added MCP tool: \(serverLabel) at \(serverUrl)")
        
        if let toolNames = expectedToolNames, !toolNames.isEmpty {
            mcpExpectedToolNames.formUnion(toolNames)
            print("📋 \(serverLabel) advertised MCP tools:")
            for name in toolNames {
                print("   • \(name)")
            }
        }
    }
    
    // MARK: - Audio/Video Controls
    
    /// Toggle microphone mute/unmute
    func toggleMute() {
        isMicMuted.toggle()
        audioTrack?.isEnabled = !isMicMuted
        print("🎤 Microphone \(isMicMuted ? "muted" : "unmuted")")
    }
    
    /// Toggle video on/off
    func toggleVideo() {
        isVideoEnabled.toggle()
        if isVideoEnabled {
            isCameraOn = true
            startVideo()
        } else {
            isCameraOn = false
            stopVideo()
        }
        print("📹 Video \(isVideoEnabled ? "enabled" : "disabled")")
    }
    
    /// Toggle camera on/off (separate from rotate)
    func toggleCamera() {
        isCameraOn.toggle()
        if isCameraOn && isVideoEnabled {
            startVideo()
        } else {
            pauseCamera()
        }
        print("📹 Camera \(isCameraOn ? "on" : "off")")
    }
    
    /// Pause camera (black screen) without disabling video completely
    private func pauseCamera() {
        cameraSession?.stopRunning()
        print("📹 Camera paused (black screen)")
    }
    
    /// Force audio to main speaker (loudspeaker)
    func forceAudioToSpeaker() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.overrideOutputAudioPort(.speaker)
            print("🔊 Audio forced to main speaker")
        } catch {
            print("❌ Failed to force audio to speaker: \(error)")
        }
    }
    
    /// Configure app for background operation
    func enableBackgroundMode() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Enable background audio processing
            try audioSession.setCategory(.playAndRecord, options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ])
            
            try audioSession.setActive(true)
            print("🌟 Background mode enabled - app can run while backgrounded")
            
        } catch {
            print("❌ Failed to enable background mode: \(error)")
        }
    }
    
    // MARK: - Calendar Integration
    
    private let eventStore = EKEventStore()
    
    func requestCalendarPermission() {
        eventStore.requestAccess(to: .event) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("🗓️ Calendar permission granted")
                } else {
                    print("❌ Calendar permission denied: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
        
        eventStore.requestAccess(to: .reminder) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("🔔 Reminders permission granted")
                } else {
                    print("❌ Reminders permission denied: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
    
    func createCalendarEvent(title: String, startDate: Date, endDate: Date) -> [String: Any] {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents
        
        do {
            try eventStore.save(event, span: .thisEvent)
            print("🗓️ Event created successfully: \(title)")
            let eventId = event.eventIdentifier ?? UUID().uuidString
            return ["status": "success", "event_id": eventId]
        } catch {
            print("❌ Failed to save event: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    func deleteCalendarEvent(eventId: String) -> [String: Any] {
        guard let event = eventStore.event(withIdentifier: eventId) else {
            return ["status": "error", "message": "Event not found"]
        }
        
        do {
            try eventStore.remove(event, span: .thisEvent)
            print("🗓️ Event deleted successfully: \(eventId)")
            return ["status": "success"]
        } catch {
            print("❌ Failed to delete event: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    func editCalendarEvent(eventId: String, newTitle: String?, newStartDate: Date?, newEndDate: Date?) -> [String: Any] {
        guard let event = eventStore.event(withIdentifier: eventId) else {
            return ["status": "error", "message": "Event not found"]
        }
        
        if let newTitle = newTitle {
            event.title = newTitle
        }
        if let newStartDate = newStartDate {
            event.startDate = newStartDate
        }
        if let newEndDate = newEndDate {
            event.endDate = newEndDate
        }
        
        do {
            try eventStore.save(event, span: .thisEvent)
            print("🗓️ Event edited successfully: \(eventId)")
            let eventId = event.eventIdentifier ?? UUID().uuidString
            return ["status": "success", "event_id": eventId]
        } catch {
            print("❌ Failed to edit event: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }

    func findCalendarEvents(title: String?, startDate: Date?, endDate: Date?) -> [[String: Any]] {
        let calendars = eventStore.calendars(for: .event)
        let predicate: NSPredicate
        if let startDate = startDate, let endDate = endDate {
            let startOfDay = Calendar.current.startOfDay(for: startDate)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate))!
            predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: calendars)
        } else {
            // If no dates are provided, search for events in the next year
            let now = Date()
            let nextYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
            predicate = eventStore.predicateForEvents(withStart: now, end: nextYear, calendars: calendars)
        }
        
        let events = eventStore.events(matching: predicate)
        var foundEvents: [[String: Any]] = []
        
        for event in events {
            let eventId = event.eventIdentifier ?? UUID().uuidString
            let eventTitle = event.title ?? "Untitled Event"
            
            if let title = title {
                if eventTitle.lowercased().contains(title.lowercased()) {
                    foundEvents.append([
                        "event_id": eventId,
                        "title": eventTitle,
                        "start_time": event.startDate.ISO8601Format(),
                        "end_time": event.endDate.ISO8601Format()
                    ])
                }
            } else {
                foundEvents.append([
                    "event_id": eventId,
                    "title": eventTitle,
                    "start_time": event.startDate.ISO8601Format(),
                    "end_time": event.endDate.ISO8601Format()
                ])
            }
        }
        
        return foundEvents
    }
    
    // MARK: - Reminders Integration
    
    func createReminder(title: String, dueDate: Date?, notes: String? = nil) -> [String: Any] {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        
        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }
        
        do {
            try eventStore.save(reminder, commit: true)
            print("🔔 Reminder created successfully: \(title)")
            let reminderId = reminder.calendarItemIdentifier ?? UUID().uuidString
            return ["status": "success", "reminder_id": reminderId]
        } catch {
            print("❌ Failed to save reminder: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    func deleteReminder(reminderId: String) -> [String: Any] {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return ["status": "error", "message": "Reminder not found"]
        }
        
        do {
            try eventStore.remove(reminder, commit: true)
            print("🔔 Reminder deleted successfully: \(reminderId)")
            return ["status": "success"]
        } catch {
            print("❌ Failed to delete reminder: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    func editReminder(reminderId: String, newTitle: String?, newDueDate: Date?, newNotes: String?) -> [String: Any] {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return ["status": "error", "message": "Reminder not found"]
        }
        
        if let newTitle = newTitle {
            reminder.title = newTitle
        }
        if let newDueDate = newDueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: newDueDate)
        }
        if let newNotes = newNotes {
            reminder.notes = newNotes
        }
        
        do {
            try eventStore.save(reminder, commit: true)
            print("🔔 Reminder edited successfully: \(reminderId)")
            let updatedReminderId = reminder.calendarItemIdentifier ?? reminderId
            return ["status": "success", "reminder_id": updatedReminderId]
        } catch {
            print("❌ Failed to edit reminder: \(error)")
            return ["status": "error", "message": error.localizedDescription]
        }
    }
    
    func findReminders(title: String?, dueDate: Date?, completed: Bool? = nil) -> [[String: Any]] {
        let predicate = eventStore.predicateForReminders(in: nil)
        var foundReminders: [[String: Any]] = []
        
        // Use a semaphore to make this synchronous since we need to return the results
        let semaphore = DispatchSemaphore(value: 0)
        
        eventStore.fetchReminders(matching: predicate) { reminders in
            guard let reminders = reminders else {
                semaphore.signal()
                return
            }
            
            for reminder in reminders {
                let reminderId = reminder.calendarItemIdentifier ?? UUID().uuidString
                let reminderTitleValue = reminder.title ?? ""
                // Filter by completion status if specified
                if let completed = completed, reminder.isCompleted != completed {
                    continue
                }
                
                // Filter by title if specified
                if let title = title {
                    if !reminderTitleValue.lowercased().contains(title.lowercased()) {
                        continue
                    }
                }
                
                // Filter by due date if specified
                if let dueDate = dueDate {
                    if let reminderDueDate = reminder.dueDateComponents?.date {
                        let calendar = Calendar.current
                        if !calendar.isDate(reminderDueDate, inSameDayAs: dueDate) {
                            continue
                        }
                    } else {
                        continue // Skip reminders without due dates if filtering by date
                    }
                }
                
                let reminderTitle = reminderTitleValue.isEmpty ? "Untitled Reminder" : reminderTitleValue
                
                var reminderDict: [String: Any] = [
                    "reminder_id": reminderId,
                    "title": reminderTitle,
                    "completed": reminder.isCompleted
                ]
                
                if let dueDateComponents = reminder.dueDateComponents,
                   let dueDate = dueDateComponents.date {
                    reminderDict["due_date"] = dueDate.ISO8601Format()
                }
                
                if let notes = reminder.notes {
                    reminderDict["notes"] = notes
                }
                
                foundReminders.append(reminderDict)
            }
            
            semaphore.signal()
        }
        
        // Wait for the async operation to complete
        semaphore.wait()
        return foundReminders
    }
    
    // MARK: - Device Information Tools
    
    func getDeviceInfo() -> [String: Any] {
        let device = UIDevice.current
        let screen = UIScreen.main
        
        return [
            "device_name": device.name,
            "device_model": device.model,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "battery_level": device.batteryLevel,
            "battery_state": device.batteryState.rawValue,
            "screen_brightness": screen.brightness,
            "screen_scale": screen.scale,
            "screen_bounds": [
                "width": screen.bounds.width,
                "height": screen.bounds.height
            ],
            "orientation": device.orientation.rawValue,
            "multitasking_supported": device.isMultitaskingSupported
        ]
    }
    
    func getBatteryInfo() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        
        let batteryLevel = device.batteryLevel
        let batteryState = device.batteryState
        
        var stateString = "Unknown"
        switch batteryState {
        case .unplugged:
            stateString = "Unplugged"
        case .charging:
            stateString = "Charging"
        case .full:
            stateString = "Full"
        default:
            stateString = "Unknown"
        }
        
        return [
            "battery_level": batteryLevel,
            "battery_percentage": Int(batteryLevel * 100),
            "battery_state": stateString,
            "is_charging": batteryState == .charging || batteryState == .full
        ]
    }
    
    func getStorageInfo() -> [String: Any] {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: documentsPath.path)
            let totalSpace = attributes[.systemSize] as? NSNumber ?? 0
            let freeSpace = attributes[.systemFreeSize] as? NSNumber ?? 0
            let usedSpace = totalSpace.int64Value - freeSpace.int64Value
            
            return [
                "total_space_bytes": totalSpace.int64Value,
                "free_space_bytes": freeSpace.int64Value,
                "used_space_bytes": usedSpace,
                "total_space_gb": String(format: "%.2f", Double(totalSpace.int64Value) / 1_000_000_000),
                "free_space_gb": String(format: "%.2f", Double(freeSpace.int64Value) / 1_000_000_000),
                "used_space_gb": String(format: "%.2f", Double(usedSpace) / 1_000_000_000)
            ]
        } catch {
            return ["error": "Failed to get storage info: \(error.localizedDescription)"]
        }
    }
    
    func getNetworkInfo() -> [String: Any] {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)
        
        let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { zeroSockAddress in
                SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
            }
        }
        
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) {
            return ["error": "Failed to get network info"]
        }
        
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let isConnected = isReachable && !needsConnection
        
        return [
            "is_connected": isConnected,
            "is_reachable": isReachable,
            "needs_connection": needsConnection,
            "connection_type": isConnected ? "Connected" : "Disconnected"
        ]
    }
    
    // MARK: - System Control Tools
    
    func setBrightness(_ brightness: Float) -> [String: Any] {
        let clampedBrightness = max(0.0, min(1.0, brightness))
        DispatchQueue.main.async {
            UIScreen.main.brightness = CGFloat(clampedBrightness)
        }
        return [
            "status": "success",
            "brightness": clampedBrightness,
            "message": "Brightness set to \(Int(clampedBrightness * 100))%"
        ]
    }
    
    func setVolume(_ volume: Float) -> [String: Any] {
        let clampedVolume = max(0.0, min(1.0, volume))
        
        // Use MPVolumeView for volume control (this is the correct iOS way)
        let volumeView = MPVolumeView()
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            DispatchQueue.main.async {
                slider.value = clampedVolume
            }
            return [
                "status": "success",
                "volume": clampedVolume,
                "message": "Volume set to \(Int(clampedVolume * 100))%"
            ]
        } else {
            return [
                "status": "error",
                "message": "Unable to access volume control"
            ]
        }
    }
    
    func triggerHapticFeedback(_ style: String) -> [String: Any] {
        DispatchQueue.main.async {
            switch style.lowercased() {
            case "light":
                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()
            case "medium":
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
            case "heavy":
                let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
                impactFeedback.impactOccurred()
            case "success":
                let notificationFeedback = UINotificationFeedbackGenerator()
                notificationFeedback.notificationOccurred(.success)
            case "warning":
                let notificationFeedback = UINotificationFeedbackGenerator()
                notificationFeedback.notificationOccurred(.warning)
            case "error":
                let notificationFeedback = UINotificationFeedbackGenerator()
                notificationFeedback.notificationOccurred(.error)
            case "selection":
                let selectionFeedback = UISelectionFeedbackGenerator()
                selectionFeedback.selectionChanged()
            default:
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
            }
        }
        
        return [
            "status": "success",
            "haptic_style": style,
            "message": "Haptic feedback triggered with \(style) style"
        ]
    }
    
    func takeScreenshot() -> [String: Any] {
        DispatchQueue.main.async {
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = windowScene?.windows.first
            
            if let window = window {
                UIGraphicsBeginImageContextWithOptions(window.bounds.size, false, UIScreen.main.scale)
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                let image = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                
                if let image = image {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Screenshot taken and saved to Photos"
        ]
    }
    
    // MARK: - Media Control Tools
    
    func getMusicInfo() -> [String: Any] {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        
        if let nowPlayingItem = musicPlayer.nowPlayingItem {
            return [
                "is_playing": musicPlayer.playbackState == .playing,
                "title": nowPlayingItem.title ?? "Unknown",
                "artist": nowPlayingItem.artist ?? "Unknown",
                "album": nowPlayingItem.albumTitle ?? "Unknown",
                "playback_state": musicPlayer.playbackState.rawValue,
                "playback_state_description": getPlaybackStateDescription(musicPlayer.playbackState)
            ]
        } else {
            return [
                "is_playing": false,
                "message": "No music currently playing"
            ]
        }
    }
    
    private func getPlaybackStateDescription(_ state: MPMusicPlaybackState) -> String {
        switch state {
        case .stopped:
            return "Stopped"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .interrupted:
            return "Interrupted"
        case .seekingForward:
            return "Seeking Forward"
        case .seekingBackward:
            return "Seeking Backward"
        @unknown default:
            return "Unknown"
        }
    }
    
    func controlMusic(_ action: String) -> [String: Any] {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        
        switch action.lowercased() {
        case "play":
            musicPlayer.play()
            return ["status": "success", "action": "play", "message": "Music started playing"]
        case "pause":
            musicPlayer.pause()
            return ["status": "success", "action": "pause", "message": "Music paused"]
        case "stop":
            musicPlayer.stop()
            return ["status": "success", "action": "stop", "message": "Music stopped"]
        case "next":
            musicPlayer.skipToNextItem()
            return ["status": "success", "action": "next", "message": "Skipped to next track"]
        case "previous":
            musicPlayer.skipToPreviousItem()
            return ["status": "success", "action": "previous", "message": "Skipped to previous track"]
        default:
            return ["status": "error", "message": "Unknown music action: \(action)"]
        }
    }
    
    func searchAndPlayMusic(query: String, searchType: String = "all") -> [String: Any] {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        
        // Create a media query based on search type
        var mediaQuery: MPMediaQuery
        var uniqueItems: [MPMediaItem] = []
        
        switch searchType.lowercased() {
        case "artist":
            mediaQuery = MPMediaQuery.artists()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains))
        case "album":
            mediaQuery = MPMediaQuery.albums()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyAlbumTitle, comparisonType: .contains))
        case "song", "title":
            mediaQuery = MPMediaQuery.songs()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains))
        default: // "all"
            // For "all" search, we'll search across multiple fields by creating separate queries
            // and combining the results
            let titleQuery = MPMediaQuery.songs()
            titleQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains))
            
            let artistQuery = MPMediaQuery.songs()
            artistQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains))
            
            let albumQuery = MPMediaQuery.songs()
            albumQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyAlbumTitle, comparisonType: .contains))
            
            // Combine results from all three queries
            var allItems: [MPMediaItem] = []
            if let titleItems = titleQuery.items { allItems.append(contentsOf: titleItems) }
            if let artistItems = artistQuery.items { allItems.append(contentsOf: artistItems) }
            if let albumItems = albumQuery.items { allItems.append(contentsOf: albumItems) }
            
            // Remove duplicates based on persistent ID
            uniqueItems = Array(Set(allItems.map { $0.persistentID })).compactMap { id in
                allItems.first { $0.persistentID == id }
            }
            
            // Create a new query with the combined results
            mediaQuery = MPMediaQuery.songs()
            // We'll work with the uniqueItems directly instead of trying to create a new query
        }
        
        // Get the results
        let items: [MPMediaItem]
        if searchType.lowercased() == "all" {
            // For "all" search, we already have uniqueItems from the combined search
            items = uniqueItems
        } else {
            // For specific searches, get items from the mediaQuery
            guard let queryItems = mediaQuery.items, !queryItems.isEmpty else {
                return [
                    "status": "error",
                    "message": "No songs found matching '\(query)'",
                    "search_type": searchType
                ]
            }
            items = queryItems
        }
        
        guard !items.isEmpty else {
            return [
                "status": "error",
                "message": "No songs found matching '\(query)'",
                "search_type": searchType
            ]
        }
        
        // Sort by relevance (exact matches first, then partial matches)
        let sortedItems = items.sorted { item1, item2 in
            let title1 = (item1.title ?? "").lowercased()
            let title2 = (item2.title ?? "").lowercased()
            let artist1 = (item1.artist ?? "").lowercased()
            let artist2 = (item2.artist ?? "").lowercased()
            let queryLower = query.lowercased()
            
            // Exact matches first
            let exactMatch1 = title1 == queryLower || artist1 == queryLower
            let exactMatch2 = title2 == queryLower || artist2 == queryLower
            
            if exactMatch1 && !exactMatch2 { return true }
            if !exactMatch1 && exactMatch2 { return false }
            
            // Then by title match
            let titleMatch1 = title1.contains(queryLower)
            let titleMatch2 = title2.contains(queryLower)
            
            if titleMatch1 && !titleMatch2 { return true }
            if !titleMatch1 && titleMatch2 { return false }
            
            // Finally by artist match
            let artistMatch1 = artist1.contains(queryLower)
            let artistMatch2 = artist2.contains(queryLower)
            
            return artistMatch1 && !artistMatch2
        }
        
        // Get the best match (first item)
        let bestMatch = sortedItems.first!
        
        // Create a collection with just this song
        let collection = MPMediaItemCollection(items: [bestMatch])
        
        // Set the queue and play
        musicPlayer.setQueue(with: collection)
        musicPlayer.play()
        
        // Prepare results
        var results: [String: Any] = [
            "status": "success",
            "action": "search_and_play",
            "query": query,
            "search_type": searchType,
            "now_playing": [
                "title": bestMatch.title ?? "Unknown",
                "artist": bestMatch.artist ?? "Unknown",
                "album": bestMatch.albumTitle ?? "Unknown"
            ],
            "total_found": items.count
        ]
        
        // Add top 5 matches for reference
        let topMatches = Array(sortedItems.prefix(5)).map { item in
            return [
                "title": item.title ?? "Unknown",
                "artist": item.artist ?? "Unknown",
                "album": item.albumTitle ?? "Unknown"
            ]
        }
        results["top_matches"] = topMatches
        
        return results
    }
    
    func endCall() -> [String: Any] {
        // Stop the WebRTC connection
        stopConnection()
        
        // Exit the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exit(0)
        }
        
        return [
            "status": "success",
            "action": "end_call",
            "message": "Call ended. Goodbye!"
        ]
    }
    
    // MARK: - System Control Functions
    
    func toggleWiFi(_ enabled: Bool) -> [String: Any] {
        // Open WiFi settings using URL scheme
        if let url = URL(string: "App-Prefs:WIFI") {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        
        return [
            "status": "success",
            "message": "WiFi settings opened",
            "action": "wifi_settings_opened",
            "enabled": enabled
        ]
    }
    
    func toggleBluetooth(_ enabled: Bool) -> [String: Any] {
        // Open Bluetooth settings using URL scheme
        if let url = URL(string: "App-Prefs:Bluetooth") {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        
        return [
            "status": "success",
            "message": "Bluetooth settings opened",
            "action": "bluetooth_settings_opened",
            "enabled": enabled
        ]
    }
    

    
    func setDoNotDisturb(_ enabled: Bool) -> [String: Any] {
        // Open Do Not Disturb settings using URL scheme
        if let url = URL(string: "App-Prefs:DO_NOT_DISTURB") {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        
        return [
            "status": "success",
            "message": "Do Not Disturb settings opened",
            "action": "dnd_settings_opened", 
            "enabled": enabled
        ]
    }
    
    // MARK: - Alarm Management Functions
    
    func setAlarm(time: String, label: String? = nil) -> [String: Any] {
        // Request notification permissions first
        let semaphore = DispatchSemaphore(value: 0)
        var permissionGranted = false
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            permissionGranted = granted
            if let error = error {
                print("❌ Notification permission error: \(error)")
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if !permissionGranted {
            return [
                "status": "error",
                "message": "Notification permissions are required to set alarms. Please enable notifications in Settings."
            ]
        }
        
        // Parse time string (e.g., "7:30 AM" or "19:30")
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        guard let alarmDate = formatter.date(from: time) else {
            // Try 24-hour format
            formatter.dateFormat = "HH:mm"
            guard let alarmDate24 = formatter.date(from: time) else {
                return [
                    "status": "error",
                    "message": "Invalid time format. Use format like '7:30 AM' or '19:30'"
                ]
            }
            return createAlarm(date: alarmDate24, label: label)
        }
        
        return createAlarm(date: alarmDate, label: label)
    }
    
    private func createAlarm(date: Date, label: String?) -> [String: Any] {
        // Create a local notification as an alarm
        let content = UNMutableNotificationContent()
        content.title = label ?? "Alarm"
        content.body = "Time to wake up!"
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "ALARM_CATEGORY"
        
        // Create trigger for the specific time
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        // Create request with unique identifier
        let identifier = "alarm_\(Int(date.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        // Add to notification center
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to create alarm: \(error)")
            } else {
                print("🔔 Alarm created successfully for \(date)")
            }
        }
        
        let timeString = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return [
            "status": "success",
            "message": "Alarm set for \(timeString)",
            "alarm_time": timeString,
            "label": label ?? "Alarm",
            "alarm_id": identifier
        ]
    }
    
    func getAlarms() -> [String: Any] {
        // Get pending notifications (our alarms)
        let semaphore = DispatchSemaphore(value: 0)
        var alarms: [[String: Any]] = []
        
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            for request in requests {
                if request.content.categoryIdentifier == "ALARM_CATEGORY" {
                    if let trigger = request.trigger as? UNCalendarNotificationTrigger {
                        let date = Calendar.current.date(from: trigger.dateComponents) ?? Date()
                        let timeString = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                        
                        alarms.append([
                            "id": request.identifier,
                            "title": request.content.title,
                            "time": timeString,
                            "date": date.description
                        ])
                    }
                }
            }
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 1.0)
        
        return [
            "status": "success",
            "alarms": alarms,
            "count": alarms.count
        ]
    }
    
    // MARK: - Camera & Photo Functions
    
    func takePhoto() -> [String: Any] {
        // Use UIImagePickerController to take a photo
        DispatchQueue.main.async {
            let imagePicker = UIImagePickerController()
            imagePicker.sourceType = .camera
            imagePicker.allowsEditing = false
            
            // Get the root view controller
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootVC = window.rootViewController {
                
                // Present the camera
                rootVC.present(imagePicker, animated: true)
            }
        }
        
        return [
            "status": "success",
            "message": "Camera opened for photo capture",
            "action": "camera_opened"
        ]
    }
    
    func getRecentPhotos(count: Int = 10) -> [String: Any] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = count
        
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        var photos: [[String: Any]] = []
        
        assets.enumerateObjects { asset, _, _ in
            photos.append([
                "id": asset.localIdentifier,
                "creation_date": asset.creationDate?.description ?? "Unknown",
                "duration": asset.duration,
                "media_type": asset.mediaType.rawValue
            ])
        }
        
        return [
            "status": "success",
            "recent_photos": photos,
            "count": photos.count
        ]
    }
    
    // MARK: - Weather & Location Functions
    
    func getCurrentLocation() -> [String: Any] {
        let locationManager = CLLocationManager()
        locationManager.requestWhenInUseAuthorization()
        
        if CLLocationManager.locationServicesEnabled() {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.startUpdatingLocation()
            
            if let location = locationManager.location {
                let latitude = location.coordinate.latitude
                let longitude = location.coordinate.longitude
                
                return [
                    "status": "success",
                    "latitude": latitude,
                    "longitude": longitude,
                    "accuracy": location.horizontalAccuracy,
                    "message": "Location retrieved successfully"
                ]
            }
        }
        
        return [
            "status": "error",
            "message": "Location services not available or permission denied"
        ]
    }
    
    func getWeather() -> [String: Any] {
        // Get current location first, then fetch weather
        let locationManager = CLLocationManager()
        locationManager.requestWhenInUseAuthorization()
        
        if CLLocationManager.locationServicesEnabled(), let location = locationManager.location {
            let latitude = location.coordinate.latitude
            let longitude = location.coordinate.longitude
            
            // Use OpenWeatherMap API (you'll need to add your API key)
            let apiKey = "d8c9ae59c2096e0c826d919669a2fc97" // Replace with actual API key
            let urlString = "https://api.openweathermap.org/data/2.5/weather?lat=\(latitude)&lon=\(longitude)&appid=\(apiKey)&units=metric"
            
            if let url = URL(string: urlString) {
                let task = URLSession.shared.dataTask(with: url) { data, response, error in
                    if let data = data {
                        do {
                            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                print("🌤️ Weather data: \(json)")
                            }
                        } catch {
                            print("❌ Weather parsing error: \(error)")
                        }
                    }
                }
                task.resume()
            }
            
            return [
                "status": "success",
                "message": "Weather data requested for current location",
                "latitude": latitude,
                "longitude": longitude
            ]
        }
        
        return [
            "status": "error",
            "message": "Location services required for weather data"
        ]
    }
    
    // MARK: - Enhanced Media Control Functions
    
    func getPlaylists() -> [String: Any] {
        let playlistsQuery = MPMediaQuery.playlists()
        guard let playlists = playlistsQuery.collections else {
            return [
                "status": "error",
                "message": "No playlists found"
            ]
        }
        
        let playlistInfo = playlists.map { playlist in
            let playlistName = (playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? "Unknown"
            let persistentId = playlist.value(forProperty: MPMediaPlaylistPropertyPersistentID) as? NSNumber ?? 0
            
            return [
                "name": playlistName,
                "song_count": playlist.count,
                "persistent_id": persistentId
            ]
        }
        
        return [
            "status": "success",
            "playlists": playlistInfo,
            "count": playlistInfo.count
        ]
    }
    
    func playPlaylist(name: String) -> [String: Any] {
        let playlistsQuery = MPMediaQuery.playlists()
        guard let playlists = playlistsQuery.collections else {
            return [
                "status": "error",
                "message": "No playlists found"
            ]
        }
        
        // Find playlist by name
        let matchingPlaylist = playlists.first { playlist in
            let playlistName = (playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? ""
            return playlistName.lowercased().contains(name.lowercased())
        }
        
        guard let playlist = matchingPlaylist else {
            return [
                "status": "error",
                "message": "Playlist '\(name)' not found"
            ]
        }
        
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        musicPlayer.setQueue(with: playlist)
        musicPlayer.play()
        
        let playlistDisplayName = (playlist.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? "Unknown"
        
        return [
            "status": "success",
            "action": "playlist_playing",
            "playlist_name": playlistDisplayName,
            "song_count": playlist.count,
            "message": "Now playing playlist: \(playlistDisplayName)"
        ]
    }
    
    func toggleShuffle() -> [String: Any] {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        musicPlayer.shuffleMode = musicPlayer.shuffleMode == .off ? .songs : .off
        
        return [
            "status": "success",
            "action": "shuffle_toggled",
            "shuffle_enabled": musicPlayer.shuffleMode != .off,
            "message": "Shuffle mode \(musicPlayer.shuffleMode != .off ? "enabled" : "disabled")"
        ]
    }
    
    func toggleRepeat() -> [String: Any] {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        let currentMode = musicPlayer.repeatMode
        
        let newMode: MPMusicRepeatMode
        switch currentMode {
        case .none, .default:
            newMode = .one
        case .one:
            newMode = .all
        case .all:
            newMode = .none
        @unknown default:
            newMode = .none
        }
        
        musicPlayer.repeatMode = newMode
        
        let modeDescription: String
        switch newMode {
        case .none, .default:
            modeDescription = "off"
        case .one:
            modeDescription = "one song"
        case .all:
            modeDescription = "all songs"
        @unknown default:
            modeDescription = "off"
        }
        
        return [
            "status": "success",
            "action": "repeat_toggled",
            "repeat_mode": modeDescription,
            "message": "Repeat mode set to \(modeDescription)"
        ]
    }
    
    // MARK: - Notes Integration
    
    func createNote(title: String, content: String) -> [String: Any] {
        // Open Notes app for creating a new note
        // iOS doesn't allow direct note creation, so we open the app for the user
        if let notesURL = URL(string: "mobilenotes://") {
            DispatchQueue.main.async {
                if UIApplication.shared.canOpenURL(notesURL) {
                    UIApplication.shared.open(notesURL)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Opening Apple Notes app to create note: \(title)",
            "note_title": title,
            "note_content": content,
            "note": "I've opened the Apple Notes app for you to create your note. You can create a new note with the title '\(title)' and content '\(content)'."
        ]
    }
    
    func searchNotes(query: String) -> [String: Any] {
        // Open Notes app for searching
        if let notesURL = URL(string: "mobilenotes://") {
            DispatchQueue.main.async {
                if UIApplication.shared.canOpenURL(notesURL) {
                    UIApplication.shared.open(notesURL)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Opening Apple Notes app to search for: \(query)",
            "search_query": query,
            "note": "I've opened the Apple Notes app for you to search for notes containing '\(query)'. You can use the search function in the Notes app."
        ]
    }
    
    func getAllNotes() -> [String: Any] {
        // Open Notes app to view all notes
        if let notesURL = URL(string: "mobilenotes://") {
            DispatchQueue.main.async {
                if UIApplication.shared.canOpenURL(notesURL) {
                    UIApplication.shared.open(notesURL)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Opening Apple Notes app to view all notes",
            "note": "I've opened the Apple Notes app where you can view all your notes. Due to iOS privacy restrictions, I cannot directly access your notes, but you can see them all in the Notes app."
        ]
    }

        func editNote(noteId: String, newContent: String) -> [String: Any] {
        // Open Notes app for editing
        if let notesURL = URL(string: "mobilenotes://") {
            DispatchQueue.main.async {
                if UIApplication.shared.canOpenURL(notesURL) {
                    UIApplication.shared.open(notesURL)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Opening Apple Notes app for editing",
            "note": "I've opened the Apple Notes app where you can edit your notes. Due to iOS privacy restrictions, I cannot directly edit notes, but you can find and edit them in the Notes app."
        ]
    }
    
    func deleteNote(noteId: String) -> [String: Any] {
        // Open Notes app for deletion
        if let notesURL = URL(string: "mobilenotes://") {
            DispatchQueue.main.async {
                if UIApplication.shared.canOpenURL(notesURL) {
                    UIApplication.shared.open(notesURL)
                }
            }
        }
        
        return [
            "status": "success",
            "message": "Opening Apple Notes app for deletion",
            "note": "I've opened the Apple Notes app where you can delete your notes. Due to iOS privacy restrictions, I cannot directly delete notes, but you can find and delete them in the Notes app."
        ]
    }
    
    // MARK: - Shortcuts Integration
    
    func runShortcut(name: String) -> [String: Any] {
        // Use URL scheme to run shortcuts
        if let url = URL(string: "shortcuts://run-shortcut?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)") {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        
        return [
            "status": "success",
            "message": "Shortcut '\(name)' executed",
            "shortcut_name": name
        ]
    }
    
    // MARK: - Contacts Integration
    
    /// Request contacts permission
    func requestContactsPermission() {
        CNContactStore().requestAccess(for: .contacts) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("📇 Contacts permission granted")
                } else {
                    print("❌ Contacts permission denied: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
    
    /// Look up phone number for a contact name
    func lookupPhoneNumber(for name: String) -> String? {
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let formatterDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            formatterDescriptor
        ]
        
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            
            for contact in contacts {
                let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check if name matches (case insensitive)
                if fullName.lowercased().contains(name.lowercased()) ||
                   contact.givenName.lowercased().contains(name.lowercased()) ||
                   contact.familyName.lowercased().contains(name.lowercased()) {
                    
                    // Get first phone number
                    if let phoneNumber = contact.phoneNumbers.first?.value.stringValue {
                        print("📇 Found contact: \(fullName) → \(phoneNumber)")
                        return phoneNumber
                    }
                }
            }
        } catch {
            print("❌ Failed to search contacts: \(error)")
        }
        
        print("📇 No contact found for: \(name)")
        return nil
    }
    
    /// Search contacts with fuzzy matching - used by AI via function calling
    func searchContacts(query: String, limit: Int = 10) -> [[String: Any]] {
        let normalizedQuery = normalizeContactQuery(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let queryTokens = normalizedQuery.split(separator: " ")
        let store = CNContactStore()
        let formatterDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactMiddleNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactNicknameKey as NSString,
            CNContactOrganizationNameKey as NSString,
            CNContactPhoneticGivenNameKey as NSString,
            CNContactPhoneticFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            formatterDescriptor
        ]

        var matches: [(contact: CNContact, phone: String, displayName: String, score: Int)] = []
        let formatter = CNContactFormatter()
        formatter.style = .fullName

        do {
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.mutableObjects = false
            request.unifyResults = true

            try store.enumerateContacts(with: request) { contact, _ in
                let displayName = formatter.string(from: contact) ?? contact.givenName
                let nameTokens = self.buildContactTokens(contact: contact, displayName: displayName)
                let score = self.scoreMatch(for: nameTokens, normalizedQuery: normalizedQuery, queryTokens: queryTokens)

                guard score > 0 else { return }

                for labeledValue in contact.phoneNumbers {
                    let normalizedPhone = self.normalizedPhoneNumber(from: labeledValue.value.stringValue)
                    guard !normalizedPhone.isEmpty else { continue }

                    matches.append((
                        contact: contact,
                        phone: normalizedPhone,
                        displayName: displayName.isEmpty ? contact.givenName : displayName,
                        score: score
                    ))
                }
            }
        } catch {
            print("❌ Failed to search contacts: \(error)")
        }

        var seen = Set<String>()
        let sortedMatches = matches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.displayName < rhs.displayName
                }
                return lhs.score > rhs.score
            }
            .filter { seen.insert("\($0.contact.identifier)|\($0.phone)").inserted }
            .prefix(limit)

        let results: [[String: Any]] = sortedMatches.map { match in
            [
                "id": match.contact.identifier,
                "name": match.displayName,
                "phone": match.phone,
                "nickname": match.contact.nickname,
                "match_score": match.score
            ]
        }

        print("📇 Contact search for '\(query)': found \(results.count) matches.")
        if let bestMatch = results.first, let phone = bestMatch["phone"] as? String {
            print("✅ Best match found: \(bestMatch["name"] ?? "Unknown") at \(phone)")
        }

        return results
    }

    private func normalizeContactQuery(_ value: String) -> String {
        return value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func buildContactTokens(contact: CNContact, displayName: String) -> [String] {
        var tokens: [String] = []

        let components = [
            contact.givenName,
            contact.middleName,
            contact.familyName,
            contact.nickname,
            contact.organizationName,
            contact.phoneticGivenName,
            contact.phoneticFamilyName,
            displayName
        ]

        for component in components {
            let normalized = normalizeContactQuery(component)
            if !normalized.isEmpty {
                tokens.append(normalized)
            }
        }

        return tokens
    }

    private func scoreMatch(for tokens: [String], normalizedQuery: String, queryTokens: [Substring]) -> Int {
        guard !tokens.isEmpty else { return 0 }

        var bestScore = 0

        for token in tokens {
            if token == normalizedQuery {
                bestScore = max(bestScore, 120)
            } else if token.hasPrefix(normalizedQuery) {
                bestScore = max(bestScore, 105)
            } else if token.contains(normalizedQuery) {
                bestScore = max(bestScore, 95)
            }

            for queryToken in queryTokens {
                if token == queryToken {
                    bestScore = max(bestScore, 90)
                } else if token.hasPrefix(queryToken) {
                    bestScore = max(bestScore, 80)
                } else if token.contains(queryToken) {
                    bestScore = max(bestScore, 70)
                }
            }
        }

        return bestScore
    }

    private func normalizedPhoneNumber(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("+") {
            let digits = trimmed.dropFirst().filter { $0.isNumber }
            return digits.isEmpty ? "" : "+" + digits
        }

        let digitsOnly = trimmed.filter { $0.isNumber }
        switch digitsOnly.count {
        case 11 where digitsOnly.first == "1":
            return "+" + digitsOnly
        case 10:
            return "+1" + digitsOnly
        case let count where count > 0:
            return "+" + digitsOnly
        default:
            return ""
        }
    }
    
    /// Feed MCP tool results back to the agent as conversation items
    private func feedMCPResultsToAgent(callId: String, output: String) {
        guard let dc = dataChannel, dc.readyState == .open else {
            print("❌ Data channel not ready for MCP result feedback")
            return
        }
        
        // Log the output for debugging
        print("📤 MCP Tool Output for call_id \(callId):")
        print(output)
        
        // Create a conversation item with the MCP tool results
        let mcpResult: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: mcpResult)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("✅ Fed MCP tool results back to agent for call_id: \(callId)")
            requestAssistantResponseAfterTool(force: true, context: "mcp-result:\(callId)")
        } catch {
            print("❌ Failed to feed MCP results to agent: \(error)")
        }
    }

    /// Helper to send a tool/function response to the realtime session
    private func sendFunctionCallOutput(previousItemId: String, callId: String, output: String) {
        guard let dc = dataChannel, dc.readyState == .open else {
            print("❌ Data channel not ready to send function call output")
            return
        }

        let functionResult: [String: Any] = [
            "type": "conversation.item.create",
            "previous_item_id": previousItemId,
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: functionResult)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("✅ Sent function call output for call_id: \(callId)")
            requestAssistantResponseAfterTool(force: true, context: "local-function:\(callId)")
        } catch {
            print("❌ Failed to send function call output: \(error)")
        }
    }

    // MARK: - MCP Client

    private func activeMcpServerConfig() -> (url: URL, authorization: String?)? {
        guard let tool = mcpTools.first,
              let urlString = tool["server_url"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }

        let authorization = tool["authorization"] as? String
        return (url: url, authorization: authorization)
    }

    private func normalizedMcpAuthorizationHeader(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if raw.lowercased().hasPrefix("bearer ") {
            return raw
        }

        return "Bearer \(raw)"
    }

    private func performMcpToolCall(name: String, arguments: [String: Any]) async -> String {
        guard let config = activeMcpServerConfig() else {
            return "{\"ok\":false,\"error\":\"mcp_not_configured\"}"
        }

        do {
            let response = try await callMcpToolOverWebSocket(
                serverUrl: config.url,
                authorization: config.authorization,
                toolName: name,
                toolArguments: arguments
            )

            if let result = response["result"] as? [String: Any] {
                if let structured = result["structuredContent"] {
                    return jsonString(from: structured) ?? "{}"
                }
                if let content = result["content"] as? [[String: Any]],
                   let firstText = content.first?["text"] as? String {
                    return firstText
                }
                return jsonString(from: result) ?? "{}"
            }

            if let errorInfo = response["error"] as? [String: Any] {
                let payload: [String: Any] = [
                    "ok": false,
                    "error": errorInfo["message"] as? String ?? "mcp_error",
                    "details": errorInfo
                ]
                return jsonString(from: payload) ?? "{\"ok\":false}"
            }

            return jsonString(from: response) ?? "{}"
        } catch {
            let payload: [String: Any] = [
                "ok": false,
                "error": error.localizedDescription
            ]
            return jsonString(from: payload) ?? "{\"ok\":false}"
        }
    }

    private func callMcpToolOverWebSocket(
        serverUrl: URL,
        authorization: String?,
        toolName: String,
        toolArguments: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: serverUrl)
        request.setValue("mcp", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let header = normalizedMcpAuthorizationHeader(authorization) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let rpcId = UUID().uuidString
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": rpcId,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": toolArguments
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "WebRTCManager.MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode MCP request"])
        }

        try await task.send(.string(jsonText))

        for _ in 0..<10 {
            let message = try await task.receive()
            let responseText: String
            switch message {
            case .string(let text):
                responseText = text
            case .data(let data):
                responseText = String(data: data, encoding: .utf8) ?? ""
            @unknown default:
                responseText = ""
            }

            guard !responseText.isEmpty,
                  let responseData = responseText.data(using: .utf8),
                  let responseObj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                continue
            }

            if let responseId = responseObj["id"] as? String, responseId == rpcId {
                return responseObj
            }
        }

        throw NSError(domain: "WebRTCManager.MCP", code: -2, userInfo: [NSLocalizedDescriptionKey: "No MCP response received"])
    }

    /// Encode JSON dictionaries into a string payload for the realtime API
    private func jsonString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Call a standard text model for token-heavy tasks (defaults to gpt-5-2025-08-07)
    private func performDelegatedTextCompletion(apiKey: String, prompt: String, system: String?, model: String, maxOutputTokens: Int?) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "WebRTCManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI URL"])
        }

        var messages: [[String: Any]] = []
        if let system = system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7
        ]

        let maxCompletionTokens = (maxOutputTokens ?? 800)
        if maxCompletionTokens > 0 {
            payload["max_completion_tokens"] = maxCompletionTokens
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "WebRTCManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response from OpenAI"])
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            if let body = String(data: data, encoding: .utf8) {
                throw NSError(domain: "WebRTCManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI error: \(body)"])
            }
            throw NSError(domain: "WebRTCManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI error status \(httpResponse.statusCode)"])
        }

        let rawJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let choices = rawJSON?["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content
            }

            if let contentArray = message["content"] as? [[String: Any]] {
                let combined = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !combined.isEmpty {
                    return combined
                }
            }
        }

        if let body = String(data: data, encoding: .utf8) {
            throw NSError(domain: "WebRTCManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to parse delegated GPT-5 response: \(body)"])
        }
        
        throw NSError(domain: "WebRTCManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to parse delegated GPT-5 response"])
    }
    
    /// Handle local function calls from the AI
    private func handleLocalFunctionCall(itemId: String, callId: String, name: String, arguments: String) {
        guard let dc = dataChannel, dc.readyState == .open else {
            print("❌ Data channel not ready for function call response")
            return
        }
        
        var functionResult: [String: Any] = [:]
        
        switch name {
        case "search_contacts":
            // Parse arguments
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let query = argDict["query"] as? String else {
                print("❌ Invalid arguments for search_contacts")
                return
            }
            
            let limit = argDict["limit"] as? Int ?? 10
            
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let results = self.searchContacts(query: query, limit: limit)
                guard let output = self.jsonString(from: results) else { return }

                await MainActor.run {
                    self.sendFunctionCallOutput(previousItemId: itemId, callId: callId, output: output)
                }
            }
            return
            
        case "create_calendar_event":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let title = argDict["title"] as? String,
                  let startTimeStr = argDict["start_time"] as? String,
                  let endTimeStr = argDict["end_time"] as? String else {
                print("❌ Invalid arguments for create_calendar_event")
                return
            }
            
            let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
            let startTimeMatches = detector.matches(in: startTimeStr, options: [], range: NSRange(location: 0, length: startTimeStr.utf16.count))
            let endTimeMatches = detector.matches(in: endTimeStr, options: [], range: NSRange(location: 0, length: endTimeStr.utf16.count))

            guard let startTimeMatch = startTimeMatches.first, let startTime = startTimeMatch.date else {
                print("❌ Could not parse start time from: \(startTimeStr)")
                return
            }
            
            guard let endTimeMatch = endTimeMatches.first, let endTime = endTimeMatch.date else {
                print("❌ Could not parse end time from: \(endTimeStr)")
                return
            }
            
            let result = createCalendarEvent(title: title, startDate: startTime, endDate: endTime)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "delete_calendar_event":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let eventId = argDict["event_id"] as? String else {
                print("❌ Invalid arguments for delete_calendar_event")
                return
            }
            
            let result = deleteCalendarEvent(eventId: eventId)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "edit_calendar_event":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let eventId = argDict["event_id"] as? String else {
                print("❌ Invalid arguments for edit_calendar_event")
                return
            }
            
            let newTitle = argDict["new_title"] as? String
            
            let newStartTime: Date?
            if let newStartTimeStr = argDict["new_start_time"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: newStartTimeStr, options: [], range: NSRange(location: 0, length: newStartTimeStr.utf16.count))
                newStartTime = matches.first?.date
            } else {
                newStartTime = nil
            }
            
            let newEndTime: Date?
            if let newEndTimeStr = argDict["new_end_time"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: newEndTimeStr, options: [], range: NSRange(location: 0, length: newEndTimeStr.utf16.count))
                newEndTime = matches.first?.date
            } else {
                newEndTime = nil
            }
            
            let result = editCalendarEvent(eventId: eventId, newTitle: newTitle, newStartDate: newStartTime, newEndDate: newEndTime)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "find_calendar_events":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] else {
                print("❌ Invalid arguments for find_calendar_events")
                return
            }
            
            let title = argDict["title"] as? String
            
            let startDate: Date?
            if let startDateStr = argDict["start_date"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: startDateStr, options: [], range: NSRange(location: 0, length: startDateStr.utf16.count))
                startDate = matches.first?.date
            } else {
                startDate = nil
            }
            
            let endDate: Date?
            if let endDateStr = argDict["end_date"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: endDateStr, options: [], range: NSRange(location: 0, length: endDateStr.utf16.count))
                endDate = matches.first?.date
            } else {
                endDate = nil
            }
            
            let results = findCalendarEvents(title: title, startDate: startDate, endDate: endDate)
            let resultsJSON = try! String(data: JSONSerialization.data(withJSONObject: results, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultsJSON
                ]
            ]

        case "create_reminder":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let title = argDict["title"] as? String else {
                print("❌ Invalid arguments for create_reminder")
                return
            }
            
            let dueDate: Date?
            if let dueDateStr = argDict["due_date"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: dueDateStr, options: [], range: NSRange(location: 0, length: dueDateStr.utf16.count))
                dueDate = matches.first?.date
            } else {
                dueDate = nil
            }
            
            let notes = argDict["notes"] as? String
            
            let result = createReminder(title: title, dueDate: dueDate, notes: notes)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "delete_reminder":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let reminderId = argDict["reminder_id"] as? String else {
                print("❌ Invalid arguments for delete_reminder")
                return
            }
            
            let result = deleteReminder(reminderId: reminderId)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "edit_reminder":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let reminderId = argDict["reminder_id"] as? String else {
                print("❌ Invalid arguments for edit_reminder")
                return
            }
            
            let newTitle = argDict["new_title"] as? String
            
            let newDueDate: Date?
            if let newDueDateStr = argDict["new_due_date"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: newDueDateStr, options: [], range: NSRange(location: 0, length: newDueDateStr.utf16.count))
                newDueDate = matches.first?.date
            } else {
                newDueDate = nil
            }
            
            let newNotes = argDict["new_notes"] as? String
            
            let result = editReminder(reminderId: reminderId, newTitle: newTitle, newDueDate: newDueDate, newNotes: newNotes)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "find_reminders":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] else {
                print("❌ Invalid arguments for find_reminders")
                return
            }
            
            let title = argDict["title"] as? String
            
            let dueDate: Date?
            if let dueDateStr = argDict["due_date"] as? String {
                let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector.matches(in: dueDateStr, options: [], range: NSRange(location: 0, length: dueDateStr.utf16.count))
                dueDate = matches.first?.date
            } else {
                dueDate = nil
            }
            
            let completed = argDict["completed"] as? Bool
            
            let results = findReminders(title: title, dueDate: dueDate, completed: completed)
            let resultsJSON = try! String(data: JSONSerialization.data(withJSONObject: results, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultsJSON
                ]
            ]

        // Device Information Tools
        case "get_device_info":
            let result = getDeviceInfo()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_battery_info":
            let result = getBatteryInfo()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_storage_info":
            let result = getStorageInfo()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_network_info":
            let result = getNetworkInfo()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // System Control Tools
        case "set_brightness":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let brightness = argDict["brightness"] as? Float else {
                print("❌ Invalid arguments for set_brightness")
                return
            }
            
            let result = setBrightness(brightness)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "set_volume":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let volume = argDict["volume"] as? Float else {
                print("❌ Invalid arguments for set_volume")
                return
            }
            
            let result = setVolume(volume)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "trigger_haptic":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let style = argDict["style"] as? String else {
                print("❌ Invalid arguments for trigger_haptic")
                return
            }
            
            let result = triggerHapticFeedback(style)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "take_screenshot":
            let result = takeScreenshot()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Media Control Tools
        case "get_music_info":
            let result = getMusicInfo()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "control_music":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let action = argDict["action"] as? String else {
                print("❌ Invalid arguments for control_music")
                return
            }
            
            let result = controlMusic(action)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "search_and_play_music":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let query = argDict["query"] as? String else {
                print("❌ Invalid arguments for search_and_play_music")
                return
            }
            
            let searchType = argDict["search_type"] as? String ?? "all"
            let result = searchAndPlayMusic(query: query, searchType: searchType)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "end_call":
            let result = endCall()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // System Control Tools
        case "toggle_wifi":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let enabled = argDict["enabled"] as? Bool else {
                print("❌ Invalid arguments for toggle_wifi")
                return
            }
            
            let result = toggleWiFi(enabled)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "toggle_bluetooth":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let enabled = argDict["enabled"] as? Bool else {
                print("❌ Invalid arguments for toggle_bluetooth")
                return
            }
            
            let result = toggleBluetooth(enabled)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "set_do_not_disturb":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let enabled = argDict["enabled"] as? Bool else {
                print("❌ Invalid arguments for set_do_not_disturb")
                return
            }
            
            let result = setDoNotDisturb(enabled)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Alarm Management Tools
        case "set_alarm":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let time = argDict["time"] as? String else {
                print("❌ Invalid arguments for set_alarm")
                return
            }
            
            let label = argDict["label"] as? String
            let result = setAlarm(time: time, label: label)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_alarms":
            let result = getAlarms()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Camera & Photo Tools
        case "take_photo":
            let result = takePhoto()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_recent_photos":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] else {
                print("❌ Invalid arguments for get_recent_photos")
                return
            }
            
            let count = argDict["count"] as? Int ?? 10
            let result = getRecentPhotos(count: count)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Weather & Location Tools
        case "get_current_location":
            let result = getCurrentLocation()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_weather":
            let result = getWeather()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Enhanced Media Control Tools
        case "get_playlists":
            let result = getPlaylists()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "play_playlist":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let name = argDict["name"] as? String else {
                print("❌ Invalid arguments for play_playlist")
                return
            }
            
            let result = playPlaylist(name: name)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "toggle_shuffle":
            let result = toggleShuffle()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "toggle_repeat":
            let result = toggleRepeat()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Notes Integration Tools
        case "create_note":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let title = argDict["title"] as? String,
                  let content = argDict["content"] as? String else {
                print("❌ Invalid arguments for create_note")
                return
            }
            
            let result = createNote(title: title, content: content)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "search_notes":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let query = argDict["query"] as? String else {
                print("❌ Invalid arguments for search_notes")
                return
            }
            
            let result = searchNotes(query: query)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "get_all_notes":
            let result = getAllNotes()
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        // Shortcuts Integration Tools
        case "run_shortcut":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let name = argDict["name"] as? String else {
                print("❌ Invalid arguments for run_shortcut")
                return
            }
            
            let result = runShortcut(name: name)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "edit_note":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let noteId = argDict["note_id"] as? String,
                  let newContent = argDict["new_content"] as? String else {
                print("❌ Invalid arguments for edit_note")
                return
            }
            
            let result = editNote(noteId: noteId, newContent: newContent)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "delete_note":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let noteId = argDict["note_id"] as? String else {
                print("❌ Invalid arguments for delete_note")
                return
            }
            
            let result = deleteNote(noteId: noteId)
            let resultJSON = try! String(data: JSONSerialization.data(withJSONObject: result, options: []), encoding: .utf8)!
            
            functionResult = [
                "type": "conversation.item.create",
                "previous_item_id": itemId,
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": resultJSON
                ]
            ]

        case "delegate_to_gpt4o":
            guard let argData = arguments.data(using: .utf8),
                  let argDict = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                  let prompt = argDict["prompt"] as? String else {
                print("❌ Invalid arguments for delegate_to_gpt4o")
                return
            }

            let system = argDict["system"] as? String
            let trimmedModel = (argDict["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let delegatedModel = (trimmedModel?.isEmpty == false ? trimmedModel : nil) ?? "gpt-5-2025-08-07"
            let maxTokens = argDict["max_output_tokens"] as? Int

            guard !currentApiKey.isEmpty else {
                print("❌ Missing API key for delegated text completion call")
                if let output = jsonString(from: ["error": "Missing API key for delegated text completion"]) {
                    sendFunctionCallOutput(previousItemId: itemId, callId: callId, output: output)
                }
                return
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    let delegatedText = try await self.performDelegatedTextCompletion(
                        apiKey: self.currentApiKey,
                        prompt: prompt,
                        system: system,
                        model: delegatedModel,
                        maxOutputTokens: maxTokens
                    )

                    let payload: [String: Any] = [
                        "model": delegatedModel,
                        "response": delegatedText
                    ]
                    if let output = self.jsonString(from: payload) {
                        await MainActor.run {
                            self.sendFunctionCallOutput(previousItemId: itemId, callId: callId, output: output)
                        }
                    }
                } catch {
                    let payload: [String: Any] = [
                        "error": error.localizedDescription
                    ]
                    if let output = self.jsonString(from: payload) {
                        await MainActor.run {
                            self.sendFunctionCallOutput(previousItemId: itemId, callId: callId, output: output)
                        }
                    }
                }
            }

            return

        default:
            print("⚠️ Unknown local function call: \(name)")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: functionResult)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("✅ Sent function call result for \(name)")
        } catch {
            print("❌ Failed to send function call result: \(error)")
        }
    }
    
    /// Get preview layer for video
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        return previewLayer
    }
    
    /// Switch between front and back camera
    func switchCamera() {
        guard isVideoEnabled, let session = cameraSession else { return }
        
        isUsingFrontCamera.toggle()
        
        // Remove current input
        if let currentInput = currentCameraInput {
            session.removeInput(currentInput)
        }
        
        // Get the opposite camera
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("❌ Camera not available for position: \(position)")
            isUsingFrontCamera.toggle() // revert
            return
        }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            currentCameraInput = newInput
            
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                print("📹 Switched to \(isUsingFrontCamera ? "front" : "back") camera")
            }
        } catch {
            print("❌ Failed to switch camera: \(error)")
            isUsingFrontCamera.toggle() // revert
        }
    }
    

    /// Start a WebRTC connection using a standard API key for local testing.
    func startConnection(
        apiKey: String,
        humeApiKey: String? = nil,
        humeSecretKey: String? = nil,
        provider: VoiceProvider = .openAI,
        modelName: String,
        systemMessage: String,
        voice: String
    ) {
        self.currentProvider = provider
        if let hKey = humeApiKey {
            self.humeApiKey = hKey
        }
        if let sKey = humeSecretKey {
            self.humeSecretKey = sKey
        }
        
        conversation.removeAll()
        conversationMap.removeAll()
        
        if provider == .hume {
            print("🚀 Starting Hume AI connection...")
            
            // Validate credentials
            guard !self.humeApiKey.isEmpty, !self.humeSecretKey.isEmpty else {
                print("❌ Hume API Key or Secret Key missing")
                DispatchQueue.main.async {
                    let errorItem = ConversationItem(
                        id: UUID().uuidString,
                        role: "system",
                        text: "Error: Hume API Key and Secret Key are required."
                    )
                    self.conversation.append(errorItem)
                    self.connectionStatus = .disconnected
                }
                return
            }
            
            // Initialize and connect HumeClient
            self.humeClient = HumeClient(apiKey: self.humeApiKey, secretKey: self.humeSecretKey)
            self.humeClient?.delegate = self
            self.connectionStatus = .connecting
            
            // Generate tool definitions to pass to Hume
            // We can reuse the same structure we send to OpenAI, as Hume EVI supports similar tool definitions.
            var tools: [[String: Any]] = []
            
            // 1. Local Tools
            tools.append(contactSearchTool)
            tools.append(createCalendarEventTool)
            tools.append(deleteCalendarEventTool)
            tools.append(editCalendarEventTool)
            tools.append(findCalendarEventsTool)
            tools.append(createReminderTool)
            tools.append(deleteReminderTool)
            tools.append(editReminderTool)
            tools.append(findRemindersTool)
            tools.append(getDeviceInfoTool)
            tools.append(getBatteryInfoTool)
            tools.append(getStorageInfoTool)
            tools.append(getNetworkInfoTool)
            tools.append(setBrightnessTool)
            tools.append(setVolumeTool)
            tools.append(triggerHapticTool)
            tools.append(takeScreenshotTool)
            tools.append(getMusicInfoTool)
            tools.append(controlMusicTool)
            tools.append(searchAndPlayMusicTool)
            tools.append(getPlaylistsTool)
            tools.append(playPlaylistTool)
            tools.append(toggleShuffleTool)
            tools.append(toggleRepeatTool)
            tools.append(endCallTool)
            tools.append(delegateToGPT4OTool)
            tools.append(toggleWiFiTool)
            tools.append(toggleBluetoothTool)
            tools.append(setDoNotDisturbTool)
            tools.append(setAlarmTool)
            tools.append(getAlarmsTool)
            tools.append(takePhotoTool)
            tools.append(getRecentPhotosTool)
            tools.append(getCurrentLocationTool)
            tools.append(getWeatherTool)
            tools.append(createNoteTool)
            tools.append(searchNotesTool)
            tools.append(editNoteTool)
            tools.append(deleteNoteTool)
            tools.append(getAllNotesTool)
            tools.append(runShortcutTool)
            
            // 2. MCP Tools
            tools.append(contentsOf: mcpTools)
            
            self.humeClient?.connect(tools: tools)
            return
        }
        
        // OpenAI Logic below

        conversationMap.removeAll()

        // Store updated config
        self.modelName = modelName
        self.systemInstructions = systemMessage
        self.voice = voice
        self.currentApiKey = apiKey

        setupPeerConnection()
        setupLocalAudio()
        configureAudioSession()
        
        guard let peerConnection = peerConnection else { return }
        
        // Create a Data Channel for sending/receiving events
        let config = RTCDataChannelConfiguration()
        if let channel = peerConnection.dataChannel(forLabel: "oai-events", configuration: config) {
            dataChannel = channel
            dataChannel?.delegate = self
        }
        
        // Create an SDP offer
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["levelControl": "true"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                print("Failed to create offer: \(error)")
                return
            }
            guard let sdp else {
                print("Failed to create offer: missing SDP")
                return
            }
            
            Task { [weak self, weak peerConnection] in
                guard let self, let peerConnection else { return }
                do {
                    try await self.setLocalDescriptionAsync(peerConnection, description: sdp)
                    guard let localSdp = peerConnection.localDescription?.sdp else {
                        throw NSError(domain: "WebRTCManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "Missing local SDP after setting description"])
                    }
                    
                    let answerSdp = try await self.fetchRemoteSDP(apiKey: apiKey, localSdp: localSdp)
                    let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
                    try await self.setRemoteDescriptionAsync(peerConnection, description: answer)
                    
                    await MainActor.run {
                        self.connectionStatus = .connected
                        self.forceAudioToSpeaker()
                        self.enableBackgroundMode()
                    }
                } catch {
                    print("Error establishing WebRTC session: \(error)")
                    await MainActor.run {
                        self.connectionStatus = .disconnected
                    }
                }
            }
        }
    }
    
    func stopConnection() {
        stopVideo()
        
        // Reset all camera and audio state
        isVideoEnabled = false
        isCameraOn = false
        isMicMuted = false
        
        // Stop OpenAI connection
        peerConnection?.close()
        peerConnection = nil
        dataChannel = nil
        audioTrack = nil
        videoTrack = nil
        
        // Stop Hume connection
        humeClient?.disconnect()
        humeClient = nil
        
        connectionStatus = .disconnected
        currentApiKey = ""
        awaitingToolResponse = false

        print("🛑 Connection stopped - camera and audio reset")
    }
    
    /// Sends a custom "conversation.item.create" event
    func sendMessage() {
        guard let dc = dataChannel,
              !outgoingMessage.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        
        let realtimeEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": outgoingMessage
                    ]
                ]
            ]
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            self.outgoingMessage = ""
            createResponse()
        }
    }
    
    /// Sends a "response.create" event
    func createResponse() {
        guard let dc = dataChannel else { return }
        
        let realtimeEvent: [String: Any] = [ "type": "response.create" ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: realtimeEvent) {
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
        }
    }
    
    private func markAwaitingToolResponse(context: String) {
        awaitingToolResponse = true
        print("🔧 Awaiting tool output (\(context))")
    }
    
    private func requestAssistantResponseAfterTool(force: Bool = false, context: String) {
        guard force || awaitingToolResponse else {
            print("🔧 Skipping response trigger (\(context)) - no pending tool output")
            return
        }
        
        awaitingToolResponse = false
        print("🎙️ Triggering assistant response after tool output (\(context))")
        createResponse()
    }
    
    /// Called automatically when data channel opens, or you can manually call it.
    /// Updates session configuration with the latest instructions and voice.
    func sendSessionUpdate() {
        guard let dc = dataChannel, dc.readyState == .open else {
            print("Data channel is not open. Cannot send session.update.")
            return
        }
        
        var sessionConfig: [String: Any] = [
            "modalities": ["text", "audio"],  // Enable both text and audio
            "instructions": systemInstructions,
            "voice": voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": "whisper-1"
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
                "create_response": true
            ],
            "max_response_output_tokens": 4096,  // Reasonable limit for voice responses
            "tool_choice": "auto"  // Let model decide when to use tools
        ]
        
        // Prepare tools array
        var allTools: [[String: Any]] = []
        
        // Add local contact search tool
        allTools.append(contactSearchTool)
        
        // Add local calendar creation tool
        allTools.append(createCalendarEventTool)
        allTools.append(deleteCalendarEventTool)
        allTools.append(editCalendarEventTool)
        allTools.append(findCalendarEventsTool)
        
        // Add reminder creation tool
        allTools.append(createReminderTool)
        allTools.append(deleteReminderTool)
        allTools.append(editReminderTool)
        allTools.append(findRemindersTool)
        
        // Add Device Information Tools
        allTools.append(getDeviceInfoTool)
        allTools.append(getBatteryInfoTool)
        allTools.append(getStorageInfoTool)
        allTools.append(getNetworkInfoTool)
        
        // Add System Control Tools
        allTools.append(setBrightnessTool)
        allTools.append(setVolumeTool)
        allTools.append(triggerHapticTool)
        allTools.append(takeScreenshotTool)
        
        // Add Media Control Tools
        allTools.append(getMusicInfoTool)
        allTools.append(controlMusicTool)
        allTools.append(searchAndPlayMusicTool)
        
        allTools.append(endCallTool)

        allTools.append(delegateToGPT4OTool)

        // Add System Control Tools
        allTools.append(toggleWiFiTool)
        allTools.append(toggleBluetoothTool)
        
        allTools.append(setDoNotDisturbTool)
        
        // Add Alarm Management Tools
        allTools.append(setAlarmTool)
        allTools.append(getAlarmsTool)
        
        // Add Camera & Photo Tools
        allTools.append(takePhotoTool)
        allTools.append(getRecentPhotosTool)
        
        // Add Weather & Location Tools
        allTools.append(getCurrentLocationTool)
        allTools.append(getWeatherTool)
        
        // Add Enhanced Media Control Tools
        allTools.append(getPlaylistsTool)
        allTools.append(playPlaylistTool)
        allTools.append(toggleShuffleTool)
        allTools.append(toggleRepeatTool)
        
        // Add Notes Integration Tools
        allTools.append(createNoteTool)
        allTools.append(searchNotesTool)
        allTools.append(editNoteTool)
        allTools.append(deleteNoteTool)
        allTools.append(getAllNotesTool)
        
        // Add Shortcuts Integration Tools
        allTools.append(runShortcutTool)
        
        // Add MCP tools if configured
        allTools.append(contentsOf: mcpTools)
        
        if !allTools.isEmpty {
            sessionConfig["tools"] = allTools
            print("🔧 Adding \(allTools.count) tools to session:")
            print("   - 1 local contact search function")
            print("   - 4 local calendar functions (create, delete, edit, find)")
            print("   - 4 local reminder functions (create, delete, edit, find)")
            print("   - 4 device information functions (device, battery, storage, network)")
            print("   - 4 system control functions (brightness, volume, haptic, screenshot)")
            print("   - 7 media control functions (music info, control, search, playlists, shuffle, repeat)")
            print("   - 4 system toggle functions (wifi, bluetooth, network info, do not disturb)")
            print("   - 2 alarm management functions (set, get)")
            print("   - 2 camera/photo functions (take photo, recent photos)")
            print("   - 2 location/weather functions (location, weather)")
            print("   - 2 notes functions (create, search)")
            print("   - 1 shortcuts function (run shortcut)")
            print("   - 1 call control function (end call)")
            print("   - \(mcpTools.count) MCP tools")
            print("🔧 Contact search tool definition: \(contactSearchTool)")
            print("🔧 Calendar creation tool definition: \(createCalendarEventTool)")
            print("🔧 Reminder creation tool definition: \(createReminderTool)")
            print("🔧 Device info tool definition: \(getDeviceInfoTool)")
            print("🔧 System control tool definition: \(setBrightnessTool)")
            print("🔧 Media control tool definition: \(getMusicInfoTool)")
        }
        
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": sessionConfig
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sessionUpdate)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("session.update event sent.")
        } catch {
            print("Failed to serialize session.update JSON: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupPeerConnection() {
        let config = RTCConfiguration()
        // If needed, configure ICE servers here
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }
    
    private func setLocalDescriptionAsync(_ connection: RTCPeerConnection, description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    private func setRemoteDescriptionAsync(_ connection: RTCPeerConnection, description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Configure for loudspeaker output with background support
            try audioSession.setCategory(.playAndRecord, options: [
                .defaultToSpeaker,      // Route to speaker by default
                .allowBluetoothHFP,     // Allow Bluetooth devices
                .allowBluetoothA2DP,    // Allow high-quality Bluetooth
                .mixWithOthers,         // Allow mixing with other audio
                .duckOthers             // Lower other app audio when speaking
            ])
            
            try audioSession.setMode(.videoChat)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Force audio to loudspeaker (not earpiece)
            try audioSession.overrideOutputAudioPort(.speaker)
            
            print("🔊 Audio routed to main speaker (loudspeaker)")
            print("🌟 Background audio support enabled")
            
        } catch {
            print("❌ Failed to configure AVAudioSession: \(error)")
        }
    }
    
    private func setupLocalAudio() {
        guard let peerConnection = peerConnection else { return }
        let factory = RTCPeerConnectionFactory()
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ],
            optionalConstraints: nil
        )
        
        let audioSource = factory.audioSource(with: constraints)
        
        let localAudioTrack = factory.audioTrack(with: audioSource, trackId: "local_audio")
        peerConnection.add(localAudioTrack, streamIds: ["local_stream"])
        audioTrack = localAudioTrack
    }
    
    /// Posts our SDP offer to the Realtime API, returns the answer SDP.
    private func fetchRemoteSDP(apiKey: String, localSdp: String) async throws -> String {
        let baseUrl = "https://api.openai.com/v1/realtime"
        guard let url = URL(string: "\(baseUrl)?model=\(modelName)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = localSdp.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "WebRTCManager.fetchRemoteSDP",
                          code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "WebRTCManager.fetchRemoteSDP",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to decode SDP"])
        }
        
        return answerSdp
    }
    
    private func handleIncomingJSON(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let rawEvent = try? JSONSerialization.jsonObject(with: data),
              let eventDict = rawEvent as? [String: Any],
              let eventType = eventDict["type"] as? String else {
            print("Received unparsable JSON:\n\(jsonString)\n")
            return
        }
        
        // Filter out noisy events to keep the console clean
        let noisyEvents: Set<String> = [
            "response.audio_transcript.delta",
            "response.audio.done",
            "response.content_part.added",
            "response.content_part.done",
            "response.output_item.added",
            "response.output_item.done",
            "rate_limits.updated",
            "input_audio_buffer.speech_started",
            "input_audio_buffer.speech_stopped",
            "input_audio_buffer.committed",
            "conversation.item.input_audio_transcription.delta",
            "conversation.item.input_audio_transcription.completed",
            "response.function_call_arguments.delta",
            "response.mcp_call_arguments.delta",
            "output_audio_buffer.started",
            "output_audio_buffer.stopped",
            "output_audio_buffer.cleared"
        ]
        
        if !noisyEvents.contains(eventType) {
            print("Received JSON:\n\(jsonString)\n")
        }
        
        eventTypeStr = eventType
        
        switch eventType {
        case "conversation.item.created":
            if let item = eventDict["item"] as? [String: Any],
               let itemId = item["id"] as? String,
               let role = item["role"] as? String
            {
                // If item contains "content", extract the text
                let text = (item["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                
                let newItem = ConversationItem(id: itemId, role: role, text: text)
                conversationMap[itemId] = newItem
                if role == "assistant" || role == "user" {
                    conversation.append(newItem)
                }
            }
            
        case "response.audio_transcript.delta":
            // partial transcript for assistant’s message
            if let itemId = eventDict["item_id"] as? String,
               let delta = eventDict["delta"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text += delta
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = convItem.text
                    }
                }
            }
            
        case "response.audio_transcript.done":
            // final transcript for assistant’s message
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = transcript
                    }
                }
            }
            
        case "conversation.item.input_audio_transcription.completed":
            // final transcript for user's audio input
            if let itemId = eventDict["item_id"] as? String,
               let transcript = eventDict["transcript"] as? String
            {
                if var convItem = conversationMap[itemId] {
                    convItem.text = transcript
                    conversationMap[itemId] = convItem
                    if let idx = conversation.firstIndex(where: { $0.id == itemId }) {
                        conversation[idx].text = transcript
                    }
                }
            }
            
        case "response.function_call.done", "response.tool_calls.done":
            print("🔧 Tool call completed - requesting assistant response.")
            requestAssistantResponseAfterTool(context: eventType)
            
        case "response.mcp_call.completed":
            print("🔧 MCP tool call completed successfully - triggering AI response.")
            requestAssistantResponseAfterTool(context: eventType)
            
        case "response.mcp_call.failed":
            print("❌ MCP tool call failed")
            if let errorInfo = eventDict["error"] as? [String: Any] {
                print("❌ MCP Error: \(errorInfo)")
            }
            // Trigger AI response to explain the failure
            requestAssistantResponseAfterTool(force: true, context: "\(eventType)-failure")
            
        case "response.function_call_arguments.done":
            if let itemId = eventDict["item_id"] as? String,
               let callId = eventDict["call_id"] as? String,
               let name = eventDict["name"] as? String,
               let arguments = eventDict["arguments"] as? String {

                if localToolNames.contains(name) {
                    print("🔧 Local function call: \(name) with call_id: \(callId) and args: \(arguments)")
                    markAwaitingToolResponse(context: name)
                    handleLocalFunctionCall(itemId: itemId, callId: callId, name: name, arguments: arguments)
                    return
                }

                if mcpExpectedToolNames.contains(name) || !mcpTools.isEmpty {
                    print("🔧 MCP tool call requested: \(name) with call_id: \(callId)")
                    markAwaitingToolResponse(context: "mcp:\(name)")

                    Task.detached(priority: .userInitiated) { [weak self] in
                        guard let self else { return }

                        var argDict: [String: Any] = [:]
                        if let argData = arguments.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] {
                            argDict = parsed
                        }

                        if name == "send_imessage",
                           argDict["text"] == nil,
                           let messageText = argDict["message"] as? String {
                            argDict["text"] = messageText
                        }

                        let output = await self.performMcpToolCall(name: name, arguments: argDict)
                        await MainActor.run {
                            self.sendFunctionCallOutput(previousItemId: itemId, callId: callId, output: output)
                        }
                    }
                    return
                }

                print("⚠️ Function call for unknown tool: \(name)")
                return
            } else {
                print("🔧 Function call args done but missing required fields: \(eventDict)")
            }
            
        case "response.output_item.added":
            // Check if this is a function or MCP call being created
            if let item = eventDict["item"] as? [String: Any],
               let itemType = item["type"] as? String {
                switch itemType {
                case "function_call":
                    if let functionName = item["name"] as? String {
                        print("🔧 Function call created: \(functionName)")
                        markAwaitingToolResponse(context: functionName)
                    }
                case "mcp_call":
                    let label = item["server_label"] as? String ?? "mcp"
                    print("🔧 MCP call created for server: \(label)")
                    markAwaitingToolResponse(context: "mcp:\(label)")
                default:
                    break
                }
            }
            
        case "response.output_item.done":
            // Check if this is a function or MCP call completion with results
            if let item = eventDict["item"] as? [String: Any],
               let itemType = item["type"] as? String {
                switch itemType {
                case "mcp_call":
                    let outputSnippet = (item["output"] as? String)?.prefix(160) ?? ""
                    print("🔧 MCP call completed with output: \(outputSnippet)")
                    requestAssistantResponseAfterTool(context: "mcp_call_output")
                case "function_call":
                    let functionName = item["name"] as? String ?? "function_call"
                    print("🔧 Function call request received: \(functionName)")
                    // DO NOT trigger response here. We must execute the function and send output first.
                    // The function execution logic (handleLocalFunctionCall) will trigger the response when done.
                default:
                    break
                }
            }
            
        case "conversation.item.function_call.completed", "conversation.item.tool_calls.completed":
            print("🔧 Tool execution conversation item completed.")
            requestAssistantResponseAfterTool(context: eventType)
            
        case "session.created", "session.updated":
            print("🎯 Session configured with MCP tools ready")
            
        case "response.done":
            print("🎯 Response completed")
            // Response is fully complete, no further action needed
            
        case "error":
            if let error = eventDict["error"] as? [String: Any],
               let message = error["message"] as? String {
                print("❌ Server error: \(message)")
            }
            
        default:
            // Log all function call related events for debugging
            if eventType.contains("function") || eventType.contains("tool") {
                print("🔧 Function/Tool event: \(eventType) - \(eventDict)")
            } else {
                print("📨 Unhandled event: \(eventType)")
            }
            break
        }
    }
    // MARK: - Video Methods
    
    private func startVideo() {
        guard isVideoEnabled && isCameraOn else { 
            print("📹 Video not enabled or camera is off")
            return 
        }
        
        // Request camera permission first
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.setupCamera()
                } else {
                    print("❌ Camera permission denied")
                    self?.isVideoEnabled = false
                    self?.isCameraOn = false
                }
            }
        }
    }
    
    private func stopVideo() {
        cameraSession?.stopRunning()
        cameraSession = nil
        videoOutput = nil
        previewLayer = nil
        videoTrack = nil
        currentCameraInput = nil
        print("📹 Camera stopped")
    }
    
    private func setupCamera() {
        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("❌ No camera available for position: \(position)")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            currentCameraInput = input
            
            cameraSession = AVCaptureSession()
            cameraSession?.sessionPreset = .high  // Use high quality for better preview
            
            print("📹 Setting up camera session...")
            cameraSession?.beginConfiguration()
            
            if cameraSession?.canAddInput(input) == true {
                cameraSession?.addInput(input)
                print("📹 ✅ Added camera input: \(position == .front ? "front" : "back")")
            }
            
            // Set up video output
            videoOutput = AVCaptureVideoDataOutput()
            videoOutput?.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput?.alwaysDiscardsLateVideoFrames = true
            videoOutput?.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInitiated))
            
            if let videoOutput = videoOutput, cameraSession?.canAddOutput(videoOutput) == true {
                cameraSession?.addOutput(videoOutput)
                print("📹 ✅ Added video output")
            }
            
            // Commit configuration changes BEFORE creating preview layer
            cameraSession?.commitConfiguration()
            print("📹 ✅ Configuration committed")
            
            // Set up preview layer AFTER session is configured
            if let session = cameraSession {
                previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer?.videoGravity = .resizeAspectFill
                previewLayer?.masksToBounds = true
                print("📹 ✅ Created preview layer")
                
                // Start the session immediately after creating preview layer
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    session.startRunning()
                    DispatchQueue.main.async {
                        print("📹 ✅ Camera session is now running!")
                        // Force UI update after camera starts
                        self?.objectWillChange.send()
                    }
                }
            }
            
        } catch {
            print("❌ Camera setup error: \(error)")
            isVideoEnabled = false
        }
    }
    
    private func sendVideoFrame(_ imageData: Data) {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        
        let base64Image = imageData.base64EncodedString()
        
        let imageMessage: [String: Any] = [
            "type": "conversation.item.create",
            "previous_item_id": NSNull(),
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": "data:image/jpeg;base64,\(base64Image)"
                    ]
                ]
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: imageMessage)
            let buffer = RTCDataBuffer(data: jsonData, isBinary: false)
            dc.sendData(buffer)
            print("📹 Sent video frame to model")
        } catch {
            print("❌ Failed to send video frame: \(error)")
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension WebRTCManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Send a frame every 2 seconds to avoid overwhelming the model
        let now = Date().timeIntervalSince1970
        let frameInterval: TimeInterval = 1.0
        
        if let lastFrameTime = lastVideoFrameTime, now - lastFrameTime < frameInterval {
            return
        }
        lastVideoFrameTime = now
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            let image = UIImage(cgImage: cgImage)
            
            // Compress the image
            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                DispatchQueue.main.async {
                    self.sendVideoFrame(jpegData)
                }
            }
        }
    }
    
    private var lastVideoFrameTime: TimeInterval? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.lastVideoFrameTime) as? TimeInterval
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.lastVideoFrameTime, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

private struct AssociatedKeys {
    static var lastVideoFrameTime: UInt8 = 0
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE Connection State changed to: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // If the server creates the data channel on its side, handle it here
        dataChannel.delegate = self
    }
}

// MARK: - HumeClientDelegate
extension WebRTCManager: HumeClientDelegate {
    func humeClient(_ client: HumeClient, didChangeStatus status: ConnectionStatus) {
        DispatchQueue.main.async {
            self.connectionStatus = status
        }
    }
    
    func humeClient(_ client: HumeClient, didReceiveMessage message: ConversationItem) {
        DispatchQueue.main.async {
            self.conversation.append(message)
            self.conversationMap[message.id] = message
        }
    }
    
    func humeClient(_ client: HumeClient, didEncounterError error: Error) {
        print("❌ Hume Client Error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.errorMessage = error.localizedDescription
            let errorItem = ConversationItem(
                id: UUID().uuidString,
                role: "system",
                text: "Hume Error: \(error.localizedDescription)"
            )
            self.conversation.append(errorItem)
            self.connectionStatus = .disconnected
        }
    }
    
    func humeClient(_ client: HumeClient, didRequestTool toolName: String, arguments: String, callId: String) {
        print("🔧 Executing Hume Tool: \(toolName) with args: \(arguments)")
        
        // Reuse the existing tool execution logic?
        // We need to parse arguments and execute.
        // Since the existing logic is tied to DataChannel messages, we'll replicate the routing here for now or refactor.
        // For speed, let's just route manually to the known functions.
        
        Task {
            var result: String = "Error: Unknown tool or invalid arguments"
            
            // Parse arguments
            let argsDict = (try? JSONSerialization.jsonObject(with: arguments.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
            
            // Check Local Tools
            if localToolNames.contains(toolName) {
                // Route to local function
                switch toolName {
                case "search_contacts":
                    if let query = argsDict["query"] as? String {
                        result = await searchContacts(query: query)
                    }
                case "create_calendar_event":
                   if let title = argsDict["title"] as? String,
                      let startTime = argsDict["start_time"] as? String,
                      let endTime = argsDict["end_time"] as? String {
                       result = await createCalendarEvent(title: title, startTime: startTime, endTime: endTime)
                   }
                case "delete_calendar_event":
                    if let eventId = argsDict["event_id"] as? String {
                        result = await deleteCalendarEvent(eventId: eventId)
                    }
                case "edit_calendar_event":
                    if let eventId = argsDict["event_id"] as? String {
                        result = await editCalendarEvent(eventId: eventId, newTitle: argsDict["new_title"] as? String, newStartTime: argsDict["new_start_time"] as? String, newEndTime: argsDict["new_end_time"] as? String)
                    }
                case "find_calendar_events":
                    result = await findCalendarEvents(title: argsDict["title"] as? String, startDate: argsDict["start_date"] as? String, endDate: argsDict["end_date"] as? String)
                case "create_reminder":
                    if let title = argsDict["title"] as? String {
                        result = await createReminder(title: title, dueDate: argsDict["due_date"] as? String, notes: argsDict["notes"] as? String)
                    }
                case "delete_reminder":
                    if let reminderId = argsDict["reminder_id"] as? String {
                        result = await deleteReminder(reminderId: reminderId)
                    }
                case "edit_reminder":
                    if let reminderId = argsDict["reminder_id"] as? String {
                        result = await editReminder(reminderId: reminderId, newTitle: argsDict["new_title"] as? String, newDueDate: argsDict["new_due_date"] as? String, newNotes: argsDict["new_notes"] as? String)
                    }
                case "find_reminders":
                    result = await findReminders(title: argsDict["title"] as? String, dueDate: argsDict["due_date"] as? String, completed: argsDict["completed"] as? Bool)
                case "get_device_info":
                    result = getDeviceInfo()
                case "get_battery_info":
                    result = getBatteryInfo()
                case "get_storage_info":
                    result = getStorageInfo()
                case "get_network_info":
                    result = getNetworkInfo()
                case "set_brightness":
                    if let brightness = argsDict["brightness"] as? Double {
                        result = setBrightness(brightness: brightness)
                    }
                case "set_volume":
                    if let volume = argsDict["volume"] as? Double {
                        result = setVolume(volume: volume)
                    }
                case "trigger_haptic":
                    if let style = argsDict["style"] as? String {
                        result = triggerHaptic(style: style)
                    }
                case "take_screenshot":
                    result = await takeScreenshot()
                case "get_music_info":
                    result = await getMusicInfo()
                case "control_music":
                    if let action = argsDict["action"] as? String {
                        result = await controlMusic(action: action)
                    }
                case "search_and_play_music":
                    if let query = argsDict["query"] as? String {
                        result = await searchAndPlayMusic(query: query, searchType: argsDict["search_type"] as? String)
                    }
                case "get_playlists":
                    result = await getPlaylists()
                case "play_playlist":
                    if let name = argsDict["name"] as? String {
                        result = await playPlaylist(name: name)
                    }
                case "toggle_shuffle":
                    result = await toggleShuffle()
                case "toggle_repeat":
                    result = await toggleRepeat()
                case "end_call":
                    result = endCall()
                case "delegate_to_gpt4o":
                    if let prompt = argsDict["prompt"] as? String {
                        let system = argsDict["system"] as? String
                        let model = argsDict["model"] as? String
                        let maxOutputTokens = argsDict["max_output_tokens"] as? Int
                        result = await performDelegatedTextCompletion(apiKey: currentApiKey, prompt: prompt, system: system, model: model, maxOutputTokens: maxOutputTokens)
                    }
                case "toggle_wifi":
                    if let enabled = argsDict["enabled"] as? Bool {
                        result = toggleWiFi(enabled: enabled)
                    }
                case "toggle_bluetooth":
                    if let enabled = argsDict["enabled"] as? Bool {
                        result = toggleBluetooth(enabled: enabled)
                    }
                case "set_do_not_disturb":
                    if let enabled = argsDict["enabled"] as? Bool {
                        result = setDoNotDisturb(enabled: enabled)
                    }
                case "set_alarm":
                    if let time = argsDict["time"] as? String {
                        result = setAlarm(time: time, label: argsDict["label"] as? String)
                    }
                case "get_alarms":
                    result = getAlarms()
                case "take_photo":
                    result = await takePhoto()
                case "get_recent_photos":
                    let count = argsDict["count"] as? Int ?? 10
                    result = await getRecentPhotos(count: count)
                case "get_current_location":
                    result = await getCurrentLocation()
                case "get_weather":
                    result = await getWeather()
                case "create_note":
                    if let title = argsDict["title"] as? String, let content = argsDict["content"] as? String {
                        result = createNote(title: title, content: content)
                    }
                case "search_notes":
                    if let query = argsDict["query"] as? String {
                        result = searchNotes(query: query)
                    }
                case "edit_note":
                    if let noteId = argsDict["note_id"] as? String, let newContent = argsDict["new_content"] as? String {
                        result = editNote(noteId: noteId, newContent: newContent)
                    }
                case "delete_note":
                    if let noteId = argsDict["note_id"] as? String {
                        result = deleteNote(noteId: noteId)
                    }
                case "get_all_notes":
                    result = getAllNotes()
                case "run_shortcut":
                    if let name = argsDict["name"] as? String {
                        result = await runShortcut(name: name)
                    }
                default:
                    print("⚠️ Hume requested unknown local tool: \(toolName)")
                    result = "Error: Unknown local tool '\(toolName)'"
                }
            } else {
                // MCP Tool
                do {
                    result = try await mcpClient.callTool(name: toolName, arguments: argsDict)
                } catch {
                    result = "Error executing MCP tool: \(error.localizedDescription)"
                }
            }
            
            // Send result back to Hume
            client.sendToolOutput(callId: callId, output: result)
        }
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("Data channel state changed: \(dataChannel.readyState)")
        // Auto-send session.update after channel is open
        if dataChannel.readyState == .open {
            sendSessionUpdate()
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            return
        }
        DispatchQueue.main.async {
            self.handleIncomingJSON(message)
        }
    }
}
