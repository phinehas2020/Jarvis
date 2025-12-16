#!/usr/bin/env python3
"""
Test to simulate continuous audio streaming like the iOS app does.
This will help us identify if the issue is with audio streaming or tools.
"""

import asyncio
import json
import base64
import struct
import math

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "models/gemini-2.5-flash-native-audio-preview-12-2025"
ENDPOINT = f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}"

def generate_silent_audio(duration_ms: int, sample_rate: int = 16000) -> bytes:
    """Generate silent 16-bit PCM audio."""
    num_samples = int(sample_rate * duration_ms / 1000)
    return struct.pack(f'<{num_samples}h', *[0] * num_samples)

def generate_tone_audio(duration_ms: int, frequency: float = 440.0, sample_rate: int = 16000) -> bytes:
    """Generate a sine wave tone as 16-bit PCM audio."""
    num_samples = int(sample_rate * duration_ms / 1000)
    samples = []
    for i in range(num_samples):
        t = i / sample_rate
        sample = int(32767 * 0.3 * math.sin(2 * math.pi * frequency * t))
        samples.append(sample)
    return struct.pack(f'<{num_samples}h', *samples)

async def test_audio_streaming():
    """Test audio streaming to Gemini Live API."""
    import websockets
    
    print("🧪 Testing Audio Streaming to Gemini Live API")
    print(f"Model: {MODEL}")
    
    # Minimal setup WITHOUT tools (to isolate the issue)
    setup_message = {
        "setup": {
            "model": MODEL,
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
                "parts": [{"text": "You are a helpful assistant. Keep responses very brief."}]
            }
            # NO TOOLS - testing minimal setup
        }
    }
    
    try:
        async with websockets.connect(ENDPOINT) as ws:
            print("✅ Connected!")
            
            # Send setup
            await ws.send(json.dumps(setup_message))
            print("📤 Setup sent (no tools)")
            
            # Wait for setupComplete
            response = await asyncio.wait_for(ws.recv(), timeout=10.0)
            response_json = json.loads(response)
            print(f"📥 Response: {response_json}")
            
            if "setupComplete" not in response_json:
                print("❌ Setup failed!")
                return
            
            print("✅ Setup complete!")
            
            # Simulate streaming silent audio for 2 seconds (like iOS would do)
            print("\n📤 Starting audio stream (2 seconds of silence)...")
            chunk_duration_ms = 100  # 100ms chunks like iOS
            total_chunks = 20  # 2 seconds total
            
            for i in range(total_chunks):
                audio_data = generate_silent_audio(chunk_duration_ms)
                message = {
                    "realtimeInput": {
                        "mediaChunks": [
                            {
                                "mimeType": "audio/pcm;rate=16000",
                                "data": base64.b64encode(audio_data).decode('utf-8')
                            }
                        ]
                    }
                }
                await ws.send(json.dumps(message))
                if i == 0:
                    print(f"   Chunk 1/{total_chunks} sent ({len(audio_data)} bytes)")
                await asyncio.sleep(0.1)  # 100ms between chunks
            
            print(f"   ... {total_chunks} chunks sent")
            
            # Now send a brief tone (simulating speech)
            print("\n📤 Sending 'speech' (short tone)...")
            speech_audio = generate_tone_audio(500)  # 500ms of tone
            message = {
                "realtimeInput": {
                    "mediaChunks": [
                        {
                            "mimeType": "audio/pcm;rate=16000",
                            "data": base64.b64encode(speech_audio).decode('utf-8')
                        }
                    ]
                }
            }
            await ws.send(json.dumps(message))
            print(f"   Speech audio sent ({len(speech_audio)} bytes)")
            
            # Send turnComplete
            print("\n📤 Sending turnComplete...")
            turn_complete = {
                "clientContent": {
                    "turnComplete": True
                }
            }
            await ws.send(json.dumps(turn_complete))
            print("   turnComplete sent!")
            
            # Wait for response
            print("\n📥 Waiting for model response...")
            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=30.0)
                    msg_json = json.loads(msg)
                    
                    if "serverContent" in msg_json:
                        sc = msg_json["serverContent"]
                        if "modelTurn" in sc:
                            parts = sc["modelTurn"].get("parts", [])
                            for part in parts:
                                if "text" in part:
                                    print(f"   TEXT: {part['text'][:100]}")
                                if "inlineData" in part:
                                    mime = part["inlineData"].get("mimeType", "unknown")
                                    data_len = len(part["inlineData"].get("data", ""))
                                    print(f"   AUDIO: {mime} ({data_len} bytes)")
                        if sc.get("turnComplete"):
                            print("   ✅ Turn complete!")
                            break
                    else:
                        print(f"   Other: {list(msg_json.keys())}")
                        
            except asyncio.TimeoutError:
                print("   ⏱️ Timeout waiting for response")
            
            print("\n🎉 Test completed successfully!")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test_audio_streaming())
