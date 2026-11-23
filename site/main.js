const video=document.querySelector('video');
const pause=document.querySelector('.pause');
const en=document.documentElement.lang==='en';
const sync=()=>{if(!pause)return;const paused=video.paused;pause.textContent=paused?'▶':'Ⅱ';pause.setAttribute('aria-label',en?(paused?'Play demo':'Pause demo'):(paused?'播放演示':'暂停演示'));pause.setAttribute('aria-pressed',String(!paused));};
if(video){
 const motion=matchMedia('(prefers-reduced-motion: reduce)');
 const applyMotion=()=>{if(motion.matches)video.pause();else video.play().catch(()=>sync());sync();};
 video.addEventListener('play',sync);video.addEventListener('pause',sync);
 pause.addEventListener('click',()=>video.paused?video.play().catch(sync):video.pause());
 motion.addEventListener('change',applyMotion);applyMotion();
 document.addEventListener('visibilitychange',()=>{if(document.hidden)video.pause();});
}
document.querySelectorAll('[data-copy]').forEach(button=>button.addEventListener('click',async()=>{
 const label=button.textContent;
 try{await navigator.clipboard.writeText(button.dataset.copy);button.textContent=en?'Copied':'已复制';}
 catch{button.textContent=en?'Select command':'请选中复制';}
 setTimeout(()=>button.textContent=label,1800);
}));
