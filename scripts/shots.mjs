// Screenshots of panel.html for the README (dev-only; not shipped, not run by CI).
//
// Renders the panel headlessly in Chromium with a sample payload in the URL fragment, the same way the
// popover loads it, and writes docs/<theme>.png (one provider) and docs/<theme>-all.png (three providers)
// at the popover's size, 520×316, at 2× for retina.
//
//   mkdir -p /tmp/shots && cd /tmp/shots && npm i playwright@1.48.2 && npx playwright install chromium
//   node /path/to/pulse-limits/scripts/shots.mjs            # run from that directory: playwright resolves there
//
// The sample numbers are illustrative, not anyone's real usage.
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const require = createRequire(path.join(process.cwd(), 'noop.js'));
const { chromium } = require('playwright');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const panel = pathToFileURL(path.join(root, 'panel.html')).href;
const THEMES = ['orbit', 'ember', 'herbarium'];

const now = Date.now();
const at = ms => new Date(now + ms).toISOString();
const H = 3600e3, M = 60e3, Dd = 24 * H;
const fetched = Math.floor(now / 1000) - 60;

// twelve hours of the session window: quiet, a busy afternoon, quiet again, rising now
const history = [];
for (let k = 72; k >= 0; k--) {
  const h = -k / 6, v = 4 + 66 * Math.exp(-((h + 6) ** 2) / (2 * 1.6 ** 2)) + (h > -1.5 ? 12 * (h + 1.5) / 1.5 : 0);
  history.push([Math.floor((now + h * H) / 1000), Math.round(v)]);
}

const claude = {
  name: 'claude', plan: 'MAX 20X', status: '', hint: '', fetched,
  windows: [
    { label: 'SESSION', pct: 16, resets: at(2 * H + 2 * M + 30e3) },
    { label: 'WEEK', pct: 4, resets: at(6 * Dd + 14 * H + 30 * M) },
    { label: 'FABLE', pct: 7, resets: at(6 * Dd + 14 * H + 30 * M) },
  ],
  activity: { tok_per_min: 3400, idle_s: 0, sessions: 7 },
};
const codex = {
  name: 'codex', plan: 'PRO', status: '', hint: '', fetched,
  windows: [
    { label: 'SESSION', pct: 42, resets: at(1 * H + 10 * M + 30e3) },
    { label: 'WEEK', pct: 18, resets: at(4 * Dd + 2 * H + 30 * M) },
  ],
  activity: { tok_per_min: 1100, idle_s: 0, sessions: 2 },
};
const grok = {
  name: 'grok', plan: 'SUPERGROK', status: '', hint: '', fetched,
  windows: [
    { label: 'WEEK', pct: 63, resets: at(3 * Dd + 4 * H + 30 * M) },
    { label: 'ONDEMAND', pct: 0, resets: at(3 * Dd + 4 * H + 30 * M) },
  ],
  activity: { tok_per_min: 0, idle_s: 720, sessions: 0 },
};

const payload = (theme, providers) => ({
  provider: 'claude', plan: claude.plan, source: 'API', theme, fetched, history,
  activity: claude.activity, status: '', hint: '', windows: claude.windows, credits: null, providers,
});
const b64 = obj => Buffer.from(JSON.stringify(obj), 'utf8').toString('base64');

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 520, height: 316 }, deviceScaleFactor: 2 });
for (const theme of THEMES) {
  for (const [suffix, providers] of [['', [claude]], ['-all', [claude, codex, grok]]]) {
    // a distinct query per shot: a fragment-only change would not reload the page
    await page.goto(`${panel}?theme=${theme}&shot=${suffix || 'one'}#${b64(payload(theme, providers))}`);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(1800);
    const out = path.join(root, 'docs', `${theme}${suffix}.png`);
    await page.screenshot({ path: out });
    console.log(out);
  }
}
await browser.close();
