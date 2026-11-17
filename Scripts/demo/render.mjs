// Render the OrbPeek demo from scene.html in headless Chromium, frame by frame
// at 2x, then encode with ffmpeg. Nothing is drawn on a real screen.
//
//   node Scripts/demo/render.mjs            # all variants
//   node Scripts/demo/render.mjs light zh   # one variant
//   node Scripts/demo/render.mjs --encode-only  # re-encode existing frames
//
// Outputs (per <lang>-<theme>):
//   site/assets/demo-<lang>-<theme>.mp4 / .webm   2880x1800, 60 fps
//   site/assets/poster-<lang>-<theme>.jpg         first frame, video poster
//   docs/assets/demo-<lang>-<theme>.gif           README animation, 1600 wide, 30 fps
//   docs/assets/hero-<lang>-<theme>.png           2880x1800 still, window peeked
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch, sceneURL } from './browser.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const FPS = 60;
const site = path.join(root, 'site/assets');
const docs = path.join(root, 'docs/assets');
const work = path.join(root, 'Artifacts/demo-frames');
mkdirSync(site, { recursive: true });
mkdirSync(docs, { recursive: true });

const encodeOnly = process.argv.includes('--encode-only');
const args = process.argv.slice(2).filter(a => !a.startsWith('--'));
const themes = args[0] ? [args[0]] : ['light', 'dark'];
const langs = args[1] ? [args[1]] : ['zh', 'en'];
const variants = themes.flatMap(theme => langs.map(lang => ({ theme, lang })));

const ff = (...a) => execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...a], { stdio: 'inherit' });

async function renderVariant(browser, { theme, lang }) {
  const name = `${lang}-${theme}`;
  const dir = path.join(work, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  await page.goto(sceneURL({ theme, lang }));
  await page.evaluate(() => document.fonts.ready);
  const tl = await page.evaluate(() => window.timeline);

  // Opening frame doubles as the loop cross-fade target and the poster.
  await page.evaluate(() => window.setTime(0));
  const first = await page.screenshot({ type: 'png' });
  await page.evaluate(b64 => {
    const fade = document.getElementById('fade');
    fade.style.background = `url(data:image/png;base64,${b64}) 0 0 / 1440px 900px`;
  }, first.toString('base64'));

  writeFileSync(path.join(dir, 'timeline.json'), JSON.stringify(tl));
  const frames = Math.round(tl.DURATION * FPS);
  for (let i = 0; i < frames; i++) {
    await page.evaluate(t => window.setTime(t), i / FPS);
    await page.screenshot({ path: path.join(dir, `${String(i).padStart(4, '0')}.png`) });
  }

  // Still: the window peeked out (hero image).
  await page.evaluate(t => window.setTime(t), tl.PEEK_AT + 0.75);
  await page.screenshot({ path: path.join(docs, `hero-${name}.png`) });
  await page.close();
  return { name, dir, frames };
}

let done;
if (encodeOnly) {
  done = variants.map(({ theme, lang }) => ({ name: `${lang}-${theme}`, dir: path.join(work, `${lang}-${theme}`) }));
} else {
  const browser = await launch();
  done = await Promise.all(variants.map(v => renderVariant(browser, v)));
  await browser.close();
}

for (const { name, dir } of done) {
  const tl = JSON.parse(readFileSync(path.join(dir, 'timeline.json'), 'utf8'));
  const total = Math.round(tl.DURATION * FPS);
  const fadeFrom = Math.round(tl.FADE_START * FPS);
  const input = ['-framerate', String(FPS), '-i', path.join(dir, '%04d.png')];
  ff(...input, '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p',
     '-tune', 'animation', '-movflags', '+faststart', path.join(site, `demo-${name}.mp4`));
  ff(...input, '-c:v', 'libvpx-vp9', '-crf', '32', '-b:v', '0', '-row-mt', '1', '-deadline', 'good', '-cpu-used', '2',
     '-pix_fmt', 'yuv420p', path.join(site, `demo-${name}.webm`));
  ff('-i', path.join(dir, '0000.png'), '-q:v', '3', path.join(site, `poster-${name}.jpg`));
  // GIF: 30 fps, ordered dither (stable from frame to frame, so unchanged
  // areas cost nothing), and the loop cross-fade thinned to 10 fps because
  // every fade frame repaints the whole window area.
  const list = [];
  for (let i = 0; i < total;) {
    const step = i >= fadeFrom ? 6 : 2;
    list.push(`file '${path.join(dir, String(i).padStart(4, '0') + '.png')}'`, `duration ${step / FPS}`);
    i += step;
  }
  list.push(`file '${path.join(dir, '0000.png')}'`);
  const listFile = path.join(dir, 'gif.txt');
  writeFileSync(listFile, list.join('\n') + '\n');
  ff('-f', 'concat', '-safe', '0', '-i', listFile, '-filter_complex',
     'scale=1600:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle',
     '-loop', '0', path.join(docs, `demo-${name}.gif`));
  console.log('encoded', name);
}
writeFileSync(path.join(work, 'done.txt'), new Date().toISOString());
