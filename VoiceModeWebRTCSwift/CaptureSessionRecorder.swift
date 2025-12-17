import Foundation
import AVFoundation
import CoreMedia

class CaptureSessionRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private let workQueue = DispatchQueue(label: "CaptureSessionRecorderQueue")
    
    var onChunk: ((String, Float) -> Void)?
    
    // Conversion state
    private var audioConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    
    override init() {
        super.init()
    }
    
    func prepare() {
        if captureSession == nil {
            setupCaptureSession()
        }
    }
    
    private func setupCaptureSession() {
        // Target: 16kHz Int16 Mono
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
        
        captureSession = AVCaptureSession()
        captureSession?.automaticallyConfiguresApplicationAudioSession = false
        captureSession?.beginConfiguration()
        
        // Input
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession?.canAddInput(input) == true else {
            print("❌ CaptureSessionRecorder: Failed to create input")
            return
        }
        captureSession?.addInput(input)
        
        // Output
        let output = AVCaptureAudioDataOutput()
        // Note: audioSettings is not available on iOS for data output conversion.
        // We must accept native format and convert manually.
        
        if captureSession?.canAddOutput(output) == true {
            captureSession?.addOutput(output)
            output.setSampleBufferDelegate(self, queue: workQueue)
        }
        
        captureSession?.commitConfiguration()
        print("🎙️ CaptureSessionRecorder configured")
    }
    
    func startRecording() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            
            // NOTE: Audio session must be configured by the caller BEFORE calling this
            // to avoid conflicts with other audio components
            
            if self.captureSession?.isRunning == false {
                self.captureSession?.startRunning()
                print("🎙️ CaptureSessionRecorder started")
            }
        }
    }
    
    func stopRecording() {
        workQueue.async { [weak self] in
            if self?.captureSession?.isRunning == true {
                self?.captureSession?.stopRunning()
                print("⏹️ CaptureSessionRecorder stopped")
            }
        }
    }
    
    // Delegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let targetFormat = targetFormat else { return }
        
        // 1. Get Input Format from SampleBuffer
        // Correct way to get ASBD pointer and creating AVAudioFormat
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let currentInputFormat = AVAudioFormat(streamDescription: asbdPointer) else { return }
        
        // 2. Prepare Converter if needed (Create new one if format changes)
        if audioConverter == nil || inputFormat != currentInputFormat {
            print("🎙️ Creating converter: \(currentInputFormat.sampleRate)Hz \(currentInputFormat.channelCount)ch (\(currentInputFormat.commonFormat.rawValue)) -> 16000Hz")
            inputFormat = currentInputFormat
            audioConverter = AVAudioConverter(from: currentInputFormat, to: targetFormat)
        }
        
        guard let converter = audioConverter else { return }
        
        // 3. Create input buffer and copy from CMSampleBuffer
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if numSamples == 0 { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: currentInputFormat, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)

        // Extract audio buffers from CMSampleBuffer (handles non-contiguous storage)
        var retainedBlockBuffer: CMBlockBuffer?
        let channelCount = max(Int(currentInputFormat.channelCount), 1)
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListPointer.deallocate() }

        let audioBufferList = audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self)

        let bufferListStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )

        if bufferListStatus != noErr {
            return
        }

        let srcBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let dstBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)

        for (src, dst) in zip(srcBuffers, dstBuffers) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let bytesToCopy = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            if bytesToCopy > 0 {
                memcpy(dstData, srcData, bytesToCopy)
            }
        }
        
        // Calculate Output Buffer Size
        let ratio = targetFormat.sampleRate / currentInputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(numSamples) * ratio) + 100
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }
        
        var error: NSError? = nil
        var supplied = false
        
        let oneShotBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true

            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        // 4. Convert
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: oneShotBlock)
        
        if status == .error || error != nil {
            // print("Conversion error: \(String(describing: error))")
            return
        }
        
        // 5. Send Chunk
        guard outputBuffer.frameLength > 0 else { return }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let outData = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let expectedByteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        let validByteCount = min(Int(audioBuffer.mDataByteSize), expectedByteCount)
        guard validByteCount > 0 else { return }

        let pcmData = Data(bytes: outData, count: validByteCount)
        guard !pcmData.isEmpty else { return }

        let rms: Float = pcmData.withUnsafeBytes { rawBufferPointer in
            let samples = rawBufferPointer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }

            var sum: Float = 0
            for sample in samples {
                let value = Float(sample)
                sum += value * value
            }

            return sqrt(sum / Float(samples.count))
        }

        self.onChunk?(pcmData.base64EncodedString(), rms)
    }
}
