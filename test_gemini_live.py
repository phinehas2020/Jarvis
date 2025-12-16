#!/usr/bin/env python3
"""
Test script for Gemini Live API WebSocket connection.
This script tests the basic connection and setup flow.
"""

import asyncio
import json
import websockets

API_KEY = "AIzaSyCdQEuFNKgWtWR0116y2VSwAVSi1FR6SHo"
MODEL = "models/gemini-2.5-flash-native-audio-preview-12-2025"

# Try different endpoint variations
ENDPOINTS = [
    f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={API_KEY}",
    f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key={API_KEY}",
]

SETUP_MESSAGE = {
    "setup": {
        "model": MODEL,
        "generationConfig": {
            "responseModalities": ["AUDIO", "TEXT"],
            "speechConfig": {
                "voiceConfig": {
                    "prebuiltVoiceConfig": {
                        "voiceName": "Puck"
                    }
                }
            }
        },
        "systemInstruction": {
            "parts": [{"text": "You are a helpful assistant. Say hello when connected."}]
        }
    }
}

async def test_endpoint(endpoint_url: str, name: str):
    print(f"\n{'='*60}")
    print(f"Testing: {name}")
    print(f"URL: {endpoint_url[:80]}...")
    print(f"{'='*60}")
    
    try:
        async with websockets.connect(endpoint_url) as ws:
            print("✅ WebSocket connected!")
            
            # Send setup message
            setup_json = json.dumps(SETUP_MESSAGE)
            print(f"📤 Sending setup message ({len(setup_json)} bytes)...")
            await ws.send(setup_json)
            print("📤 Setup message sent!")
            
            # Wait for response
            print("⏳ Waiting for response...")
            try:
                response = await asyncio.wait_for(ws.recv(), timeout=10.0)
                print(f"📥 Received response ({len(response)} bytes):")
                
                try:
                    response_json = json.loads(response)
                    print(json.dumps(response_json, indent=2)[:500])
                    
                    if "setupComplete" in response_json:
                        print("\n🎉 SUCCESS! Setup complete received!")
                        
                        # Try sending a simple text message
                        text_msg = {
                            "clientContent": {
                                "turns": [
                                    {
                                        "role": "user",
                                        "parts": [{"text": "Hello, just say 'hi' briefly."}]
                                    }
                                ],
                                "turnComplete": True
                            }
                        }
                        await ws.send(json.dumps(text_msg))
                        print("📤 Sent text message, waiting for response...")
                        
                        # Wait for model response
                        while True:
                            try:
                                msg = await asyncio.wait_for(ws.recv(), timeout=15.0)
                                msg_json = json.loads(msg)
                                print(f"📥 Message: {json.dumps(msg_json, indent=2)[:300]}")
                                
                                if msg_json.get("serverContent", {}).get("turnComplete"):
                                    print("✅ Turn complete - model responded successfully!")
                                    break
                            except asyncio.TimeoutError:
                                print("⏱️ Timeout waiting for model response")
                                break
                        
                        return True
                    elif "error" in response_json:
                        print(f"❌ Error from server: {response_json['error']}")
                        return False
                except json.JSONDecodeError:
                    print(f"Raw response: {response[:200]}")
                    
            except asyncio.TimeoutError:
                print("❌ Timeout waiting for response")
                return False
                
    except websockets.exceptions.InvalidStatusCode as e:
        print(f"❌ Invalid status code: {e.status_code}")
        if hasattr(e, 'headers'):
            print(f"   Headers: {dict(e.headers)}")
        return False
    except Exception as e:
        print(f"❌ Connection error: {type(e).__name__}: {e}")
        return False
    
    return False

async def main():
    print("🧪 Gemini Live API Connection Test")
    print(f"Model: {MODEL}")
    
    for i, endpoint in enumerate(ENDPOINTS):
        name = f"Endpoint {i+1} ({'v1beta' if 'v1beta' in endpoint else 'v1alpha'})"
        success = await test_endpoint(endpoint, name)
        if success:
            print(f"\n✅ {name} WORKS!")
            print(f"\nUse this endpoint in your iOS app:")
            print(endpoint)
            return
    
    print("\n❌ No endpoints worked. Let's try the official SDK approach...")

if __name__ == "__main__":
    asyncio.run(main())
