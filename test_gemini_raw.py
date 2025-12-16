#!/usr/bin/env python3
"""
Debug script to capture the exact WebSocket messages used by the Gemini Live API.
We'll intercept and log the raw messages to understand the correct format.
"""

import asyncio
import json
import websockets

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"

# v1beta endpoint with API key as query param
ENDPOINT = f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}"

async def test_raw_websocket():
    print("🧪 Raw WebSocket Test for Gemini Live API")
    print(f"Model: {MODEL}")
    print(f"Endpoint: {ENDPOINT[:60]}...")
    
    # This is the exact format from Google's documentation
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
                "parts": [{"text": "You are a helpful assistant."}]
            }
        }
    }
    
    print(f"\n📤 Setup message:")
    print(json.dumps(setup_message, indent=2))
    
    try:
        async with websockets.connect(ENDPOINT) as ws:
            print("\n✅ WebSocket connected!")
            
            # Send setup
            await ws.send(json.dumps(setup_message))
            print("📤 Setup sent!")
            
            # Receive response
            response = await asyncio.wait_for(ws.recv(), timeout=10.0)
            response_json = json.loads(response)
            print(f"\n📥 Response:")
            print(json.dumps(response_json, indent=2))
            
            if "setupComplete" in response_json:
                print("\n🎉 SETUP COMPLETE!")
                
                # Send a text message
                text_message = {
                    "clientContent": {
                        "turns": [
                            {
                                "role": "user",
                                "parts": [{"text": "Hello, say hi briefly."}]
                            }
                        ],
                        "turnComplete": True
                    }
                }
                
                print(f"\n📤 Sending text message:")
                print(json.dumps(text_message, indent=2))
                await ws.send(json.dumps(text_message))
                
                # Receive responses
                print("\n📥 Receiving responses:")
                while True:
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=15.0)
                        msg_json = json.loads(msg)
                        
                        # Log key parts only to avoid spam
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
                                        print(f"   AUDIO: {mime} ({data_len} bytes base64)")
                            if sc.get("turnComplete"):
                                print("   ✅ Turn complete!")
                                break
                        elif "toolCall" in msg_json:
                            print(f"   TOOL CALL: {msg_json['toolCall']}")
                        else:
                            print(f"   OTHER: {list(msg_json.keys())}")
                            
                    except asyncio.TimeoutError:
                        print("⏱️ Timeout")
                        break
                
                print("\n🎉 SUCCESS! Raw WebSocket works!")
                return True
            else:
                print(f"❌ Unexpected response: {response_json}")
                return False
                
    except Exception as e:
        print(f"❌ Error: {type(e).__name__}: {e}")
        return False

if __name__ == "__main__":
    asyncio.run(test_raw_websocket())
