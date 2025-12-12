# BlueBubbles MCP Bridge Setup Instructions

Run these commands on the Mac mini where BlueBubbles is installed.

## Prerequisites Check

First, verify BlueBubbles is running and get its API details:

```bash
# Check if BlueBubbles is running
ps aux | grep -i bluebubbles

# Get your BlueBubbles server URL and password from the BlueBubbles app
# Usually: http://localhost:1234 (check BlueBubbles Settings > API)
```

## Step 1: Install Node.js (if not installed)

```bash
# Check if Node.js is installed
node --version

# If not installed, install via Homebrew
brew install node

# Verify installation
node --version  # Should be v18+ 
npm --version
```

## Step 2: Install Cloudflare Tunnel

```bash
# Install cloudflared via Homebrew
brew install cloudflared

# Verify installation
cloudflared --version
```

## Step 3: Create the MCP Bridge Directory

```bash
# Create directory
sudo mkdir -p /opt/imessage-bridge
sudo chown $(whoami) /opt/imessage-bridge
cd /opt/imessage-bridge
```

## Step 4: Initialize the Project

```bash
cd /opt/imessage-bridge

# Initialize npm project
npm init -y

# Install dependencies
npm install @modelcontextprotocol/sdk express cors dotenv node-fetch
```

## Step 5: Create Environment File

```bash
cd /opt/imessage-bridge

cat > .env << 'EOF'
# BlueBubbles Configuration
BLUEBUBBLES_URL=http://localhost:1234
BLUEBUBBLES_PASSWORD=your_bluebubbles_password_here

# MCP Server Configuration  
MCP_PORT=3000
MCP_BEARER_TOKEN=your_secure_random_token_here

# Generate a secure token with: openssl rand -hex 32
EOF

# Generate a secure bearer token
echo "MCP_BEARER_TOKEN=$(openssl rand -hex 32)" >> .env.example
```

**IMPORTANT:** Edit `.env` and fill in:
- `BLUEBUBBLES_PASSWORD` - Found in BlueBubbles app > Settings > API > Server Password
- `BLUEBUBBLES_URL` - Usually `http://localhost:1234` (check BlueBubbles Settings)
- `MCP_BEARER_TOKEN` - Generate with `openssl rand -hex 32`

## Step 6: Create the MCP Server

Create the main server file:

```bash
cd /opt/imessage-bridge
mkdir -p src
```

Then create `src/index.js` with the content from the `index.js` file in this folder.

## Step 7: Test Locally

```bash
cd /opt/imessage-bridge

# Start the server
node src/index.js

# In another terminal, test it:
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

## Step 8: Set Up Cloudflare Tunnel

```bash
# Login to Cloudflare (opens browser)
cloudflared tunnel login

# Create a named tunnel
cloudflared tunnel create imessage-bridge

# Note the tunnel ID that's displayed (like: a]1234abcd-5678-efgh-ijkl-9876543210ab)
```

## Step 9: Configure the Tunnel

```bash
# Create tunnel config
mkdir -p ~/.cloudflared

cat > ~/.cloudflared/config.yml << 'EOF'
tunnel: YOUR_TUNNEL_ID_HERE
credentials-file: /Users/YOUR_USERNAME/.cloudflared/YOUR_TUNNEL_ID_HERE.json

ingress:
  - hostname: <your-imessage-hostname>
    service: http://localhost:3000
  - service: http_status:404
EOF
```

**Replace:**
- `YOUR_TUNNEL_ID_HERE` with your actual tunnel ID
- `YOUR_USERNAME` with your macOS username
- `<your-imessage-hostname>` with your desired subdomain

## Step 10: Set Up DNS

```bash
# Create DNS record pointing to your tunnel
cloudflared tunnel route dns imessage-bridge <your-imessage-hostname>
```

## Step 11: Install pm2 for Process Management

```bash
# Install pm2 globally
npm install -g pm2

# Start the MCP server with pm2
cd /opt/imessage-bridge
pm2 start src/index.js --name imessage-bridge

# Start the tunnel with pm2
pm2 start cloudflared --name cloudflare-tunnel -- tunnel run imessage-bridge

# Save pm2 configuration
pm2 save

# Set up pm2 to start on boot
pm2 startup
# Follow the instructions it prints
```

## Step 12: Verify Everything Works

```bash
# Check processes are running
pm2 status

# Check logs
pm2 logs imessage-bridge
pm2 logs cloudflare-tunnel

# Test from the internet
curl -X POST https://<your-imessage-hostname>/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

## Troubleshooting

### BlueBubbles API not responding
```bash
# Check BlueBubbles is running
ps aux | grep BlueBubbles

# Test BlueBubbles API directly
curl "http://localhost:1234/api/v1/server/info?password=YOUR_BB_PASSWORD"
```

### MCP Server not starting
```bash
# Check logs
pm2 logs imessage-bridge --lines 50

# Check for port conflicts
lsof -i :3000
```

### Tunnel not working
```bash
# Check tunnel status
cloudflared tunnel info imessage-bridge

# Check tunnel logs
pm2 logs cloudflare-tunnel --lines 50
```

## iOS App Configuration

Once everything is running, configure the Jarvis iOS app:

1. Open Jarvis app > Settings
2. Enable "Custom MCP Server"
3. Server Label: `bluebubbles`
4. Server URL: `https://<your-imessage-hostname>/mcp`
5. Auth Token: Your `MCP_BEARER_TOKEN` value

Test by asking Jarvis to "send a test message to [phone number]"
