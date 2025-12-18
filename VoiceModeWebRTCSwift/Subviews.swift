import SwiftUI

// MARK: - App Header
struct AppHeaderView: View {
    let title: String
    let onShowOptions: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: onShowOptions) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Circle().fill(Color(.systemGray6)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }
}

// MARK: - Conversation List Row
struct ConversationRow: View {
    let item: ConversationItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(item.role == "user" ? Color.blue : Color.gray.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(item.role == "user" ? "U" : "J")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(item.role == "user" ? .white : .primary)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.role == "user" ? "You" : "Jarvis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text(item.text)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(item.role == "user" ? Color.blue.opacity(0.05) : Color.clear)
        )
    }
}

// MARK: - Empty State View
struct EmptyConversationView: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundColor(.blue.opacity(0.3))
            
            Text(title)
                .font(.headline)
            
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
