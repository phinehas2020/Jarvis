import Foundation
import AVFoundation

/// Centralized manager for AVAudioSession configuration.
/// Ensures consistent audio settings across all voice providers.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    private init() {
        setupInterruptionHandling()
    }

    private func preferredInput(for session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let preferredOrder: [AVAudioSession.Port] = [
            .bluetoothHFP,
            .bluetoothLE,
            .headsetMic,
            .builtInMic
        ]

        guard let inputs = session.availableInputs else { return nil }
        for port in preferredOrder {
            if let match = inputs.first(where: { $0.portType == port }) {
                return match
            }
        }

        return inputs.first
    }

    func applyPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        guard let preferred = preferredInput(for: session) else { return }
        do {
            try session.setPreferredInput(preferred)
            print("🎧 Preferred input: \(preferred.portType.rawValue)")
        } catch {
            print("❌ Failed to set preferred input: \(error)")
        }
    }
    
    // MARK: - Audio Session Configuration
    
    /// Configure audio session for voice chat (bidirectional audio)
    func configureForVoiceChat(sampleRate: Double = 24000) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .defaultToSpeaker,
                .allowBluetoothHFP,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            applyPreferredInput()
            
            let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ", ")
            let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
            print("🔊 AudioSession configured for voiceChat (rate: \(session.sampleRate)Hz, in: \(inputs), out: \(outputs))")
        } catch {
            print("❌ AudioSession configuration error: \(error)")
        }
    }
    
    /// Configure audio session specifically for recording (mic input focus)
    func configureForRecording(sampleRate: Double = 16000) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .mixWithOthers,
                .duckOthers
            ])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            applyPreferredInput()
            
            print("🎙️ AudioSession configured for recording (rate: \(session.sampleRate)Hz)")
        } catch {
            print("❌ AudioSession configuration error: \(error)")
        }
    }

    /// Configure audio session for Gemini native audio with stronger echo cancellation.
    func configureForGeminiVoiceChat(sampleRate: Double = 16000) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .defaultToSpeaker,
                .allowBluetoothHFP
            ])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            applyPreferredInput()

            print("🎙️ AudioSession configured for Gemini voiceChat (rate: \(session.sampleRate)Hz)")
        } catch {
            print("❌ AudioSession configuration error: \(error)")
        }
    }
    
    /// Force audio output to the main speaker (loudspeaker)
    func forceToSpeaker() {
        do {
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            let hasExternalOutput = outputs.contains { output in
                switch output.portType {
                case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .headsetMic, .usbAudio, .carAudio:
                    return true
                default:
                    return false
                }
            }

            if hasExternalOutput {
                print("🔊 Skipping forceToSpeaker (external output in use)")
                return
            }

            try session.overrideOutputAudioPort(.speaker)
            print("🔊 Audio forced to main speaker")
        } catch {
            print("❌ Failed to force audio to speaker: \(error)")
        }
    }
    
    /// Deactivate the audio session (call when disconnecting)
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🔇 AudioSession deactivated")
        } catch {
            print("❌ Failed to deactivate audio session: \(error)")
        }
    }
    
    // MARK: - Interruption Handling
    
    private var onInterruptionBegan: (() -> Void)?
    private var onInterruptionEnded: (() -> Void)?
    
    /// Set callbacks for audio interruptions (e.g., phone calls)
    func setInterruptionHandlers(began: @escaping () -> Void, ended: @escaping () -> Void) {
        onInterruptionBegan = began
        onInterruptionEnded = ended
    }
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            print("⚠️ Audio interruption began")
            onInterruptionBegan?()
        case .ended:
            print("✅ Audio interruption ended")
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        switch reason {
        case .newDeviceAvailable:
            print("🎧 New audio device connected")
        case .oldDeviceUnavailable:
            print("🔌 Audio device disconnected")
        case .categoryChange:
            print("🔄 Audio category changed")
        default:
            break
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
