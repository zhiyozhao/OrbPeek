// Local screenshots of the site and README for review (headless, 2x).
//   node Scripts/demo/preview.mjs <out-dir>
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { launch } from './browser.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const out = path.resolve(process.argv[2] || path.join(root, 'Artifacts/preview'));
mkdirSync(out, { recursive: true });

const PORT = Number(process.env.PORT || 4391);
const server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1', '--directory', path.join(root, 'site')], { stdio: 'ignore' });
await new Promise(r => setTimeout(r, 800));

// README rendered with pandoc (GFM) inside a GitHub-like column.
const readmeCSS = `
  :root { color-scheme: light dark; }
  body { margin: 0; background: #fff; color: #1f2328; font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif; }
  .box { max-width: 980px; margin: 24px auto; padding: 32px; box-sizing: border-box; }
  @media (max-width: 600px) { .box { padding: 16px; margin: 0; } }
  a { color: #0969da; text-decoration: none; }
  h1 { font-size: 2em; margin: .67em 0; font-weight: 600; }
  h2 { font-size: 1.5em; font-weight: 600; padding-bottom: .3em; border-bottom: 1px solid #d1d9e0b3; margin: 24px 0 16px; }
  p, ul, table, pre, picture { margin: 0 0 16px; }
  img { max-width: 100%; height: auto; }
  code { font: 85% ui-monospace, SFMono-Regular, Menlo, monospace; background: #818b981f; padding: .2em .4em; border-radius: 6px; }
  pre { background: #f6f8fa; padding: 16px; border-radius: 6px; overflow: auto; }
  pre code { background: none; padding: 0; font-size: 85%; }
  table { border-collapse: collapse; display: block; overflow: auto; }
  th, td { border: 1px solid #d1d9e0; padding: 6px 13px; }
  th { font-weight: 600; }
  tr:nth-child(2n) { background: #f6f8fa; }
  kbd { display: inline-block; padding: 0 5px; font: 11px ui-monospace, Menlo, monospace; line-height: 20px; color: #1f2328; background: #f6f8fa; border: 1px solid #d1d9e0b3; border-radius: 6px; box-shadow: inset 0 -1px 0 #d1d9e0b3; }
  ul { padding-left: 2em; } li + li { margin-top: .25em; }
  @media (prefers-color-scheme: dark) { body { background: #0d1117; color: #e6edf3; } a { color: #4493f8 !important; } code, pre { background: #151b23 !important; } th, td { border-color: #3d444d !important; } h2 { border-color: #3d444db3 !important; } kbd { background: #151b23 !important; border-color: #3d444db3 !important; box-shadow: inset 0 -1px 0 #3d444db3 !important; color: #e6edf3; } tr:nth-child(2n) { background: #151b23; } }
`;
for (const name of ['README.md', 'README.en.md']) {
  const html = execFileSync('pandoc', ['-f', 'gfm', '-t', 'html', path.join(root, name)]).toString();
  writeFileSync(path.join(root, `.${name}.preview.html`), `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><style>${readmeCSS}</style><div class="box">${html}</div>`);
}

const browser = await launch();
const shots = [];
for (const lang of ['zh', 'en']) {
  for (const scheme of ['light', 'dark']) {
    for (const [device, viewport] of [['desktop', { width: 1440, height: 900 }], ['mobile', { width: 390, height: 844 }]]) {
      const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2, colorScheme: scheme, isMobile: device === 'mobile', hasTouch: device === 'mobile' });
      const page = await ctx.newPage();
      const errors = [];
      page.on('console', m => m.type() === 'error' && errors.push(m.text()));
      page.on('pageerror', e => errors.push(String(e)));
      await page.goto(`http://127.0.0.1:${PORT}/${lang === 'en' ? 'en/' : ''}`, { waitUntil: 'networkidle' });
      // Show a representative frame: the window peeked out.
      await page.evaluate(async () => {
        const v = document.getElementById('demo');
        v.currentTime = 0;
        await v.play();
        await new Promise(r => { const tick = () => v.currentTime >= 4.6 ? r() : requestAnimationFrame(tick); tick(); });
        v.pause();
      });
      await page.waitForTimeout(400);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      const src = await page.evaluate(() => document.getElementById('demo').currentSrc.split('/').pop());
      const install = await page.evaluate(() => {
        const r = document.getElementById('install').getBoundingClientRect();
        return { top: Math.round(r.top), bottom: Math.round(r.bottom), viewport: window.innerHeight };
      });
      const file = path.join(out, `site-${lang}-${scheme}-${device}.png`);
      await page.screenshot({ path: path.join(out, `site-${lang}-${scheme}-${device}-first-screen.png`) });
      await page.screenshot({ path: file, fullPage: true });
      // The nav button must land on the install section.
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.click('.nav .btn');
      await page.waitForTimeout(900);
      const afterClick = await page.evaluate(() => Math.round(document.getElementById('install').getBoundingClientRect().top));
      await page.evaluate(() => window.scrollTo(0, 0));
      shots.push({ file: path.basename(file), video: src, horizontalOverflow: overflow, errors, install, installTopAfterNavClick: afterClick });
      await ctx.close();
    }
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2, colorScheme: scheme });
    const page = await ctx.newPage();
    const name = lang === 'en' ? 'README.en.md' : 'README.md';
    await page.goto(pathToFileURL(path.join(root, `.${name}.preview.html`)).href, { waitUntil: 'load' });
    const file = path.join(out, `readme-${lang}-${scheme}.png`);
    const install = await page.evaluate(() => {
      const h = [...document.querySelectorAll('h2')].find(e => /^(安装|Install)$/.test(e.textContent.trim()));
      const pre = h.nextElementSibling.getBoundingClientRect();
      return { headingTop: Math.round(h.getBoundingClientRect().top), commandBottom: Math.round(pre.bottom), viewport: window.innerHeight };
    });
    await page.screenshot({ path: path.join(out, `readme-${lang}-${scheme}-first-screen.png`) });
    await page.screenshot({ path: file, fullPage: true });
    shots.push({ file: path.basename(file), install });
    await ctx.close();
  }
}
await browser.close();
server.kill();
for (const name of ['README.md', 'README.en.md']) execFileSync('rm', ['-f', path.join(root, `.${name}.preview.html`)]);
writeFileSync(path.join(out, 'checks.json'), JSON.stringify(shots, null, 2));
console.log(JSON.stringify(shots, null, 2));
