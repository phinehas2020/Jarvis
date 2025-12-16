/**
 * BlueBubbles MCP Bridge Server
 * 
 * This server acts as a bridge between OpenAI's MCP protocol and BlueBubbles REST API.
 * It exposes BlueBubbles functionality as MCP tools that can be called by AI assistants.
 */

import 'dotenv/config';
import express from 'express';
import cors from 'cors';

const app = express();
app.use(cors());
app.use(express.json());

// Configuration
const CONFIG = {
  port: process.env.MCP_PORT || 3000,
  bearerToken: process.env.MCP_BEARER_TOKEN,
  bluebubbles: {
    url: process.env.BLUEBUBBLES_URL || 'http://localhost:1234',
    password: process.env.BLUEBUBBLES_PASSWORD
  }
};

// Validate configuration
if (!CONFIG.bearerToken) {
  console.error('❌ MCP_BEARER_TOKEN is required in .env');
  process.exit(1);
}
if (!CONFIG.bluebubbles.password) {
  console.error('❌ BLUEBUBBLES_PASSWORD is required in .env');
  process.exit(1);
}

console.log('🚀 Starting BlueBubbles MCP Bridge...');
console.log(`📡 BlueBubbles URL: ${CONFIG.bluebubbles.url}`);

// ============================================================================
// BlueBubbles API Client
// ============================================================================

async function bbFetch(path, options = {}) {
  const url = new URL(path, CONFIG.bluebubbles.url);
  url.searchParams.set('password', CONFIG.bluebubbles.password);
  
  const response = await fetch(url.toString(), {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers
    }
  });
  
  const data = await response.json();
  return { status: response.status, data };
}

// ============================================================================
// MCP Tool Definitions
// ============================================================================

const TOOLS = [
  {
    name: 'bluebubbles_health',
    description: 'Check if BlueBubbles server is running and accessible',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'bluebubbles_list_chats',
    description: 'List or search chat conversations. Use this to find existing chats before sending messages.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max results (1-500)', default: 25 },
        offset: { type: 'number', description: 'Pagination offset', default: 0 },
        search: { type: 'string', description: 'Search term (phone number, name, etc.)' },
        includeParticipants: { type: 'boolean', description: 'Include participant details', default: true }
      },
      required: []
    }
  },
  {
    name: 'bluebubbles_get_messages',
    description: 'Get messages from a specific chat. Requires chatGuid.',
    inputSchema: {
      type: 'object',
      properties: {
        chatGuid: { type: 'string', description: 'Chat GUID (e.g., iMessage;-;+12345678900)' },
        limit: { type: 'number', description: 'Max messages to fetch (1-500)', default: 50 },
        offset: { type: 'number', description: 'Pagination offset', default: 0 },
        after: { type: 'string', description: 'Fetch messages after this date/guid' },
        before: { type: 'string', description: 'Fetch messages before this date/guid' }
      },
      required: ['chatGuid']
    }
  },
  {
    name: 'bluebubbles_send_message',
    description: 'Send a message to an existing chat. Requires chatGuid - use bluebubbles_list_chats first to find it, or bluebubbles_create_chat to create a new one.',
    inputSchema: {
      type: 'object',
      properties: {
        chatGuid: { type: 'string', description: 'Chat GUID (required)' },
        message: { type: 'string', description: 'Message text to send' },
        service: { type: 'string', enum: ['iMessage', 'SMS'], default: 'iMessage' }
      },
      required: ['chatGuid', 'message']
    }
  },
  {
    name: 'bluebubbles_create_chat',
    description: 'Create a new chat and optionally send the first message. On macOS Big Sur+, a message is required when creating a chat.',
    inputSchema: {
      type: 'object',
      properties: {
        addresses: { 
          type: 'array', 
          items: { type: 'string' },
          description: 'Phone numbers or Apple IDs (e.g., ["+12345678900"])'
        },
        message: { type: 'string', description: 'Initial message to send (required on Big Sur+)' },
        service: { type: 'string', enum: ['iMessage', 'SMS'], default: 'iMessage' }
      },
      required: ['addresses']
    }
  },
  {
    name: 'bluebubbles_request',
    description: 'Make a raw API request to BlueBubbles. Use this for advanced operations not covered by other tools.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'API path (e.g., /api/v1/chat/new)' },
        method: { type: 'string', enum: ['GET', 'POST', 'PUT', 'DELETE'], default: 'GET' },
        body: { type: 'object', description: 'Request body for POST/PUT requests' }
      },
      required: ['path']
    }
  },
  {
    name: 'bluebubbles_get_attachment',
    description: 'Get attachment metadata by GUID',
    inputSchema: {
      type: 'object',
      properties: {
        attachmentGuid: { type: 'string', description: 'Attachment GUID' }
      },
      required: ['attachmentGuid']
    }
  },
  {
    name: 'execute_task',
    description: 'Run a GPT-5.2 vision-driven computer agent on this Mac (screenshot → decide → act → repeat) using desktop controls.',
    inputSchema: {
      type: 'object',
      properties: {
        task: { type: 'string', description: 'Task instructions for the computer agent' },
        maxSteps: { type: 'number', description: 'Maximum action steps (default: 20)', default: 20 },
        model: { type: 'string', description: 'Override model (default: COMPUTER_AGENT_MODEL or gpt-5.2)' },
        imageDetail: { type: 'string', enum: ['low', 'high', 'auto'], description: 'Vision detail level', default: 'high' },
        postActionWaitMs: { type: 'number', description: 'Delay after each action before next screenshot', default: 300 },
        includeFinalScreenshot: { type: 'boolean', description: 'Include final screenshot base64 in the response', default: true }
      },
      required: ['task']
    }
  }
];

// ============================================================================
// Tool Handlers
// ============================================================================

let computerAgentBusy = false;

async function handleTool(name, args) {
  console.log(`🔧 Executing tool: ${name}`, JSON.stringify(args));
  
  try {
    switch (name) {
      case 'bluebubbles_health': {
        const result = await bbFetch('/api/v1/server/info');
        return { success: true, ...result };
      }
      
      case 'bluebubbles_list_chats': {
        const params = new URLSearchParams();
        params.set('limit', args.limit || 25);
        params.set('offset', args.offset || 0);
        if (args.search) params.set('with', args.search);
        
        const result = await bbFetch(`/api/v1/chat/query?${params.toString()}`, {
          method: 'POST',
          body: JSON.stringify({
            with: args.search ? [args.search] : [],
            limit: args.limit || 25,
            offset: args.offset || 0
          })
        });
        return result;
      }
      
      case 'bluebubbles_get_messages': {
        const result = await bbFetch(`/api/v1/chat/${encodeURIComponent(args.chatGuid)}/message`, {
          method: 'POST',
          body: JSON.stringify({
            limit: args.limit || 50,
            offset: args.offset || 0,
            after: args.after || null,
            before: args.before || null,
            sort: 'DESC'
          })
        });
        return result;
      }
      
      case 'bluebubbles_send_message': {
        const result = await bbFetch('/api/v1/message/text', {
          method: 'POST',
          body: JSON.stringify({
            chatGuid: args.chatGuid,
            message: args.message,
            method: args.service === 'SMS' ? 'private-api' : 'apple-script'
          })
        });
        return result;
      }
      
      case 'bluebubbles_create_chat': {
        const result = await bbFetch('/api/v1/chat/new', {
          method: 'POST',
          body: JSON.stringify({
            addresses: args.addresses,
            message: args.message || '',
            service: args.service || 'iMessage'
          })
        });
        return result;
      }
      
      case 'bluebubbles_request': {
        const result = await bbFetch(args.path, {
          method: args.method || 'GET',
          body: args.body ? JSON.stringify(args.body) : undefined
        });
        return result;
      }
      
      case 'bluebubbles_get_attachment': {
        const result = await bbFetch(`/api/v1/attachment/${encodeURIComponent(args.attachmentGuid)}`);
        return result;
      }

      case 'execute_task': {
        if (computerAgentBusy) {
          return { error: 'Computer agent is already running (execute_task busy)' };
        }
        if (!args?.task || typeof args.task !== 'string') {
          return { error: 'task (string) is required' };
        }

        computerAgentBusy = true;
        try {
          const { runComputerAgent } = await import('./computer-agent.js');
          return await runComputerAgent({
            task: args.task,
            maxSteps: args.maxSteps,
            model: args.model,
            imageDetail: args.imageDetail,
            postActionWaitMs: args.postActionWaitMs,
            includeFinalScreenshot: args.includeFinalScreenshot
          });
        } catch (error) {
          const message = String(error?.message || error);
          if (message.includes("Cannot find package 'openai'")) {
            return { error: "Missing dependency: openai. Install with: npm install openai" };
          }
          if (message.includes('OPENAI_API_KEY is required')) {
            return { error: 'OPENAI_API_KEY is required in the server environment to use execute_task' };
          }
          return { error: message };
        } finally {
          computerAgentBusy = false;
        }
      }
      
      default:
        return { error: `Unknown tool: ${name}` };
    }
  } catch (error) {
    console.error(`❌ Tool error (${name}):`, error.message);
    return { error: error.message };
  }
}

// ============================================================================
// Authentication Middleware
// ============================================================================

function authenticate(req, res, next) {
  const authHeader = req.headers.authorization;
  
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid Authorization header' });
  }
  
  const token = authHeader.substring(7);
  if (token !== CONFIG.bearerToken) {
    return res.status(401).json({ error: 'Invalid bearer token' });
  }
  
  next();
}

// ============================================================================
// MCP Protocol Handler (Streamable HTTP)
// ============================================================================

app.post('/mcp', authenticate, async (req, res) => {
  const { jsonrpc, method, params, id } = req.body;
  
  console.log(`📥 MCP Request: ${method}`, params ? JSON.stringify(params).substring(0, 200) : '');
  
  if (jsonrpc !== '2.0') {
    return res.json({ jsonrpc: '2.0', error: { code: -32600, message: 'Invalid Request' }, id });
  }
  
  try {
    let result;
    
    switch (method) {
      case 'initialize':
        result = {
          protocolVersion: '2024-11-05',
          capabilities: {
            tools: {}
          },
          serverInfo: {
            name: 'bluebubbles-mcp',
            version: '1.0.0'
          }
        };
        break;
        
      case 'tools/list':
        result = { tools: TOOLS };
        break;
        
      case 'tools/call':
        const { name, arguments: args } = params;
        const toolResult = await handleTool(name, args || {});
        result = {
          content: [{
            type: 'text',
            text: JSON.stringify(toolResult, null, 2)
          }]
        };
        break;
        
      case 'notifications/initialized':
        // Acknowledgment, no response needed
        result = {};
        break;
        
      default:
        return res.json({
          jsonrpc: '2.0',
          error: { code: -32601, message: `Method not found: ${method}` },
          id
        });
    }
    
    console.log(`📤 MCP Response for ${method}:`, JSON.stringify(result).substring(0, 200));
    res.json({ jsonrpc: '2.0', result, id });
    
  } catch (error) {
    console.error(`❌ MCP Error:`, error);
    res.json({
      jsonrpc: '2.0',
      error: { code: -32603, message: error.message },
      id
    });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ============================================================================
// Start Server
// ============================================================================

app.listen(CONFIG.port, () => {
  console.log(`✅ BlueBubbles MCP Bridge running on port ${CONFIG.port}`);
  console.log(`🔗 MCP endpoint: http://localhost:${CONFIG.port}/mcp`);
  console.log(`💚 Health check: http://localhost:${CONFIG.port}/health`);
});
