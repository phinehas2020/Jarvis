#!/usr/bin/env python3
"""
Test ONLY audio input (no text) - simulating voice-only interaction.
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
    print("🧪 Testing Gemini Live API - Audio ONLY Input")
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
            
            # Stream audio in chunks (simulating real microphone input)
            print("\n📤 Streaming audio in chunks...")
            
            # First, stream some "silence" (low level)
            for i in range(5):
                chunk = generate_tone_audio(100, frequency=0)  # 100ms silence
                await session.send_realtime_input(
                    audio={"data": base64.b64encode(chunk).decode('utf-8'), "mime_type": "audio/pcm"}
                )
                print(f"   Silence chunk {i+1}/5")
                await asyncio.sleep(0.1)
            
            # Then stream the actual "speech" (a tone)
            print("\n📤 Sending 'speech' audio...")
            speech = generate_tone_audio(1000, frequency=440)  # 1 second tone
            await session.send_realtime_input(
                audio={"data": base64.b64encode(speech).decode('utf-8'), "mime_type": "audio/pcm"}
            )
            print("   Speech sent!")
            
            # Now we need to signal end of turn
            # According to docs, we can send end_of_turn
            print("\n📤 Signaling end of turn...")
            
            # For Live API with audio, the model should auto-detect turn boundaries
            # But we can also explicitly end the turn
            # Let's wait for the response without explicitly ending
            
            print("\n📥 Waiting for response (with timeout)...")
            try:
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
            except asyncio.TimeoutError:
                print("   ⏱️ No response received (timeout)")
            
            print("\n🎉 Test completed!")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())
