import asyncio
import websockets
import json

async def test_websocket():
    uri = "wss://imessage.phinehasadams.com/mcp?token=6zXYRXIQcZHKOo__2sImBYqgj3yktutHR9B6OSk2Y4Y"
    headers = {
        "Sec-WebSocket-Protocol": "mcp"
    }
    try:
        async with websockets.connect(uri, extra_headers=headers, subprotocols=["mcp"]) as websocket:
            print("Connection successful!")
            
            # Send a list_tools RPC request
            list_tools_request = {
                "jsonrpc": "2.0",
                "method": "list_tools",
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