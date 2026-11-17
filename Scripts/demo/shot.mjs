// Quick stills for review: node Scripts/demo/shot.mjs <theme> <lang> <t>... -> /tmp/orbpeek-shot-*.png
import { launch, sceneURL } from './browser.mjs';
const [theme = 'light', lang = 'zh', ...times] = process.argv.slice(2);
const browser = await launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
await page.goto(sceneURL({ theme, lang }));
await page.evaluate(() => document.fonts.ready);
console.log(await page.evaluate(() => window.timeline));
for (const t of times) {
  await page.evaluate(t => window.setTime(t), Number(t));
  const path = `/tmp/orbpeek-shot-${theme}-${lang}-${t}.png`;
  await page.screenshot({ path });
  console.log(path);
}
await browser.close();
