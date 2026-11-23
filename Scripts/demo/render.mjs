// Code-only desktop; no screen/window capture, permissions or app process.
// node Scripts/demo/render.mjs [zh|en]   (requires Playwright + ffmpeg)
import { mkdirSync, copyFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { launch } from './browser.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const assets=path.join(root,'site/assets');
const langs=process.argv[2]?[process.argv[2]]:['zh','en'];
const fps=24;
const ff=(...args)=>execFileSync('ffmpeg',['-hide_banner','-loglevel','error','-y',...args],{stdio:'inherit'});
const browser=await launch();
try {
 for(const lang of langs){
  const frames=path.join(root,'Artifacts/demo-v3',lang);mkdirSync(frames,{recursive:true});
  const page=await browser.newPage({viewport:{width:1440,height:940},deviceScaleFactor:2});
  await page.goto(pathToFileURL(path.join(root,'Scripts/demo/scene.html')).href+'?lang='+lang);
  await page.evaluate(()=>document.fonts.ready);
  await page.evaluate(()=>window.setTime(0));
  await page.screenshot({path:path.join(assets,`poster-${lang}.png`)});
  const cached=new Map();
  for(let i=0;i<20*fps;i++){
   const state=await page.evaluate(t=>window.setTime(t),i/fps);
   const frame=path.join(frames,String(i).padStart(4,'0')+'.png');
   if(cached.has(state))copyFileSync(cached.get(state),frame);
   else{await page.screenshot({path:frame});cached.set(state,frame);}
   if(i%120===0)console.log(lang,`${i}/${20*fps}`);
  }
  for(const [edge,t] of [['left',2.5],['right',7.5],['up',12.5],['down',17.5]]){
   await page.evaluate(t=>window.setTime(t),t);
   await page.screenshot({path:path.join(root,'Artifacts/demo-v3',`${lang}-${edge}.png`)});
  }
  await page.close();
  ff('-framerate',String(fps),'-i',path.join(frames,'%04d.png'),'-c:v','libx264','-preset','slow','-crf','21','-tune','animation','-pix_fmt','yuv420p','-movflags','+faststart',path.join(assets,`demo-${lang}.mp4`));
  // GIF also keeps the complete 2x image; 12 fps is enough for the pointer.
  ff('-framerate',String(fps),'-i',path.join(frames,'%04d.png'),'-filter_complex','fps=12,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle','-loop','0',path.join(assets,`demo-${lang}.gif`));
  console.log('encoded',lang);
 }
} finally {await browser.close();}
