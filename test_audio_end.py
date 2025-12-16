#!/usr/bin/env python3
"""
Test the correct way to end audio input - using audioStreamEnd in realtimeInput.
"""

import asyncio
import json
import base64
import struct
import math
import websockets

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "models/gemini-2.5-flash-native-audio-preview-12-2025"
ENDPOINT = f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}"

def generate_tone_audio(duration_ms: int, frequency: float = 440.0, sample_rate: int = 16000) -> bytes:
    """Generate a sine wave tone as 16-bit PCM audio."""
    num_samples = int(sample_rate * duration_ms / 1000)
    samples = []
    for i in range(num_samples):
        t = i / sample_rate
        sample = int(32767 * 0.5 * math.sin(2 * math.pi * frequency * t))
        samples.append(sample)
    return struct.pack(f'<{num_samples}h', *samples)

async def test_audio_stream_end():
    print("🧪 Testing audioStreamEnd for audio input")
    print(f"Model: {MODEL}")
    
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
                "parts": [{"text": "You are a helpful assistant. Say hello when you hear audio."}]
            }
        }
    }
    
    try:
        async with websockets.connect(ENDPOINT) as ws:
            print("✅ Connected!")
            
            await ws.send(json.dumps(setup_message))
            response = await ws.recv()
            print(f"📥 Setup response: {json.loads(response)}")
            
            # Send some audio
            print("\n📤 Sending audio...")
            audio_data = generate_tone_audio(500, 440)  # 500ms tone
            audio_message = {
                "realtimeInput": {
                    "mediaChunks": [
                        {
                            "mimeType": "audio/pcm;rate=16000",
                            "data": base64.b64encode(audio_data).decode('utf-8')
                        }
                    ]
                }
            }
            await ws.send(json.dumps(audio_message))
            print("   Audio sent!")
            
            # Now send audioStreamEnd to signal we're done with audio input
            print("\n📤 Sending audioStreamEnd...")
            end_message = {
                "realtimeInput": {
                    "audioStreamEnd": True
                }
            }
            await ws.send(json.dumps(end_message))
            print("   audioStreamEnd sent!")
            
            # Wait for response
            print("\n📥 Waiting for model response...")
            try:
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout=15.0)
                    msg_json = json.loads(msg)
                    
                    if "serverContent" in msg_json:
                        sc = msg_json["serverContent"]
                        if "modelTurn" in sc:
                            parts = sc["modelTurn"].get("parts", [])
                            for part in parts:
                                if "text" in part:
                                    print(f"   TEXT: {part['text'][:100]}")
                                if "inlineData" in part:
                                    data_len = len(part["inlineData"].get("data", ""))
                                    print(f"   AUDIO: {data_len} bytes")
                        if sc.get("turnComplete"):
                            print("   ✅ Turn complete!")
                            break
                    else:
                        print(f"   Other: {list(msg_json.keys())}")
                        
            except asyncio.TimeoutError:
                print("   ⏱️ Timeout")
            
            print("\n🎉 SUCCESS! audioStreamEnd works!")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")

if __name__ == "__main__":
    asyncio.run(test_audio_stream_end())
