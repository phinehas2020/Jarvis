#!/usr/bin/env python3
"""
Test audio input with different signal types to see what triggers a response.
"""

import asyncio
import json
import base64
import struct
import math
import websockets
from google import genai

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

async def test_audio_then_text():
    """Test sending audio followed by text to trigger processing."""
    print("🧪 Testing: Audio THEN Text to trigger processing")
    
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
        async with client.aio.live.connect(model=MODEL, config=config) as session:
            print("✅ Connected!")
            
            # Send audio chunks
            print("📤 Sending audio chunks...")
            for i in range(10):
                chunk = generate_tone_audio(100, 440)  # 100ms chunks
                await session.send_realtime_input(
                    audio={"data": base64.b64encode(chunk).decode('utf-8'), "mime_type": "audio/pcm"}
                )
            print("   Audio sent!")
            
            # Now send a text message after audio - this tells model to respond
            print("📤 Sending text after audio...")
            await session.send_client_content(
                turns=[{"role": "user", "parts": [{"text": "What did you hear?"}]}],
                turn_complete=True
            )
            
            print("📥 Waiting for response...")
            async for response in session.receive():
                if response.server_content:
                    if response.server_content.model_turn:
                        for part in response.server_content.model_turn.parts:
                            if hasattr(part, 'text') and part.text:
                                print(f"   TEXT: {part.text[:200]}")
                            if hasattr(part, 'inline_data') and part.inline_data:
                                print(f"   AUDIO: {len(part.inline_data.data)} bytes")
                    if response.server_content.turn_complete:
                        print("   ✅ Turn complete!")
                        break
            
            print("\n🎉 Audio + Text approach works!")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

async def test_pure_audio_with_activity():
    """Test using activityStart/activityEnd signals."""
    print("\n🧪 Testing: Pure Audio with activityStart/activityEnd")
    
    ENDPOINT = f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}"
    
    setup_message = {
        "setup": {
            "model": f"models/{MODEL}",
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {
                        "prebuiltVoiceConfig": {
                            "voiceName": "Puck"
                        }
                    }
                }
            },
            "systemInstruction": {
                "parts": [{"text": "You are a helpful assistant. When you hear audio, say hello."}]
            },
            # Disable automatic VAD so we control it
            "realtimeInputConfig": {
                "automaticActivityDetection": {
                    "disabled": True
                }
            }
        }
    }
    
    try:
        async with websockets.connect(ENDPOINT) as ws:
            print("✅ Connected!")
            
            await ws.send(json.dumps(setup_message))
            response = await ws.recv()
            print(f"📥 Setup: {json.loads(response)}")
            
            # Send activityStart
            print("📤 Sending activityStart...")
            await ws.send(json.dumps({
                "realtimeInput": {
                    "activityStart": {}
                }
            }))
            
            # Send audio
            print("📤 Sending audio...")
            audio = generate_tone_audio(1000, 440)
            await ws.send(json.dumps({
                "realtimeInput": {
                    "mediaChunks": [{
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64.b64encode(audio).decode('utf-8')
                    }]
                }
            }))
            
            # Send activityEnd
            print("📤 Sending activityEnd...")
            await ws.send(json.dumps({
                "realtimeInput": {
                    "activityEnd": {}
                }
            }))
            
            # Wait for response
            print("📥 Waiting for response...")
            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=10.0)
                    msg_json = json.loads(msg)
                    keys = list(msg_json.keys())
                    print(f"   Received: {keys}")
                    
                    if "serverContent" in msg_json:
                        sc = msg_json["serverContent"]
                        if sc.get("turnComplete"):
                            print("   ✅ Turn complete!")
                            break
            except asyncio.TimeoutError:
                print("   ⏱️ Timeout")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")

async def main():
    await test_audio_then_text()
    await test_pure_audio_with_activity()

if __name__ == "__main__":
    asyncio.run(main())
