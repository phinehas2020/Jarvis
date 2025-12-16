#!/usr/bin/env python3
"""
Test using Google SDK to stream audio and see exactly what it sends.
We'll capture the actual format used.
"""

import asyncio
from google import genai
import base64
import struct
import math

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"

def generate_tone_audio(duration_ms: int, frequency: float = 440.0, sample_rate: int = 16000) -> bytes:
    """Generate a sine wave tone as 16-bit PCM audio."""
    num_samples = int(sample_rate * duration_ms / 1000)
    samples = []
    for i in range(num_samples):
        t = i / sample_rate
        sample = int(32767 * 0.5 * math.sin(2 * math.pi * frequency * t))
        samples.append(sample)
    return struct.pack(f'<{num_samples}h', *samples)

async def main():
    print("🧪 Testing Gemini Live API with Audio Input via SDK")
    print(f"Model: {MODEL}")
    
    client = genai.Client(api_key=API_KEY)
    
    config = {
        "response_modalities": ["AUDIO"],
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
        print("📡 Connecting...")
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("✅ Connected!")
            
            # Send audio using the SDK's method
            print("\n📤 Sending audio input...")
            
            # Generate some audio - a short tone that should trigger a response
            audio_data = generate_tone_audio(1000)  # 1 second
            print(f"   Audio: {len(audio_data)} bytes, 16kHz, 16-bit PCM")
            
            # The SDK provides send_realtime_input for streaming audio
            await session.send_realtime_input(
                audio={"data": base64.b64encode(audio_data).decode('utf-8'), "mime_type": "audio/pcm"}
            )
            print("   Audio sent!")
            
            # Let's also try text input to see if that works
            print("\n📤 Sending text input...")
            await session.send_client_content(
                turns=[{"role": "user", "parts": [{"text": "Hello, say hi briefly!"}]}],
                turn_complete=True
            )
            print("   Text sent!")
            
            print("\n📥 Waiting for response...")
            async for response in session.receive():
                if response.server_content:
                    if response.server_content.model_turn:
                        for part in response.server_content.model_turn.parts:
                            if hasattr(part, 'text') and part.text:
                                print(f"   TEXT: {part.text[:100]}")
                            if hasattr(part, 'inline_data') and part.inline_data:
                                print(f"   AUDIO: {len(part.inline_data.data)} bytes")
                    if response.server_content.turn_complete:
                        print("   ✅ Turn complete!")
                        break
            
            print("\n🎉 SUCCESS!")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())
