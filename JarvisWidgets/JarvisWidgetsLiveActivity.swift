//
//  JarvisWidgetsLiveActivity.swift
//  JarvisWidgets
//
//  Created by Phinehas Adams on 12/18/25.
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct JarvisWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            // Lock screen/banner UI
            VStack(spacing: 0) {
                HStack {
                    // Left Side: Status & Branding
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            StatusIndicator(isConnected: context.state.status == "Connected")
                            
                            Text("JARVIS")
                                .font(.system(.subheadline, design: .rounded))
                                .fontWeight(.black)
                                .foregroundColor(.white)
                                .tracking(1.5)
                        }
                        
                        Text(context.state.status.uppercased())
                            .font(.system(.caption2, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    // Right Side: Action Buttons
                    HStack(spacing: 12) {
                        if context.state.status == "Connected" {
                            Button(intent: ToggleMuteIntent()) {
                                ZStack {
                                    Circle()
                                        .fill(context.state.isMuted ? Color.red.opacity(0.2) : Color.blue.opacity(0.2))
                                        .frame(width: 44, height: 44)
                                    
                                    Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(context.state.isMuted ? .red : .blue)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(intent: StartJarvisIntent()) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 44, height: 44)
                                        .shadow(color: .purple.opacity(0.5), radius: 8, x: 0, y: 4)
                                    
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background {
                ZStack {
                    Color.black
                    LinearGradient(
                        colors: [Color.purple.opacity(0.15), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .activityBackgroundTint(Color.black.opacity(0.9))
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("JARVIS")
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.black)
                            .foregroundColor(.purple)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 12)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 12) {
                        if context.state.status == "Connected" {
                            Button(intent: ToggleMuteIntent()) {
                                Image(systemName: context.state.isMuted ? "mic.slash.circle.fill" : "mic.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(context.state.isMuted ? .red : .blue)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(intent: StartJarvisIntent()) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.purple)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 12)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(context.state.status)
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Text(context.state.status == "Connected" ? "Tap to Mute" : "Tap Play to Start")
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.bottom, 12)
                }
                
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.system(size: 14, weight: .bold))
            } compactTrailing: {
                if context.state.status == "Connected" {
                    Image(systemName: context.state.isMuted ? "mic.slash" : "mic")
                        .foregroundColor(context.state.isMuted ? .red : .blue)
                        .font(.system(size: 14, weight: .bold))
                } else {
                    Image(systemName: "play.fill")
                        .foregroundColor(.purple)
                        .font(.system(size: 14, weight: .bold))
                }
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.system(size: 14, weight: .bold))
            }
            .keylineTint(Color.purple)
        }
    }
}

struct StatusIndicator: View {
    let isConnected: Bool
    @State private var pulsing = false
    
    var body: some View {
        ZStack {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            
            if isConnected {
                Circle()
                    .stroke(Color.green.opacity(0.5), lineWidth: 2)
                    .frame(width: pulsing ? 16 : 8, height: pulsing ? 16 : 8)
                    .opacity(pulsing ? 0 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                            pulsing = true
                        }
                    }
            }
        }
    }
}
