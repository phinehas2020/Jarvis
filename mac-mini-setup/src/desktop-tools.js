import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';

function execFileResult(file, args, options = {}) {
  const {
    timeoutMs = 60_000,
    cwd,
    env,
    maxBuffer = 10 * 1024 * 1024
  } = options;

  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      { timeout: timeoutMs, cwd, env, maxBuffer },
      (error, stdout, stderr) => {
        if (error?.code === 'ENOENT') {
          const notFound = new Error(`Command not found: ${file}`);
          notFound.code = 'ENOENT';
          return reject(notFound);
        }

        const exitCode = typeof error?.code === 'number' ? error.code : 0;

        resolve({
          stdout: stdout?.toString?.() ?? String(stdout ?? ''),
          stderr: stderr?.toString?.() ?? String(stderr ?? ''),
          exitCode,
          timedOut: Boolean(error?.killed && error?.signal)
        });
      }
    );
  });
}

function toInt(value, label) {
  const numberValue = Number(value);
  if (!Number.isFinite(numberValue)) {
    throw new Error(`${label} must be a finite number`);
  }
  return Math.round(numberValue);
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

let cachedCliclickPath = null;
async function resolveCliclickPath() {
  if (cachedCliclickPath) return cachedCliclickPath;

  const fromEnv = process.env.CLICLICK_PATH;
  if (fromEnv) {
    if (!(await fileExists(fromEnv))) {
      throw new Error(`CLICLICK_PATH is set but not found: ${fromEnv}`);
    }
    cachedCliclickPath = fromEnv;
    return cachedCliclickPath;
  }

  const homebrewCandidates = [
    '/opt/homebrew/bin/cliclick',
    '/usr/local/bin/cliclick'
  ];
  for (const candidate of homebrewCandidates) {
    if (await fileExists(candidate)) {
      cachedCliclickPath = candidate;
      return cachedCliclickPath;
    }
  }

  try {
    const which = await execFileResult('/usr/bin/which', ['cliclick'], {
      timeoutMs: 3_000
    });
    if (which.exitCode === 0 && which.stdout.trim()) {
      cachedCliclickPath = which.stdout.trim();
      return cachedCliclickPath;
    }
  } catch {
    // ignore
  }

  throw new Error('cliclick is required for mouse/keyboard control. Install with: brew install cliclick');
}

async function runCliclick(commands, options = {}) {
  const cliclickPath = await resolveCliclickPath();
  return execFileResult(cliclickPath, commands, options);
}

export async function screenshot(options = {}) {
  const {
    display,
    format = 'png',
    includeCursor = true,
    timeoutMs = 30_000
  } = options;

  const safeFormat = format === 'jpg' || format === 'jpeg' ? 'jpg' : 'png';
  const mimeType = safeFormat === 'png' ? 'image/png' : 'image/jpeg';

  const filename = `screenshot-${crypto.randomUUID()}.${safeFormat}`;
  const filePath = path.join(os.tmpdir(), filename);

  const args = ['-x', '-t', safeFormat];
  if (includeCursor) args.push('-C');
  if (Number.isInteger(display)) args.push('-D', String(display));
  args.push(filePath);

  try {
    await execFileResult('/usr/sbin/screencapture', args, { timeoutMs });
    const buffer = await fs.readFile(filePath);
    return {
      mimeType,
      base64: buffer.toString('base64')
    };
  } finally {
    await fs.unlink(filePath).catch(() => {});
  }
}

export async function click({ x, y }, options = {}) {
  return runCliclick([`c:${toInt(x, 'x')},${toInt(y, 'y')}`], options);
}

export async function doubleClick({ x, y }, options = {}) {
  return runCliclick([`dc:${toInt(x, 'x')},${toInt(y, 'y')}`], options);
}

export async function rightClick({ x, y }, options = {}) {
  return runCliclick([`rc:${toInt(x, 'x')},${toInt(y, 'y')}`], options);
}

export async function drag({ fromX, fromY, toX, toY }, options = {}) {
  const startX = toInt(fromX, 'fromX');
  const startY = toInt(fromY, 'fromY');
  const endX = toInt(toX, 'toX');
  const endY = toInt(toY, 'toY');

  return runCliclick([`dd:${startX},${startY}`, `m:${endX},${endY}`, `du:${endX},${endY}`], options);
}

export async function scroll({ direction, amount = 300 }, options = {}) {
  const delta = toInt(amount, 'amount');
  const dir = String(direction || '').toLowerCase();

  let dx = 0;
  let dy = 0;

  switch (dir) {
    case 'up':
      dy = -delta;
      break;
    case 'down':
      dy = delta;
      break;
    case 'left':
      dx = -delta;
      break;
    case 'right':
      dx = delta;
      break;
    default:
      throw new Error(`direction must be one of: up, down, left, right (got: ${direction})`);
  }

  return runCliclick([`sc:${dx},${dy}`], options);
}

export async function typeText({ text }, options = {}) {
  const value = text ?? '';
  if (typeof value !== 'string') throw new Error('text must be a string');
  return runCliclick([`t:${value}`], options);
}

export async function keypress({ keys }, options = {}) {
  const value = String(keys ?? '').trim();
  if (!value) throw new Error('keys is required');

  const parts = value.split('+').map((p) => p.trim()).filter(Boolean);

  const normalize = (key) => {
    const k = key.toLowerCase();
    if (k === 'command' || k === 'cmd' || k === 'meta') return 'cmd';
    if (k === 'option' || k === 'opt' || k === 'alt') return 'alt';
    if (k === 'control' || k === 'ctrl') return 'ctrl';
    if (k === 'shift') return 'shift';
    return key;
  };

  if (parts.length <= 1) {
    return runCliclick([`kp:${normalize(value)}`], options);
  }

  const normalized = parts.map(normalize);
  const modifiers = normalized.slice(0, -1);
  const mainKey = normalized[normalized.length - 1];

  const down = modifiers.map((m) => `kd:${m}`);
  const up = modifiers.slice().reverse().map((m) => `ku:${m}`);

  return runCliclick([...down, `kp:${mainKey}`, ...up], options);
}

export async function applescript({ script }, options = {}) {
  const value = script ?? '';
  if (typeof value !== 'string') throw new Error('script must be a string');
  return execFileResult('/usr/bin/osascript', ['-e', value], options);
}

export async function terminal({ command, timeoutMs = 60_000, cwd } = {}, options = {}) {
  const value = command ?? '';
  if (typeof value !== 'string' || !value.trim()) throw new Error('command is required');
  return execFileResult('/bin/zsh', ['-lc', value], { ...options, timeoutMs, cwd });
}

export async function openApp({ appName }, options = {}) {
  const value = appName ?? '';
  if (typeof value !== 'string' || !value.trim()) throw new Error('appName is required');
  return execFileResult('/usr/bin/open', ['-a', value], options);
}

export async function openUrl({ url }, options = {}) {
  const value = url ?? '';
  if (typeof value !== 'string' || !value.trim()) throw new Error('url is required');
  return execFileResult('/usr/bin/open', [value], options);
}

export async function wait({ ms }, options = {}) {
  const delayMs = toInt(ms, 'ms');
  const effective = Math.max(0, delayMs);
  const timeoutMs = options.timeoutMs ?? effective + 5_000;

  await Promise.race([
    new Promise((resolve) => setTimeout(resolve, effective)),
    new Promise((_, reject) => setTimeout(() => reject(new Error('wait timed out')), timeoutMs))
  ]);

  return { stdout: '', stderr: '', exitCode: 0, timedOut: false };
}

