// Pick the demo for the current appearance, honour reduced motion, copy the
// install command. No third-party code, no tracking.
(function () {
  var video = document.getElementById('demo');
  var dark = window.matchMedia('(prefers-color-scheme: dark)');
  var still = window.matchMedia('(prefers-reduced-motion: reduce)');

  function load() {
    if (!video) return;
    var base = video.getAttribute('data-base') + (dark.matches ? 'dark' : 'light');
    video.poster = base.replace('demo-', 'poster-') + '.jpg';
    video.innerHTML =
      '<source src="' + base + '.webm" type="video/webm">' +
      '<source src="' + base + '.mp4" type="video/mp4">';
    if (still.matches) {
      video.removeAttribute('autoplay');
      video.controls = true;
      video.load();
    } else {
      video.load();
      var p = video.play();
      if (p && p.catch) p.catch(function () { video.controls = true; });
    }
  }
  load();
  if (dark.addEventListener) dark.addEventListener('change', load);

  var button = document.querySelector('.copy');
  if (button && navigator.clipboard) {
    var label = button.textContent;
    button.addEventListener('click', function () {
      navigator.clipboard.writeText(button.getAttribute('data-copy')).then(function () {
        button.textContent = button.getAttribute('data-done');
        setTimeout(function () { button.textContent = label; }, 1600);
      });
    });
  } else if (button) {
    button.hidden = true;
  }
})();
