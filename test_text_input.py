#!/usr/bin/env python3
"""
Test what exact format works with the native audio model for voice input.
We'll try different approaches to trigger a model response.
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

async def test_approaches():
    print("🧪 Testing Different Approaches to Trigger Model Response")
    print(f"Model: {MODEL}")
    
    # Setup with automatic VAD enabled (default)
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
                "parts": [{"text": "You are a helpful assistant. When you receive any input, just say 'Hello, I hear you!'"}]
            }
        }
    }
    
    try:
        async with websockets.connect(ENDPOINT) as ws:
            print("✅ Connected!")
            
            await ws.send(json.dumps(setup_message))
            response = await ws.recv()
            print(f"📥 Setup response: {json.loads(response)}")
            
            # Approach 1: Send text input using clientContent (this should definitely work)
            print("\n--- APPROACH 1: Text Input with clientContent ---")
            text_message = {
                "clientContent": {
                    "turns": [
                        {
                            "role": "user",
                            "parts": [{"text": "Hello! Say hi back."}]
                        }
                    ],
                    "turnComplete": True
                }
            }
            await ws.send(json.dumps(text_message))
            print("📤 Text sent!")
            
            # Wait for response
            print("📥 Waiting...")
            while True:
                msg = await asyncio.wait_for(ws.recv(), timeout=15.0)
                msg_json = json.loads(msg)
                keys = list(msg_json.keys())
                print(f"   Received: {keys}")
                
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
                        
            print("\n🎉 Approach 1 worked! Text input triggers responses properly.")
            
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")

if __name__ == "__main__":
    asyncio.run(test_approaches())
