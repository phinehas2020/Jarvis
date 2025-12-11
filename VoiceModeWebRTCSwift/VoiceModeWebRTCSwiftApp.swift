//
//  VoiceModeWebRTCSwiftApp.swift
//  VoiceModeWebRTCSwift
//
//  Created by Pallav Agarwal on 1/3/25.
//

import SwiftUI
import AVFoundation

@main
struct VoiceModeWebRTCSwiftApp: App {
    init() {
        // Configure background audio on app launch
        configureBackgroundAudio()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    print("🌟 App entering foreground")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    print("🌟 App entering background - maintaining audio connection")
                }
        }
    }
    
    private func configureBackgroundAudio() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ])
            print("🌟 App configured for background audio")
        } catch {
            print("❌ Failed to configure background audio: \(error)")
        }
    }
}
