import fs from 'node:fs/promises';
import {
  screenshot,
  click,
  doubleClick,
  rightClick,
  drag,
  scroll,
  typeText,
  keypress,
  applescript,
  terminal,
  openApp,
  openUrl,
  wait
} from './desktop-tools.js';
import {
  browser_navigate,
  browser_click,
  browser_type,
  browser_scroll,
  browser_extract_text,
  browser_screenshot,
  browser_close
} from './browser-tools.js';

const SYSTEM_PROMPT_PATH = new URL('../ComputerAgentPrompt.md', import.meta.url);

let cachedSystemPrompt = null;
async function loadSystemPrompt() {
  if (cachedSystemPrompt) return cachedSystemPrompt;
  cachedSystemPrompt = await fs.readFile(SYSTEM_PROMPT_PATH, 'utf8');
  return cachedSystemPrompt;
}

function truncate(value, maxChars = 4_000) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}… (truncated, ${text.length} chars)`;
}

function buildAugmentedSystemPrompt(basePrompt) {
  return [
    basePrompt.trim(),
    '',
    '## Runtime Tooling Note (Important)',
    'Only these tools are actually available in this environment:',
    '- screenshot() is taken automatically after each action (and included in your input).',
    '- click: {x, y}',
    '- double_click: {x, y}',
    '- right_click: {x, y}',
    '- drag: {fromX, fromY, toX, toY}',
    '- scroll: {direction: "up"|"down"|"left"|"right", amount}',
    '- type: {text}',
    '- keypress: {keys} where keys uses "+" for combos (e.g., "cmd+shift+4", "enter")',
    '- applescript: {script}',
    '- terminal: {command, timeoutMs?, cwd?}',
    '- open_app: {appName}',
    '- open_url: {url}',
    '- wait: {ms}',
    '- browser_navigate: {url} (Use for fast, reliable web browsing distinct from desktop vision)',
    '- browser_click: {selector}',
    '- browser_type: {selector, text}',
    '- browser_scroll: {amount}',
    '- browser_extract_text: {} (Returns visible text from current page)',
    '- done: {status, summary, data?, next_steps?}',
    '',
    'You should prioritize using browser_* tools for purely web-based tasks as they are faster and more reliable than vision-based clicking.',
    'For OS-level tasks or when the browser tools fail, fall back to desktop vision tools (click, type, etc).',
    '',
    'You must choose exactly ONE action each step and respond with ONLY valid JSON matching this shape:',
    '{"thought": "...", "action": {"tool": "click|...|browser_navigate|...|done", "params": {}}}',
    '',
    'When you are finished, use tool "done".'
  ].join('\n');
}

const STEP_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    thought: { type: 'string' },
    action: {
      type: 'object',
      additionalProperties: false,
      properties: {
        tool: {
          type: 'string',
          enum: [
            'click',
            'double_click',
            'right_click',
            'drag',
            'scroll',
            'type',
            'keypress',
            'applescript',
            'terminal',
            'open_app',
            'open_url',
            'wait',
            'browser_navigate',
            'browser_click',
            'browser_type',
            'browser_scroll',
            'browser_extract_text',
            'send_imessage',
            'send_tapback',
            'rename_group',
            'mark_chat_read',
            'get_handles',
            'done'
          ]
        },
        params: { type: 'object' }
      },
      required: ['tool', 'params']
    }
  },
  required: ['thought', 'action']
};

function requireString(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} is required`);
  }
  return value;
}

function requireNumber(value, label) {
  const numberValue = Number(value);
  if (!Number.isFinite(numberValue)) {
    throw new Error(`${label} must be a finite number`);
  }
  return numberValue;
}

function extractJson(text) {
  let trimmed = String(text ?? '').trim();
  if (!trimmed) throw new Error('Model returned empty output');

  // Strip markdown code fences if present
  if (trimmed.startsWith('```')) {
    trimmed = trimmed.replace(/^```(json)?\n?/, '').replace(/\n?```$/, '');
  }

  // Find first { and last } to handle potentially conversational wrapping
  const firstBrace = trimmed.indexOf('{');
  const lastBrace = trimmed.lastIndexOf('}');
  if (firstBrace !== -1 && lastBrace !== -1) {
    trimmed = trimmed.substring(firstBrace, lastBrace + 1);
  }

  try {
    return JSON.parse(trimmed);
  } catch (error) {
    // Handle case where model outputs multiple JSON objects: {"thought":...} {"action":...}
    // We try to wrap them in an array or merge them.
    // Simple heuristic: if it looks like there are multiple root objects, try formatting as array
    try {
      // Replace "}{" with "},{" to make valid array, wrap in []
      const arrayText = `[${trimmed.replace(/}\s*{/g, '},{')}]`;
      const array = JSON.parse(arrayText);
      // Merge all objects in the array
      return array.reduce((acc, curr) => ({ ...acc, ...curr }), {});
    } catch (e2) {
      console.error('❌ Failed to parse JSON:', trimmed);
      throw error; // Throw original error
    }
  }
}

async function createOpenAIClient() {
  let apiKey = process.env.OPENAI_API_KEY;
  let baseURL = undefined;

  // xAI Support
  if (process.env.XAI_API_KEY) {
    apiKey = process.env.XAI_API_KEY;
    baseURL = 'https://api.x.ai/v1';
  }

  if (!apiKey) {
    throw new Error('OPENAI_API_KEY or XAI_API_KEY is required to use execute_task');
  }

  const { default: OpenAI } = await import('openai');
  return new OpenAI({ apiKey, baseURL });
}

function buildUserInput({ task, stepIndex, maxSteps, lastToolResult, history }) {
  const recent = history.slice(-8);
  const historyText = recent.length
    ? recent
      .map((h) => `- Step ${h.step}: ${h.tool} ${h.paramsSummary} -> ${h.resultSummary}`)
      .join('\n')
    : '(none yet)';

  const lastText = lastToolResult
    ? `Last tool result:\n${truncate(lastToolResult, 2_000)}`
    : 'Last tool result: (none yet)';

  return [
    `Task: ${task}`,
    `Step: ${stepIndex}/${maxSteps}`,
    '',
    lastText,
    '',
    'Recent history:',
    historyText,
    '',
    'Decide the next single action based on the screenshot.'
  ].join('\n');
}

async function executeToolAction(action) {
  const tool = action.tool;
  const params = action.params || {};

  switch (tool) {
    case 'click':
      return click({ x: requireNumber(params.x, 'x'), y: requireNumber(params.y, 'y') });
    case 'double_click':
      return doubleClick({ x: requireNumber(params.x, 'x'), y: requireNumber(params.y, 'y') });
    case 'right_click':
      return rightClick({ x: requireNumber(params.x, 'x'), y: requireNumber(params.y, 'y') });
    case 'drag':
      return drag({
        fromX: requireNumber(params.fromX, 'fromX'),
        fromY: requireNumber(params.fromY, 'fromY'),
        toX: requireNumber(params.toX, 'toX'),
        toY: requireNumber(params.toY, 'toY')
      });
    case 'scroll':
      return scroll({
        direction: requireString(params.direction, 'direction'),
        amount: params.amount
      });
    case 'type':
      return typeText({ text: requireString(params.text ?? '', 'text') });
    case 'keypress':
      return keypress({ keys: requireString(params.keys, 'keys') });
    case 'applescript':
      return applescript({ script: requireString(params.script, 'script') });
    case 'terminal':
      return terminal({
        command: requireString(params.command, 'command'),
        timeoutMs: params.timeoutMs,
        cwd: params.cwd
      });
    case 'open_app':
      return openApp({ appName: requireString(params.appName, 'appName') });
    case 'open_url':
      return openUrl({ url: requireString(params.url, 'url') });
    case 'wait':
      return wait({ ms: requireNumber(params.ms, 'ms') });

    // Browser Tools
    case 'browser_navigate':
      return browser_navigate({ url: requireString(params.url, 'url') });
    case 'browser_click':
      return browser_click({ selector: requireString(params.selector, 'selector') });
    case 'browser_type':
      return browser_type({ selector: requireString(params.selector, 'selector'), text: requireString(params.text, 'text') });
    case 'browser_scroll':
      return browser_scroll({ amount: params.amount });
    case 'browser_extract_text':
      return browser_extract_text();
    case 'browser_screenshot':
      return browser_screenshot({ fullPage: params.fullPage });

    case 'send_imessage': {
      if (!action.bridgeHandleTool) {
        throw new Error('send_imessage is only available when running through the bridge');
      }
      return action.bridgeHandleTool('send_imessage', {
        to: requireString(params.to, 'to'),
        message: requireString(params.message || params.text, 'message')
      }, action.bridgeContext);
    }

    case 'send_tapback': {
      if (!action.bridgeHandleTool) throw new Error('Tool only available via bridge');
      return action.bridgeHandleTool('send_tapback', {
        chatGuid: requireString(params.chatGuid, 'chatGuid'),
        messageGuid: requireString(params.messageGuid, 'messageGuid'),
        reaction: requireString(params.reaction, 'reaction')
      }, action.bridgeContext);
    }

    case 'rename_group': {
      if (!action.bridgeHandleTool) throw new Error('Tool only available via bridge');
      return action.bridgeHandleTool('rename_group', {
        chatGuid: requireString(params.chatGuid, 'chatGuid'),
        displayName: requireString(params.displayName || params.name, 'displayName')
      }, action.bridgeContext);
    }

    case 'mark_chat_read': {
      if (!action.bridgeHandleTool) throw new Error('Tool only available via bridge');
      return action.bridgeHandleTool('mark_chat_read', {
        chatGuid: requireString(params.chatGuid, 'chatGuid')
      }, action.bridgeContext);
    }

    case 'get_handles': {
      if (!action.bridgeHandleTool) throw new Error('Tool only available via bridge');
      return action.bridgeHandleTool('get_handles', {}, action.bridgeContext);
    }

    default:
      throw new Error(`Unknown tool: ${tool}`);
  }
}

function summarizeActionParams(tool, params) {
  try {
    if (!params || typeof params !== 'object') return '';
    switch (tool) {
      case 'click':
      case 'double_click':
      case 'right_click':
        return `(${params.x}, ${params.y})`;
      case 'drag':
        return `(${params.fromX},${params.fromY})->(${params.toX},${params.toY})`;
      case 'scroll':
        return `(${params.direction}, ${params.amount ?? 300})`;
      case 'type':
        return `(${truncate(params.text ?? '', 40)})`;
      case 'keypress':
        return `(${params.keys})`;
      case 'applescript':
        return `(${truncate(params.script ?? '', 60)})`;
      case 'terminal':
        return `(${truncate(params.command ?? '', 60)})`;
      case 'open_app':
        return `(${params.appName})`;
      case 'open_url':
        return `(${truncate(params.url ?? '', 60)})`;
      case 'wait':
        return `(${params.ms}ms)`;

      // Browser Tools
      case 'browser_navigate':
        return `(${truncate(params.url ?? '', 60)})`;
      case 'browser_click':
      case 'browser_type':
        return `(${truncate(params.selector ?? '', 40)})`;
      case 'browser_scroll':
        return `(${params.amount ?? 500})`;
      case 'browser_extract_text':
        return '';

      default:
        return '';
    }
  } catch {
    return '';
  }
}

function summarizeToolResult(result) {
  if (!result) return '(no result)';
  if (typeof result === 'string') return truncate(result, 120);
  if (result.error) return `error: ${truncate(result.error, 120)}`;
  if (typeof result.exitCode === 'number' && result.exitCode !== 0) {
    return `exitCode=${result.exitCode}`;
  }
  if (result.stdout) return truncate(result.stdout, 120);
  return '(ok)';
}

export async function runComputerAgent(options, bridgeContext) {
  // Close browser on completion if needed, but for now we keep it persistent across the session
  // (It will be closed when the process restarts or if we add explicit cleanup logic)

  const {
    task,
    maxSteps = Number(process.env.COMPUTER_AGENT_MAX_STEPS || 20),
    model = process.env.COMPUTER_AGENT_MODEL || 'grok-4-1-fast-non-reasoning',
    imageDetail = process.env.COMPUTER_AGENT_IMAGE_DETAIL || 'low',
    postActionWaitMs = Number(process.env.COMPUTER_AGENT_POST_ACTION_WAIT_MS || 300),
    includeFinalScreenshot = true,
    handleTool: bridgeHandleTool // Callback from the bridge
  } = options || {};

  requireString(task, 'task');

  const client = await createOpenAIClient();
  const basePrompt = await loadSystemPrompt();
  const systemPrompt = buildAugmentedSystemPrompt(basePrompt);

  const history = [];
  let lastToolResult = null;

  let current = await screenshot({ includeCursor: true });
  let currentImageUrl = `data:${current.mimeType};base64,${current.base64}`;

  for (let stepIndex = 1; stepIndex <= maxSteps; stepIndex++) {
    const inputText = buildUserInput({
      task,
      stepIndex,
      maxSteps,
      lastToolResult,
      history
    });

    const completion = await client.chat.completions.create({
      model,
      messages: [
        {
          role: 'system',
          content: systemPrompt
        },
        {
          role: 'user',
          content: [
            { type: 'text', text: inputText },
            { type: 'image_url', image_url: { url: currentImageUrl, detail: imageDetail } }
          ]
        }
      ],
      response_format: {
        type: 'json_schema',
        json_schema: { name: 'computer_agent_step', schema: STEP_SCHEMA, strict: false }
      },
      max_completion_tokens: 4096
    });

    const outputText = completion.choices[0].message.content;
    console.log(`🤖 Model Output (Step ${stepIndex}):`, outputText);
    const decision = extractJson(outputText);
    const action = decision.action;

    if (action?.tool === 'done') {
      const params = action.params || {};
      const status = String(params.status || 'success');
      const summary = String(params.summary || '');
      const data = params.data && typeof params.data === 'object' ? params.data : {};
      const nextSteps = params.next_steps ? String(params.next_steps) : undefined;

      let finalScreenshot;
      if (includeFinalScreenshot) {
        finalScreenshot = current.base64;
      }

      // Cleanup browser on completion? Maybe kept alive for multi-turn sessions if needed.
      // await browser_close();

      return {
        status,
        summary,
        data: { ...data, steps: history },
        screenshot: finalScreenshot,
        next_steps: nextSteps
      };
    }

    let toolResult;
    try {
      // Inject bridge context into action if needed
      const enrichedAction = { ...action, bridgeHandleTool, bridgeContext };
      toolResult = await executeToolAction(enrichedAction);
    } catch (error) {
      toolResult = { error: error.message };
    }

    lastToolResult = toolResult;
    history.push({
      step: stepIndex,
      tool: action.tool,
      params: action.params || {},
      paramsSummary: summarizeActionParams(action.tool, action.params || {}),
      resultSummary: summarizeToolResult(toolResult)
    });

    if (postActionWaitMs > 0) {
      await wait({ ms: postActionWaitMs }).catch(() => { });
    }

    current = await screenshot({ includeCursor: true });
    currentImageUrl = `data:${current.mimeType};base64,${current.base64}`;
  }

  return {
    status: 'partial',
    summary: `Reached max steps (${maxSteps}) before completion`,
    data: { steps: history },
    screenshot: includeFinalScreenshot ? current.base64 : undefined,
    next_steps: 'Increase maxSteps or refine the task instructions.'
  };
}

