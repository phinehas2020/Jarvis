#!/usr/bin/env python3
"""
Test script for Gemini Live API using the official Google GenAI SDK.
"""

import asyncio
from google import genai

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"

async def main():
    print("🧪 Testing Gemini Live API with Official SDK")
    print(f"Model: {MODEL}")
    
    # Create client with API key
    client = genai.Client(api_key=API_KEY)
    
    config = {
        "response_modalities": ["AUDIO"],  # Native audio model requires AUDIO
        "system_instruction": "You are a helpful assistant. Respond briefly.",
        "speech_config": {
            "voice_config": {
                "prebuilt_voice_config": {
                    "voice_name": "Puck"
                }
            }
        }
    }
    
    try:
        print("📡 Connecting to Gemini Live API...")
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("✅ Connected to Gemini Live API!")
            
            # Send a simple text message
            print("📤 Sending test message...")
            await session.send_client_content(
                turns=[{"role": "user", "parts": [{"text": "Say hello in one sentence."}]}],
                turn_complete=True
            )
            
            print("⏳ Waiting for response...")
            async for response in session.receive():
                if response.server_content:
                    if response.server_content.model_turn:
                        for part in response.server_content.model_turn.parts:
                            if hasattr(part, 'text') and part.text:
                                print(f"📥 Response: {part.text}")
                    if response.server_content.turn_complete:
                        print("✅ Turn complete!")
                        break
            
            print("\n🎉 SUCCESS! The connection works!")
            print("\nNow we know the correct API format. Let's examine the session details...")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())
