/**
 * BlueBubbles MCP Bridge Server
 * 
 * This server acts as a bridge between OpenAI's MCP protocol and BlueBubbles REST API.
 * It exposes BlueBubbles functionality as MCP tools that can be called by AI assistants.
 */

import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import {
  browser_navigate,
  browser_click,
  browser_type,
  browser_scroll,
  browser_extract_text,
  browser_screenshot,
  browser_close
} from './browser-tools.js';

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

  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch (e) {
    data = { error: text };
  }
  return { status: response.status, data };
}

// ============================================================================
// MCP Tool Definitions
// ============================================================================

const TOOLS = [
  {
    name: 'get_status',
    description: 'Check if BlueBubbles server is running and accessible (health check)',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'bluebubbles_list_chats',
    description: 'List or search chat conversations. Use this to find existing chats.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: 'Max results', default: 25 },
        offset: { type: 'number', description: 'Pagination offset', default: 0 },
        search: { type: 'string', description: 'Search term (phone, name)' },
        includeParticipants: { type: 'boolean', default: true }
      },
      required: []
    }
  },
  {
    name: 'fetch_messages',
    description: 'Get messages from a chat. Provide chatGuid, handle, or contact name.',
    inputSchema: {
      type: 'object',
      properties: {
        chatGuid: { type: 'string', description: 'Chat GUID' },
        handle: { type: 'string', description: 'Contact handle, phone, or Nickname (e.g. Sweetheart)' },
        limit: { type: 'number', default: 50 },
        offset: { type: 'number', default: 0 },
        after: { type: 'string', description: 'EPOCH timestamp' },
        before: { type: 'string', description: 'EPOCH timestamp' }
      },
      required: []
    }
  },
  {
    name: 'get_recent_messages',
    description: 'Get an overview of recent activity across all your chats. Shows the latest messages from the top 5 most recently active threads.',
    inputSchema: {
      type: 'object',
      properties: {
        chatLimit: { type: 'number', description: 'Number of chats to check (default: 5)', default: 5 },
        messagesPerChat: { type: 'number', description: 'Messages per chat (default: 2)', default: 2 }
      },
      required: []
    }
  },
  {
    name: 'send_imessage',
    description: 'Send a message to a chat.',
    inputSchema: {
      type: 'object',
      properties: {
        chatGuid: { type: 'string', description: 'Chat GUID' },
        message: { type: 'string', description: 'Message text' },
        service: { type: 'string', enum: ['iMessage', 'SMS'], default: 'iMessage' }
      },
      required: ['chatGuid', 'message']
    }
  },
  {
    name: 'bluebubbles_create_chat',
    description: 'Create a new chat.',
    inputSchema: {
      type: 'object',
      properties: {
        addresses: { type: 'array', items: { type: 'string' } },
        message: { type: 'string' },
        service: { type: 'string', enum: ['iMessage', 'SMS'], default: 'iMessage' }
      },
      required: ['addresses']
    }
  },
  {
    name: 'bluebubbles_request',
    description: 'Raw API request.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        method: { type: 'string' },
        body: { type: 'object' }
      },
      required: ['path']
    }
  },
  {
    name: 'bluebubbles_get_attachment',
    description: 'Get attachment metadata.',
    inputSchema: {
      type: 'object',
      properties: {
        attachmentGuid: { type: 'string' }
      },
      required: ['attachmentGuid']
    }
  },
  {
    name: 'execute_task',
    description: 'Run a GPT-5 vision-driven computer agent on this Mac (screenshot → decide → act → repeat) using desktop controls.',
    inputSchema: {
      type: 'object',
      properties: {
        task: { type: 'string', description: 'Task instructions for the computer agent' },
        maxSteps: { type: 'number', description: 'Maximum action steps (default: 20)', default: 20 },
        model: { type: 'string', description: 'Override model (default: COMPUTER_AGENT_MODEL or gpt-5-2025-08-07)' },
        imageDetail: { type: 'string', enum: ['low', 'high', 'auto'], description: 'Vision detail level', default: 'high' },
        postActionWaitMs: { type: 'number', description: 'Delay after each action before next screenshot', default: 300 },
        includeFinalScreenshot: { type: 'boolean', description: 'Include final screenshot base64 in the response', default: true },
        background: { type: 'boolean', description: 'Run asynchronously and notify on completion', default: false },
        notifyPhone: { type: 'string', description: 'Phone number to text result to if running in background' }
      },
      required: ['task']
    }
  },
  // Browser Tools (Direct Access)
  {
    name: 'browser_navigate',
    description: 'Navigate the Playwright browser to a URL.',
    inputSchema: {
      type: 'object',
      properties: { url: { type: 'string' } },
      required: ['url']
    }
  },
  {
    name: 'browser_click',
    description: 'Click an element in the browser.',
    inputSchema: {
      type: 'object',
      properties: { selector: { type: 'string' } },
      required: ['selector']
    }
  },
  {
    name: 'browser_type',
    description: 'Type text into an element in the browser.',
    inputSchema: {
      type: 'object',
      properties: { selector: { type: 'string' }, text: { type: 'string' } },
      required: ['selector', 'text']
    }
  },
  {
    name: 'browser_scroll',
    description: 'Scroll the browser page.',
    inputSchema: {
      type: 'object',
      properties: { amount: { type: 'number' } },
      required: []
    }
  },
  {
    name: 'browser_extract_text',
    description: 'Extract visible text from the current page.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: []
    }
  },
  {
    name: 'browser_screenshot',
    description: 'Take a screenshot of the current browser page.',
    inputSchema: {
      type: 'object',
      properties: { fullPage: { type: 'boolean' } },
      required: []
    }
  }
];

// ============================================================================
// Tool Handlers
// ============================================================================

let computerAgentBusy = false;

async function handleTool(name, args, context) {
  console.log(`🔧 Executing tool: ${name}`, JSON.stringify(args));

  try {
    switch (name) {
      case 'get_status':
      case 'bluebubbles_health': {
        const result = await bbFetch('/api/v1/server/info');
        return { success: true, ...result };
      }

      case 'bluebubbles_list_chats': {
        const params = new URLSearchParams();
        params.set('limit', args.limit || 25);
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

      case 'fetch_messages':
      case 'bluebubbles_get_messages': {
        let guid = args.chatGuid;

        // If chatGuid is missing but handle/name is provided, find the chat
        if (!guid && args.handle) {
          console.log(`🔍 Searching for chat with identifier: ${args.handle}`);

          // Step 1: Try handle/phone search (POST /query)
          const chatSearch = await bbFetch('/api/v1/chat/query', {
            method: 'POST',
            body: JSON.stringify({
              with: [args.handle],
              limit: 1
            })
          });

          if (chatSearch.status === 200 && chatSearch.data?.data?.length > 0) {
            guid = chatSearch.data.data[0].guid;
            console.log(`✅ Found chatGuid by handle: ${guid}`);
          } else {
            // Step 2: Fallback to searching all chats for a display name match (nicknames like "Sweetheart")
            console.log(`🕵️ Handle search failed. Searching display names for "${args.handle}"...`);
            const allChats = await bbFetch('/api/v1/chat?limit=100');
            if (allChats.status === 200 && allChats.data?.data) {
              const searchTerm = args.handle.toLowerCase();
              const match = allChats.data.data.find(c =>
                (c.displayName && c.displayName.toLowerCase().includes(searchTerm)) ||
                (c.title && c.title.toLowerCase().includes(searchTerm))
              );

              if (match) {
                guid = match.guid;
                console.log(`🎯 Found chatGuid by display name: ${guid} (${match.displayName})`);
              }
            }
          }

          if (!guid) {
            return { error: `Could not find a chat associated with "${args.handle}". Use bluebubbles_list_chats to see your active threads.` };
          }
        }

        if (!guid) {
          return { error: "A chatGuid, handle, or contact name must be provided to fetch messages." };
        }

        const params = new URLSearchParams();
        params.set('limit', args.limit || 50);
        params.set('offset', args.offset || 0);
        params.set('sort', 'DESC');
        if (args.after) params.set('after', args.after);
        if (args.before) params.set('before', args.before);

        const result = await bbFetch(`/api/v1/chat/${encodeURIComponent(guid)}/message?${params.toString()}`, {
          method: 'GET'
        });
        return result;
      }

      case 'get_recent_messages': {
        const chatLimit = args.chatLimit || 5;
        const messagesPerChat = args.messagesPerChat || 2;

        console.log(`📥 Pulling activity: ${chatLimit} chats, ${messagesPerChat} messages/chat`);

        // 1. Get recent chats sorted by last message
        const chatsResult = await bbFetch('/api/v1/chat/query', {
          method: 'POST',
          body: JSON.stringify({
            limit: chatLimit,
            sort: 'lastmessage'
          })
        });
        if (chatsResult.status !== 200 || !chatsResult.data?.data) return chatsResult;

        const chats = chatsResult.data.data;
        const result = [];

        // 2. For each chat, get the latest N messages
        for (const chat of chats) {
          const msgResult = await bbFetch(`/api/v1/chat/${encodeURIComponent(chat.guid)}/message?limit=${messagesPerChat}&sort=DESC`);
          result.push({
            chatName: chat.displayName || chat.title || 'Unknown Chat',
            chatGuid: chat.guid,
            messages: msgResult.status === 200 ? msgResult.data?.data : []
          });
        }

        return { success: true, activity: result };
      }

      case 'send_imessage':
      case 'bluebubbles_send_message': {
        const messageText = args.message || args.text;

        // If 'to' is provided instead of 'chatGuid', assume we need to create/find a chat
        if (args.to && !args.chatGuid) {
          console.log(`✨ Auto-creating chat for recipient: ${args.to}`);
          const result = await bbFetch('/api/v1/chat/new', {
            method: 'POST',
            body: JSON.stringify({
              addresses: [args.to],
              message: messageText,
              service: args.service || 'iMessage',
              method: args.service === 'SMS' ? 'private-api' : 'apple-script'
            })
          });
          return result;
        }

        // Otherwise use the standard send endpoint
        const result = await bbFetch('/api/v1/message/text', {
          method: 'POST',
          body: JSON.stringify({
            chatGuid: args.chatGuid,
            message: messageText,
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

      case 'send_tapback':
      case 'bluebubbles_send_tapback': {
        const result = await bbFetch('/api/v1/message/react', {
          method: 'POST',
          body: JSON.stringify({
            chatGuid: args.chatGuid,
            messageGuid: args.messageGuid,
            reaction: args.reaction
          })
        });
        return result;
      }

      case 'rename_group':
      case 'bluebubbles_rename_chat': {
        const result = await bbFetch(`/api/v1/chat/${encodeURIComponent(args.chatGuid)}`, {
          method: 'PUT',
          body: JSON.stringify({
            displayName: args.displayName || args.name
          })
        });
        return result;
      }

      case 'mark_chat_read':
      case 'bluebubbles_mark_read': {
        const result = await bbFetch(`/api/v1/chat/${encodeURIComponent(args.chatGuid)}/read`, {
          method: 'POST'
        });
        return result;
      }

      case 'get_handles':
      case 'bluebubbles_get_handles': {
        const result = await bbFetch('/api/v1/handle');
        return result;
      }

      case 'execute_task': {
        const { task, maxSteps, background = false, notifyPhone } = args;

        if (computerAgentBusy) {
          return { error: 'Computer agent is already running a task. Please wait.' };
        }

        const { runComputerAgent } = await import('./computer-agent.js');

        if (background) {
          // Asynchronous Background Mode
          console.log(`🚀 Starting background task: ${task}`);

          // Start the task in a detached promise
          (async () => {
            computerAgentBusy = true;
            try {
              const { model } = args;
              const result = await runComputerAgent({ task, maxSteps, model, handleTool }, context);

              const summary = result.summary || 'Task completed without summary.';
              const status = result.status;
              const msg = `🖥️ Computer Agent Finished (${status}):\n${summary}`;

              console.log('✅ Background task finished:', summary);

              // 1. Notify via WebSocket if possible
              if (context?.sendNotification) {
                console.log(`🔔 Sending WS notification to client...`);
                context.sendNotification('notifications/task_result', {
                  task,
                  status,
                  summary,
                  next_steps: result.next_steps
                });
              }

              // 2. Notify via iMessage if requested
              if (notifyPhone) {
                await handleTool('send_imessage', { to: notifyPhone, message: msg }, context);
              }
            } catch (error) {
              console.error(`❌ Background task error:`, error);

              if (context?.sendNotification) {
                context.sendNotification('notifications/task_result', {
                  task,
                  status: 'error',
                  summary: error.message
                });
              }

              if (notifyPhone) {
                await handleTool('send_imessage', { to: notifyPhone, message: `❌ Computer Agent Failed: ${error.message}` }, context);
              }
            } finally {
              computerAgentBusy = false;
            }
          })();

          return {
            status: "started",
            message: "I have started the task in the background. I will notify you through the phone when it is finished.",
            job_id: Date.now()
          };
        }

        // Foreground Mode (Wait for result)
        computerAgentBusy = true;
        try {
          const result = await runComputerAgent({ ...args, handleTool }, context);
          return result;
        } catch (error) {
          const message = String(error?.message || error);
          if (error.code === 'MODULE_NOT_FOUND') {
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

      // Browser Tools Handlers
      case 'browser_navigate':
        return await browser_navigate(args);
      case 'browser_click':
        return await browser_click(args);
      case 'browser_type':
        return await browser_type(args);
      case 'browser_scroll':
        return await browser_scroll(args);
      case 'browser_extract_text':
        return await browser_extract_text(args);
      case 'browser_screenshot':
        return await browser_screenshot(args);

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
// MCP Protocol Handler (Shared between HTTP and WebSocket)
// ============================================================================

/**
 * Process an MCP JSON-RPC request and return the response object.
 * @param {object} request - The JSON-RPC request
 * @param {object} context - Optional context (e.g. WebSocket or connection info)
 * @returns {Promise<object>} - The JSON-RPC response
 */
async function processMcpRequest(request, context = {}) {
  const { jsonrpc, method, params, id } = request;

  console.log(`📥 MCP Request: ${method}`, params ? JSON.stringify(params).substring(0, 200) : '');

  if (jsonrpc !== '2.0') {
    return { jsonrpc: '2.0', error: { code: -32600, message: 'Invalid Request' }, id };
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
        const { name: toolName, arguments: toolArgs } = params;
        let toolResult = await handleTool(toolName, toolArgs || {}, context);

        // Special handling for bulky results (like execute_task)
        let responseText = '';
        if (toolResult && typeof toolResult === 'object') {
          if (toolResult.summary && toolResult.status) {
            // Priority summary for the model to see
            responseText = `Status: ${toolResult.status}\nSummary: ${toolResult.summary}`;
            if (toolResult.next_steps) {
              responseText += `\nNext Steps: ${toolResult.next_steps}`;
            }

            // Log full result to console but strip screenshot from AI response
            if (toolResult.screenshot) {
              console.log(`📸 Result included a screenshot (${toolResult.screenshot.length} chars) - stripping from AI response text.`);
              delete toolResult.screenshot;
            }
          } else {
            responseText = JSON.stringify(toolResult, null, 2);
          }
        } else {
          responseText = String(toolResult);
        }

        result = {
          content: [{
            type: 'text',
            text: responseText
          }]
        };
        break;

      case 'notifications/initialized':
        result = {};
        break;

      default:
        return {
          jsonrpc: '2.0',
          error: { code: -32601, message: `Method not found: ${method}` },
          id
        };
    }

    console.log(`📤 MCP Response for ${method}:`, JSON.stringify(result).substring(0, 200));
    return { jsonrpc: '2.0', result, id };

  } catch (error) {
    console.error(`❌ MCP Error:`, error);
    return {
      jsonrpc: '2.0',
      error: { code: -32603, message: error.message },
      id
    };
  }
}

// HTTP Endpoint
app.post('/mcp', authenticate, async (req, res) => {
  const response = await processMcpRequest(req.body);
  res.json(response);
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ============================================================================
// Start Server
// ============================================================================

// ============================================================================
// Start Server with WebSocket Support
// ============================================================================

import { WebSocketServer } from 'ws';
import http from 'http';

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  console.log(`🔌 Client connected from ${req.socket.remoteAddress}`);

  const context = {
    ws,
    sendNotification: (method, params) => {
      if (ws.readyState === 1) { // OPEN
        ws.send(JSON.stringify({
          jsonrpc: '2.0',
          method,
          params
        }));
      }
    }
  };

  ws.on('message', async (message) => {
    try {
      const msgText = message.toString();
      const request = JSON.parse(msgText);

      // Use the shared MCP request handler with context
      const response = await processMcpRequest(request, context);
      if (response) {
        ws.send(JSON.stringify(response));
      }
    } catch (error) {
      console.error(`❌ WS Error:`, error);
      ws.send(JSON.stringify({
        jsonrpc: '2.0',
        error: { code: -32700, message: 'Parse error: ' + error.message },
        id: null
      }));
    }
  });

  ws.on('close', () => {
    console.log('🔌 Client disconnected');
  });
});

server.listen(CONFIG.port, () => {
  console.log(`✅ BlueBubbles MCP Bridge running on port ${CONFIG.port}`);
  console.log(`🔗 MCP HTTP endpoint: http://localhost:${CONFIG.port}/mcp`);
  console.log(`🔗 MCP WebSocket endpoint: ws://localhost:${CONFIG.port}/`);
});
