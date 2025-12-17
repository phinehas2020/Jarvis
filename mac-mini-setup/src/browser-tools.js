
import { chromium } from 'playwright';
import fs from 'node:fs/promises';

let browser = null;
let context = null;
let page = null;

// Ensure browser is running
async function ensurePage() {
    if (page) return page;

    if (!browser) {
        console.log('🌐 Launching Playwright browser...');
        browser = await chromium.launch({
            headless: true, // Run headless as requested per user
            args: ['--no-sandbox']
        });
        context = await browser.newContext({
            viewport: { width: 1280, height: 800 },
            userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        });
    }

    if (!context) {
        context = await browser.newContext();
    }

    if (context.pages().length > 0) {
        page = context.pages()[0];
    } else {
        page = await context.newPage();
    }

    return page;
}

export async function browser_navigate({ url }) {
    const p = await ensurePage();
    try {
        await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        return `Navigated to ${url}`;
    } catch (error) {
        return `Error navigating to ${url}: ${error.message}`;
    }
}

export async function browser_click({ selector }) {
    const p = await ensurePage();
    try {
        await p.click(selector, { timeout: 5000 });
        return `Clicked ${selector}`;
    } catch (error) {
        return `Error clicking ${selector}: ${error.message}`;
    }
}

export async function browser_type({ selector, text }) {
    const p = await ensurePage();
    try {
        await p.fill(selector, text, { timeout: 5000 });
        return `Typed "${text}" into ${selector}`;
    } catch (error) {
        return `Error typing into ${selector}: ${error.message}`;
    }
}

export async function browser_press({ key }) {
    const p = await ensurePage();
    try {
        await p.keyboard.press(key);
        return `Pressed key ${key}`;
    } catch (error) {
        return `Error pressing key ${key}: ${error.message}`;
    }
}

export async function browser_scroll({ amount }) {
    const p = await ensurePage();
    try {
        await p.evaluate((y) => window.scrollBy(0, y), amount || 500);
        return `Scrolled by ${amount || 500}`;
    } catch (error) {
        return `Error scrolling: ${error.message}`;
    }
}

export async function browser_screenshot({ fullPage = false } = {}) {
    const p = await ensurePage();
    const buffer = await p.screenshot({ fullPage, type: 'png' });
    return {
        mimeType: 'image/png',
        base64: buffer.toString('base64')
    };
}

export async function browser_extract_text() {
    const p = await ensurePage();
    // Extract visible text, simplified
    const text = await p.evaluate(() => document.body.innerText);
    // Truncate if too long (simple approach)
    return text.substring(0, 5000);
}

export async function browser_get_html() {
    const p = await ensurePage();
    return await p.content();
}

export async function browser_close() {
    if (browser) {
        await browser.close();
        browser = null;
        context = null;
        page = null;
    }
    return 'Browser closed';
}
