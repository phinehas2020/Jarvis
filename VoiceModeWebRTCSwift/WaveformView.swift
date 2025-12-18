import SwiftUI
import Accelerate

/// A real-time audio waveform visualization view.
/// Uses Metal-inspired rendering with smooth animations for a premium feel.
struct WaveformView: View {
    let amplitudes: [Float]
    let isActive: Bool
    let accentColor: Color
    let barCount: Int
    
    init(amplitudes: [Float] = [], isActive: Bool = false, accentColor: Color = .blue, barCount: Int = 32) {
        self.amplitudes = amplitudes
        self.isActive = isActive
        self.accentColor = accentColor
        self.barCount = barCount
    }
    
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 40
    private let barSpacing: CGFloat = 3
    private let cornerRadius: CGFloat = 2
    
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    WaveformBar(
                        amplitude: normalizedAmplitude(at: index),
                        isActive: isActive,
                        accentColor: accentColor,
                        minHeight: minBarHeight,
                        maxHeight: maxBarHeight,
                        cornerRadius: cornerRadius,
                        index: index
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func normalizedAmplitude(at index: Int) -> CGFloat {
        guard !amplitudes.isEmpty else {
            // When idle, generate a subtle "breathing" animation
            return 0.15
        }
        
        // Map the index to the appropriate amplitude sample
        let sampleIndex = Int(Float(index) / Float(barCount) * Float(amplitudes.count))
        let clampedIndex = min(max(0, sampleIndex), amplitudes.count - 1)
        
        // Normalize amplitude (0.0 to 1.0)
        let amplitude = CGFloat(amplitudes[clampedIndex])
        return min(max(0.1, amplitude), 1.0)
    }
}

/// Individual bar in the waveform
struct WaveformBar: View {
    let amplitude: CGFloat
    let isActive: Bool
    let accentColor: Color
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let cornerRadius: CGFloat
    let index: Int
    
    @State private var animatedHeight: CGFloat = 4
    @State private var idlePhase: Double = 0
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(barGradient)
            .frame(width: 4, height: animatedHeight)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: animatedHeight)
            .onAppear {
                updateHeight()
                startIdleAnimation()
            }
            .onChange(of: amplitude) { _ in
                updateHeight()
            }
            .onChange(of: isActive) { _ in
                updateHeight()
            }
    }
    
    private var barGradient: LinearGradient {
        let intensity = animatedHeight / maxHeight
        let topColor = accentColor.opacity(0.8 + intensity * 0.2)
        let bottomColor = accentColor.opacity(0.3 + intensity * 0.3)
        
        return LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private func updateHeight() {
        if isActive {
            animatedHeight = minHeight + (maxHeight - minHeight) * amplitude
        } else {
            // Subtle idle animation
            let baseHeight = minHeight + 2
            let variation = sin(idlePhase + Double(index) * 0.3) * 3
            animatedHeight = baseHeight + CGFloat(variation)
        }
    }
    
    private func startIdleAnimation() {
        guard !isActive else { return }
        
        // Create a gentle wave effect when idle
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            idlePhase = .pi * 2
        }
    }
}

/// Waveform visualizer that responds to actual audio levels
class WaveformGenerator: ObservableObject {
    @Published var amplitudes: [Float] = Array(repeating: 0.1, count: 32)
    
    private var history: [[Float]] = []
    private let smoothingFactor: Float = 0.7
    
    /// Update with new RMS (root mean square) value from audio input
    func updateWithRMS(_ rms: Float) {
        // Normalize RMS to 0-1 range (typical speech RMS is 100-5000)
        let normalized = min(1.0, max(0.0, rms / 5000.0))
        
        // Add some variation across bars for visual interest
        var newAmplitudes: [Float] = []
        for i in 0..<32 {
            // Create slight variation based on position
            let variation = sin(Float(i) * 0.3 + Float(Date().timeIntervalSince1970 * 10)) * 0.2
            let amplitude = normalized * (0.8 + variation)
            newAmplitudes.append(max(0.1, min(1.0, amplitude)))
        }
        
        // Smooth transition
        for i in 0..<amplitudes.count {
            amplitudes[i] = amplitudes[i] * smoothingFactor + newAmplitudes[i] * (1 - smoothingFactor)
        }
    }
    
    /// Reset to idle state
    func reset() {
        amplitudes = Array(repeating: 0.1, count: 32)
    }
}

#Preview {
    VStack(spacing: 20) {
        // Active waveform
        WaveformView(
            amplitudes: [0.3, 0.5, 0.8, 0.6, 0.4, 0.7, 0.9, 0.5, 0.3, 0.6, 0.8, 0.4],
            isActive: true,
            accentColor: .blue
        )
        .frame(height: 50)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        
        // Idle waveform
        WaveformView(
            amplitudes: [],
            isActive: false,
            accentColor: .green
        )
        .frame(height: 50)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    .padding()
}
