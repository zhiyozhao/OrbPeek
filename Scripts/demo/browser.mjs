import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

export async function launch() {
  const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  const entry = process.env.PLAYWRIGHT_CORE || [
    `${root}/playwright-core/index.mjs`,
    `${root}/@playwright/cli/node_modules/playwright-core/index.mjs`,
  ].find(existsSync);
  if (!entry) throw new Error('Set PLAYWRIGHT_CORE to an installed playwright-core/index.mjs.');
  const { chromium } = await import(pathToFileURL(entry).href);
  const executablePath = process.env.CHROMIUM || ['1223', '1208'].map(v =>
    `${homedir()}/Library/Caches/ms-playwright/chromium-${v}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`
  ).find(existsSync);
  return chromium.launch({ headless: true, executablePath });
}
