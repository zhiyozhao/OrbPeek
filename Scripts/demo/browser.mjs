// Headless Chromium via Playwright. Set PLAYWRIGHT_CORE to a playwright-core
// entry and CHROMIUM to a browser binary if the defaults below don't exist.
import { existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));

function playwrightCore() {
  if (process.env.PLAYWRIGHT_CORE) return process.env.PLAYWRIGHT_CORE;
  const root = execSync('npm root -g').toString().trim();
  for (const p of [`${root}/playwright-core/index.mjs`, `${root}/@playwright/cli/node_modules/playwright-core/index.mjs`, `${root}/playwright/node_modules/playwright-core/index.mjs`]) {
    if (existsSync(p)) return p;
  }
  throw new Error('playwright-core not found; set PLAYWRIGHT_CORE');
}

function chromiumBinary() {
  if (process.env.CHROMIUM) return process.env.CHROMIUM;
  const cache = `${homedir()}/Library/Caches/ms-playwright`;
  for (const v of ['1223', '1208']) {
    const p = `${cache}/chromium-${v}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
    if (existsSync(p)) return p;
  }
  return undefined; // let Playwright pick its bundled build
}

export async function launch() {
  const { chromium } = await import(pathToFileURL(playwrightCore()).href);
  return chromium.launch({ headless: true, executablePath: chromiumBinary() });
}

export function sceneURL(query) {
  return pathToFileURL(path.join(here, 'scene.html')).href + '?' + new URLSearchParams(query);
}
