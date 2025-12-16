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
    '- done: {status, summary, data?, next_steps?}',
    '',
    'Do NOT call browser_* tools (Playwright is not available).',
    '',
    'You must choose exactly ONE action each step and respond with ONLY valid JSON matching this shape:',
    '{"thought": "...", "action": {"tool": "click|double_click|right_click|drag|scroll|type|keypress|applescript|terminal|open_app|open_url|wait|done", "params": {}}}',
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

  return JSON.parse(trimmed);
}

async function createOpenAIClient() {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error('OPENAI_API_KEY is required to use execute_task');
  }

  const { default: OpenAI } = await import('openai');
  return new OpenAI({ apiKey });
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

export async function runComputerAgent(options) {
  const {
    task,
    maxSteps = Number(process.env.COMPUTER_AGENT_MAX_STEPS || 20),
    model = process.env.COMPUTER_AGENT_MODEL || 'gpt-5-2025-08-07',
    imageDetail = process.env.COMPUTER_AGENT_IMAGE_DETAIL || 'high',
    postActionWaitMs = Number(process.env.COMPUTER_AGENT_POST_ACTION_WAIT_MS || 300),
    includeFinalScreenshot = true
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

    const decision = extractJson(completion.choices[0].message.content);
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
      toolResult = await executeToolAction(action);
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

