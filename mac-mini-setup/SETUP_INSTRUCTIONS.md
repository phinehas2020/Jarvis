# BlueBubbles MCP Bridge & Computer Agent Setup

This guide will help you set up the Jarvis server component on your Mac Mini. This bridge enables iMessage control and the "Computer Agent" desktop automation features.

## 🛠️ Prerequisites

1.  **BlueBubbles Server**: Installed and running on your Mac.
2.  **iMessage Account**: Logged in on the Mac.
3.  **Node.js**: v18 or newer installed (`brew install node`).
4.  **PM2**: Process manager (`npm install -g pm2`).
5.  **Cloudflare Tunnel**: (Optional but recommended) for secure remote access.

## Step 1: Prepare the Directory

```bash
sudo mkdir -p /opt/imessage-bridge
sudo chown $(whoami) /opt/imessage-bridge
cd /opt/imessage-bridge
```

## Step 2: Install Dependencies

```bash
cd /opt/imessage-bridge
npm init -y
npm install @modelcontextprotocol/sdk express cors dotenv node-fetch openai playwright
npx playwright install chromium
```

## Step 3: Configure Environment Variables

Create a `.env` file in `/opt/imessage-bridge/`:

```env
# --- BlueBubbles ---
BLUEBUBBLES_URL=http://localhost:1234
BLUEBUBBLES_PASSWORD=your_server_password

# --- MCP Security ---
MCP_PORT=3000
MCP_BEARER_TOKEN=your_secure_random_token

# --- AI Models (for Computer Agent) ---
# Required for the background computer agent to think
OPENAI_API_KEY=sk-....
XAI_API_KEY=xai-....

# --- Agent Tuning ---
# Defaults to grok-4-1-fast-non-reasoning for max speed
COMPUTER_AGENT_MODEL=grok-4-1-fast-non-reasoning
COMPUTER_AGENT_MAX_STEPS=20
```

> [!TIP]
> Generate a secure token with `openssl rand -hex 32`.

## Step 4: Deploy the Code

Copy the following files from this repository to `/opt/imessage-bridge/src/`:
1.  `mac-mini-setup/src/index.js` -> `src/index.js`
2.  `mac-mini-setup/src/computer-agent.js` -> `src/computer-agent.js`
3.  `mac-mini-setup/src/desktop-tools.js` -> `src/desktop-tools.js` (if present)
4.  `mac-mini-setup/src/browser-tools.js` -> `src/browser-tools.js`
5.  `mac-mini-setup/ComputerAgentPrompt.md` -> `../ComputerAgentPrompt.md` (relative to index.js)

## Step 5: Start with PM2

PM2 ensures the bridge starts automatically if the Mac restarts.

```bash
cd /opt/imessage-bridge
pm2 start src/index.js --name imessage-bridge
pm2 save
pm2 startup
```

## Step 6: Expose to the Internet

If you aren't using a VPN, use a Cloudflare Tunnel:
1.  `brew install cloudflared`
2.  `cloudflared tunnel login`
3.  `cloudflared tunnel create jarvis-bridge`
4.  Configure your `~/.cloudflared/config.yml` to point `localhost:3000` to a subdomain.
5.  `pm2 start cloudflared --name tunnel -- tunnel run jarvis-bridge`

---

## 🔧 Available Tools

Once the bridge is connected to the iOS app, Jarvis can perform these actions:

### **iMessage & BlueBubbles**
- `send_imessage`: Send text or attachments.
- `send_tapback`: Send heart, like, laugh, etc.
- `rename_group`: Rename any group chat.
- `mark_chat_read`: Mark chats as read.
- `fetch_messages`: Get chat history.

### **Computer Automation**
- `execute_task`: Triggers the **Computer Agent**.
  - **Foreground**: Jarvis waits for the result.
  - **Background**: Jarvis finishes the conversation and pings your phone when the task is done.

## ❓ Troubleshooting

- **"Context is not defined"**: Ensure you have the latest `index.js`.
- **Agent is slow**: Verify `COMPUTER_AGENT_MODEL` is set to a "fast" or "non-reasoning" variant.
- **Microphone issues**: WebRTC requires a physical iOS device; simulator audio is often unreliable.

---

*Documentation updated: Dec 2025*
