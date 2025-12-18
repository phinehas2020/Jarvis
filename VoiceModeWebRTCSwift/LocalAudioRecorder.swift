import Foundation
import AVFoundation

class LocalAudioRecorder: NSObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    
    // Updated signature to include RMS (matched CaptureSessionRecorder)
    var onChunk: ((String, Float) -> Void)?
    
    override init() {
        super.init()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // We use .playAndRecord with .mixWithOthers to coexist with the library's player
            // effectively sharing the RemoteIO
            // .defaultToSpeaker is safer for voice agents
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .mixWithOthers,
                .duckOthers
            ])
            
            // Try to set strict 16kHz if possible
            do {
                try session.setPreferredSampleRate(16000)
            } catch {
                print("⚠️ Could not set preferred sample rate: \(error)")
            }
            
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            AudioSessionManager.shared.applyPreferredInput()
        } catch {
            print("Error setting up audio session: \(error)")
        }
    }
    
    func startRecording() {
        setupAudioSession()
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }
        
        inputNode = audioEngine.inputNode
        let inputFormat = inputNode!.inputFormat(forBus: 0)
        
        // We want 16kHz, 1 channel, Int16 (PCM) for Gemini
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            print("Failed to create target format")
            return
        }
        self.targetFormat = pcmFormat
        
        // Create converter
        audioConverter = AVAudioConverter(from: inputFormat, to: pcmFormat)
        
        // Buffer size: 100ms at 48kHz is ~4800 frames. 2048 is ~40ms. Low latency is good.
        inputNode?.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] (buffer, time) in
            self?.processBuffer(buffer: buffer)
        }
        
        do {
            try audioEngine.start()
            print("🎙️ LocalAudioRecorder started (Input: \(inputFormat.sampleRate)Hz, Target: 16000Hz)")
        } catch {
            print("Error starting audio engine: \(error)")
        }
    }
    
    func stopRecording() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        audioConverter = nil
        print("⏹️ LocalAudioRecorder stopped")
    }
    
    private func processBuffer(buffer: AVAudioPCMBuffer) {
        guard let targetFormat = targetFormat, let converter = audioConverter else { return }
        
        // Calculate output buffer capacity
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 100
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        
        var error: NSError? = nil
        
        var haveFed = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if haveFed {
                outStatus.pointee = .noDataNow
                return nil
            }
            haveFed = true
            outStatus.pointee = .haveData
            return buffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error || error != nil {
            // print("Audio conversion error: \(String(describing: error))")
            return
        }
        
        // Calculate RMS & Base64
        if let channelData = outputBuffer.int16ChannelData {
            let channelPointer = channelData[0]
            let frameCount = Int(outputBuffer.frameLength)
            
            guard frameCount > 0 else { return }
            
            // Apply Software Gain (Boosting sensitivity)
            let micGain: Float = 2.5
            var sum: Float = 0
            
            for i in 0..<frameCount {
                // Apply gain and clamp to Int16 range
                let boostedSample = Float(channelPointer[i]) * micGain
                let clampedSample = max(Float(Int16.min), min(Float(Int16.max), boostedSample))
                let finalSample = Int16(clampedSample)
                
                // Update the buffer with boosted sample (for encoding)
                channelPointer[i] = finalSample
                
                // Use boosted sample for RMS Calculation
                sum += clampedSample * clampedSample
            }
            
            let rms = sqrt(sum / Float(frameCount))
            
            // Base64 Encoding
            let dataCount = frameCount * MemoryLayout<Int16>.size
            let data = Data(bytes: channelPointer, count: dataCount)
            let base64 = data.base64EncodedString()
            
            self.onChunk?(base64, rms)
        }
    }
}
