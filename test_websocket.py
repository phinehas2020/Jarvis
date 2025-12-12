import asyncio
import websockets
import json
import os

async def test_websocket():
    uri = os.getenv("MCP_URL", "wss://YOUR_MCP_HOST/mcp?token=YOUR_TOKEN")
    headers = {
        "Sec-WebSocket-Protocol": "mcp"
    }
    try:
        async with websockets.connect(uri, extra_headers=headers, subprotocols=["mcp"]) as websocket:
            print("Connection successful!")
            
            # Send a tools/list RPC request
            list_tools_request = {
                "jsonrpc": "2.0",
                "method": "tools/list",
                "id": 1
            }
            await websocket.send(json.dumps(list_tools_request))
            print(f"Sent list_tools request: {list_tools_request}")

            # Receive and print the response
            response = await websocket.recv()
            print(f"Received response: {response}")

    except Exception as e:
        print(f"Connection failed: {e}")

asyncio.run(test_websocket())
