#!/bin/bash
# Quick Setup Script for BlueBubbles MCP Bridge
# Run this on your Mac mini where BlueBubbles is installed

set -e

echo "🚀 BlueBubbles MCP Bridge Quick Setup"
echo "======================================"

# Check for Node.js
if ! command -v node &> /dev/null; then
    echo "❌ Node.js not found. Installing via Homebrew..."
    if ! command -v brew &> /dev/null; then
        echo "Installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install node
fi
echo "✅ Node.js $(node --version)"

# Check for cloudflared
if ! command -v cloudflared &> /dev/null; then
    echo "📦 Installing cloudflared..."
    brew install cloudflared
fi
echo "✅ cloudflared $(cloudflared --version)"

# Create directory
echo "📁 Creating /opt/imessage-bridge..."
sudo mkdir -p /opt/imessage-bridge
sudo chown $(whoami) /opt/imessage-bridge

# Clone or copy files
cd /opt/imessage-bridge

# Create package.json
cat > package.json << 'PACKAGE_EOF'
{
  "name": "imessage-bridge",
  "version": "1.0.0",
  "description": "BlueBubbles MCP Bridge for Jarvis AI Assistant",
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.21.0"
  }
}
PACKAGE_EOF

# Create src directory
mkdir -p src

# Create the MCP server
cat > src/index.js << 'SERVER_EOF'
/**
 * BlueBubbles MCP Bridge Server
 */
import 'dotenv/config';
import express from 'express';
import cors from 'cors';

const app = express();
app.use(cors());
app.use(express.json());

const CONFIG = {
  port: process.env.MCP_PORT || 3000,
  bearerToken: process.env.MCP_BEARER_TOKEN,
  bluebubbles: {
    url: process.env.BLUEBUBBLES_URL || 'http://localhost:1234',
    password: process.env.BLUEBUBBLES_PASSWORD
  }
};

if (!CONFIG.bearerToken) { console.error('❌ MCP_BEARER_TOKEN required'); process.exit(1); }
if (!CONFIG.bluebubbles.password) { console.error('❌ BLUEBUBBLES_PASSWORD required'); process.exit(1); }

console.log('🚀 Starting BlueBubbles MCP Bridge...');
console.log(`📡 BlueBubbles URL: ${CONFIG.bluebubbles.url}`);

async function bbFetch(path, options = {}) {
  const url = new URL(path, CONFIG.bluebubbles.url);
  url.searchParams.set('password', CONFIG.bluebubbles.password);
  const response = await fetch(url.toString(), {
    ...options,
    headers: { 'Content-Type': 'application/json', ...options.headers }
  });
  const data = await response.json();
  return { status: response.status, data };
}

const TOOLS = [
  { name: 'bluebubbles_health', description: 'Check BlueBubbles server health', inputSchema: { type: 'object', properties: {}, required: [] } },
  { name: 'bluebubbles_list_chats', description: 'List/search chats', inputSchema: { type: 'object', properties: { limit: { type: 'number' }, offset: { type: 'number' }, search: { type: 'string' } }, required: [] } },
  { name: 'bluebubbles_get_messages', description: 'Get messages from chat', inputSchema: { type: 'object', properties: { chatGuid: { type: 'string' }, limit: { type: 'number' }, offset: { type: 'number' } }, required: ['chatGuid'] } },
  { name: 'bluebubbles_send_message', description: 'Send message to existing chat', inputSchema: { type: 'object', properties: { chatGuid: { type: 'string' }, message: { type: 'string' }, service: { type: 'string', enum: ['iMessage', 'SMS'] } }, required: ['chatGuid', 'message'] } },
  { name: 'bluebubbles_create_chat', description: 'Create new chat (include message on Big Sur+)', inputSchema: { type: 'object', properties: { addresses: { type: 'array', items: { type: 'string' } }, message: { type: 'string' }, service: { type: 'string' } }, required: ['addresses'] } },
  { name: 'bluebubbles_request', description: 'Raw BlueBubbles API request', inputSchema: { type: 'object', properties: { path: { type: 'string' }, method: { type: 'string' }, body: { type: 'object' } }, required: ['path'] } }
];

async function handleTool(name, args) {
  console.log(`🔧 Tool: ${name}`, JSON.stringify(args));
  try {
    switch (name) {
      case 'bluebubbles_health': return await bbFetch('/api/v1/server/info');
      case 'bluebubbles_list_chats': return await bbFetch('/api/v1/chat/query', { method: 'POST', body: JSON.stringify({ with: args.search ? [args.search] : [], limit: args.limit || 25, offset: args.offset || 0 }) });
      case 'bluebubbles_get_messages': return await bbFetch(`/api/v1/chat/${encodeURIComponent(args.chatGuid)}/message`, { method: 'POST', body: JSON.stringify({ limit: args.limit || 50, offset: args.offset || 0, sort: 'DESC' }) });
      case 'bluebubbles_send_message': return await bbFetch('/api/v1/message/text', { method: 'POST', body: JSON.stringify({ chatGuid: args.chatGuid, message: args.message, method: 'apple-script' }) });
      case 'bluebubbles_create_chat': return await bbFetch('/api/v1/chat/new', { method: 'POST', body: JSON.stringify({ addresses: args.addresses, message: args.message || '', service: args.service || 'iMessage' }) });
      case 'bluebubbles_request': return await bbFetch(args.path, { method: args.method || 'GET', body: args.body ? JSON.stringify(args.body) : undefined });
      default: return { error: `Unknown tool: ${name}` };
    }
  } catch (error) { return { error: error.message }; }
}

function authenticate(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth?.startsWith('Bearer ') || auth.substring(7) !== CONFIG.bearerToken) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

app.post('/mcp', authenticate, async (req, res) => {
  const { jsonrpc, method, params, id } = req.body;
  console.log(`📥 ${method}`);
  if (jsonrpc !== '2.0') return res.json({ jsonrpc: '2.0', error: { code: -32600, message: 'Invalid Request' }, id });
  
  let result;
  switch (method) {
    case 'initialize': result = { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'bluebubbles-mcp', version: '1.0.0' } }; break;
    case 'tools/list': result = { tools: TOOLS }; break;
    case 'tools/call': const toolResult = await handleTool(params.name, params.arguments || {}); result = { content: [{ type: 'text', text: JSON.stringify(toolResult, null, 2) }] }; break;
    case 'notifications/initialized': result = {}; break;
    default: return res.json({ jsonrpc: '2.0', error: { code: -32601, message: `Method not found: ${method}` }, id });
  }
  res.json({ jsonrpc: '2.0', result, id });
});

app.get('/health', (req, res) => res.json({ status: 'ok', timestamp: new Date().toISOString() }));

app.listen(CONFIG.port, () => {
  console.log(`✅ MCP Bridge running on port ${CONFIG.port}`);
  console.log(`🔗 Endpoint: http://localhost:${CONFIG.port}/mcp`);
});
SERVER_EOF

# Install dependencies
echo "📦 Installing dependencies..."
npm install

# Generate bearer token
BEARER_TOKEN=$(openssl rand -hex 32)

# Create .env file
echo ""
echo "⚙️  Creating .env file..."
echo "Please enter your BlueBubbles password (from BlueBubbles > Settings > API):"
read -s BB_PASSWORD

cat > .env << ENV_EOF
BLUEBUBBLES_URL=http://localhost:1234
BLUEBUBBLES_PASSWORD=${BB_PASSWORD}
MCP_PORT=3000
MCP_BEARER_TOKEN=${BEARER_TOKEN}
ENV_EOF

echo ""
echo "✅ Setup complete!"
echo ""
echo "======================================"
echo "🔑 Your MCP Bearer Token (SAVE THIS!):"
echo "${BEARER_TOKEN}"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Test locally: npm start"
echo "2. Set up Cloudflare Tunnel (see SETUP_INSTRUCTIONS.md)"
echo "3. Configure iOS app with the bearer token above"
echo ""
echo "To start the server now, run:"
echo "  cd /opt/imessage-bridge && npm start"

