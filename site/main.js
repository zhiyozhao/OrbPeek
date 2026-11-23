// Copy the install command. No third-party code, no tracking.
(function () {
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
