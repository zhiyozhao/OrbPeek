// Local 2x review screenshots and browser checks. No real desktop capture.
// node Scripts/demo/preview.mjs /absolute/output/directory
import { createServer } from 'node:http';
import { readFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
import { launch } from './browser.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const out=path.resolve(process.argv[2]||path.join(root,'Artifacts/site-v3'));
mkdirSync(out,{recursive:true});
const mime={'.html':'text/html','.css':'text/css','.js':'text/javascript','.png':'image/png','.gif':'image/gif','.mp4':'video/mp4'};
const markdownCSS=`body{margin:0;background:#fff;color:#1f2328;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.box{max-width:1040px;margin:24px auto;padding:32px;border:1px solid #d1d9e0;border-radius:8px}h1{font-size:32px}h1,h2{border-bottom:1px solid #d1d9e0;padding-bottom:8px}h2{margin-top:30px;font-size:24px}a{color:#0969da;text-decoration:none}img{max-width:100%;height:auto}pre{padding:16px;background:#f6f8fa;overflow:auto;border-radius:6px}code,kbd{background:#818b981f;border-radius:4px;padding:2px 5px;font-size:13px}pre code{background:none;padding:0}table{border-collapse:collapse}td,th{border:1px solid #d1d9e0;padding:7px 12px}li+li{margin-top:6px}p{margin:16px 0}@media(prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}.box,h1,h2,td,th{border-color:#3d444d}a{color:#4493f8}pre{background:#151b23}}`;
const readmes=Object.fromEntries(['zh','en'].map(lang=>{
 const html=execFileSync('pandoc',['-f','gfm','-t','html',path.join(root,lang==='zh'?'README.md':'README.en.md')],{encoding:'utf8'});
 return [lang,`<!doctype html><html lang="${lang}"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><base href="/"><style>${markdownCSS}</style><main class="box">${html}</main></html>`];
}));
const server=createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname.startsWith('/review-readme-')){
  res.setHeader('Content-Type','text/html; charset=utf-8');res.end(readmes[url.pathname.includes('-en')?'en':'zh']);return;
 }
 let file=path.resolve(root,'.'+decodeURIComponent(url.pathname));
 if(!file.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
 if(url.pathname.endsWith('/'))file=path.join(file,'index.html');
 if(!existsSync(file)){res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type',mime[path.extname(file)]||'application/octet-stream');res.end(readFileSync(file));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base=`http://127.0.0.1:${server.address().port}`;
let browser;
const results=[];
try{
 browser=await launch();
 for(const lang of ['zh','en'])for(const scheme of ['light','dark'])for(const [device,width,height] of [['desktop',1440,900],['mobile',390,844]]){
  const ctx=await browser.newContext({viewport:{width,height},deviceScaleFactor:2,colorScheme:scheme,isMobile:device==='mobile',hasTouch:device==='mobile'});
  const page=await ctx.newPage(),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));page.on('console',m=>{if(m.type()==='error')errors.push(m.text())});
  await page.goto(base+'/site/'+(lang==='en'?'en/':''),{waitUntil:'networkidle'});
  await page.locator('video').evaluate(async v=>{await v.play();await new Promise(r=>setTimeout(r,250));});
  assert.equal(await page.locator('video').evaluate(v=>v.paused),false,'muted autoplay');
  await page.locator('.pause').click();assert.equal(await page.locator('video').evaluate(v=>v.paused),true,'pause button');
  // Let decoding and compositing advance naturally; seeked alone can still
  // leave Chromium's poster in a screenshot after a very early pause.
  await page.locator('video').evaluate(v=>v.play());
  await page.waitForFunction(()=>document.querySelector('video').currentTime>=2.5);
  await page.locator('video').evaluate(v=>v.pause());
  const geometry=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth-innerWidth,hero:document.querySelector('.hero').getBoundingClientRect().height,viewport:innerHeight,intro:document.querySelector('.intro').getBoundingClientRect().top,video:document.querySelector('video').getBoundingClientRect().toJSON(),pixels:[document.querySelector('video').videoWidth,document.querySelector('video').videoHeight]}));
  assert.equal(geometry.overflow,0,'horizontal overflow');assert.equal(geometry.hero,height,'one viewport hero');assert.equal(geometry.intro,height,'no next section in first viewport');assert.deepEqual(geometry.pixels,[2880,1880]);
  const name=`orbpeek-site-${lang}-${scheme}-${device}`;
  await page.screenshot({path:path.join(out,name+'-first-screen.png')});
  await page.screenshot({path:path.join(out,name+'.png'),fullPage:true});
  await page.locator('.next').click();
  await page.waitForFunction(()=>Math.abs(document.querySelector('#install').getBoundingClientRect().top-36)<2);
  await page.locator('summary').click();assert.equal(await page.locator('details').getAttribute('open'),'');
  await page.evaluate(()=>{Object.defineProperty(navigator,'clipboard',{value:{writeText:async text=>{window.copied=text}}})});
  await page.locator('[data-copy]').click();assert.equal(await page.evaluate(()=>window.copied),'brew install --cask zhiyozhao/tap/orbpeek');
  await page.emulateMedia({reducedMotion:'reduce'});assert.equal(await page.locator('video').evaluate(v=>v.paused),true,'reduced motion');
  const links=await page.locator('a').evaluateAll(as=>as.map(a=>a.href).filter(h=>h.startsWith(location.origin)&&!h.includes('#')));
  for(const href of links){const response=await ctx.request.get(href);assert(response.ok(),href);}
  assert.deepEqual(errors,[]);
  results.push({lang,scheme,device,...geometry,errors,autoplay:true,pause:true,copy:true,installAnchor:true,gatekeeperDisclosure:true,reducedMotion:true});
  await ctx.close();console.log(name,'OK');
 }
 for(const lang of ['zh','en'])for(const scheme of ['light','dark']){
  const ctx=await browser.newContext({viewport:{width:1280,height:900},deviceScaleFactor:2,colorScheme:scheme});const page=await ctx.newPage();
  await page.goto(`${base}/review-readme-${lang}`,{waitUntil:'networkidle'});
  assert.equal(await page.locator('img').evaluateAll(imgs=>imgs.every(i=>i.complete&&i.naturalWidth>0)),true,'README images');
  // Freeze only this review rendering at a representative animation frame.
  await page.locator('img[src$=".gif"]').evaluate((img,src)=>new Promise(resolve=>{img.onload=resolve;img.src=src}),`/Artifacts/demo-v3/${lang}-left.png`);
  await page.screenshot({path:path.join(out,`orbpeek-readme-${lang}-${scheme}-first-screen.png`)});
  await page.screenshot({path:path.join(out,`orbpeek-readme-${lang}-${scheme}.png`),fullPage:true});
  results.push({readme:lang,scheme,images:true,preview:'local GFM rendering, not a live GitHub screenshot'});await ctx.close();
 }
 writeFileSync(path.join(out,'orbpeek-checks.json'),JSON.stringify(results,null,2)+'\n');
}finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
