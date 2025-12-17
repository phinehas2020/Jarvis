import SwiftUI

/// A premium connection status indicator with animated states
struct ConnectionStatusView: View {
    let status: ConnectionStatus
    let eventType: String
    
    @State private var pulseAnimation = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Animated status indicator
            ZStack {
                // Outer pulse ring (when connecting)
                if status == .connecting {
                    Circle()
                        .stroke(statusColor.opacity(0.3), lineWidth: 2)
                        .frame(width: 20, height: 20)
                        .scaleEffect(pulseAnimation ? 1.5 : 1.0)
                        .opacity(pulseAnimation ? 0 : 0.7)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false), value: pulseAnimation)
                }
                
                // Main indicator
                Circle()
                    .fill(statusGradient)
                    .frame(width: 12, height: 12)
                    .shadow(color: statusColor.opacity(0.5), radius: status == .connected ? 4 : 0)
            }
            .frame(width: 22, height: 22)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(status.description)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(statusColor)
                
                if !eventType.isEmpty && status == .connected {
                    Text(eventType)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(statusColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusColor.opacity(0.2), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.3), value: status)
        .onAppear {
            pulseAnimation = true
        }
    }
    
    private var statusColor: Color {
        status.color
    }
    
    private var statusGradient: LinearGradient {
        switch status {
        case .connected:
            return LinearGradient(
                colors: [.green.opacity(0.8), .green],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .connecting:
            return LinearGradient(
                colors: [.yellow.opacity(0.8), .orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .disconnected:
            return LinearGradient(
                colors: [.gray.opacity(0.6), .gray],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ConnectionStatusView(status: .connected, eventType: "response.audio.delta")
        ConnectionStatusView(status: .connecting, eventType: "")
        ConnectionStatusView(status: .disconnected, eventType: "")
    }
    .padding()
    .background(Color(.systemBackground))
}
