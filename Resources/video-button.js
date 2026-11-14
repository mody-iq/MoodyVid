/* One optional shortcut per frame.  The native sniffer button remains available
 * when a site hides or replaces this element.  This runs in an isolated WebKit
 * content world: page scripts cannot call its private message handler. */
(function () {
  'use strict';
  if (window.__moodyVidVideoButtonInstalled) return;
  window.__moodyVidVideoButtonInstalled = true;
  var button = null;
  var scheduled = false;
  var label = __MV_VIDEO_BUTTON_LABEL__;

  function setStyle(element, values) {
    Object.keys(values).forEach(function (key) {
      element.style.setProperty(key, values[key], 'important');
    });
  }

  function createButton() {
    var b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('aria-label', label);
    b.title = label;
    b.textContent = '\u2913';
    setStyle(b, {
      'all': 'initial', 'position': 'fixed', 'z-index': '2147483646',
      'box-sizing': 'border-box', 'display': 'none', 'width': '40px',
      'height': '40px', 'padding': '0', 'border': '0', 'border-radius': '20px',
      'background': '#0b8e9c', 'color': '#fff', 'font': 'bold 26px sans-serif',
      'line-height': '40px', 'text-align': 'center', 'cursor': 'pointer',
      'touch-action': 'manipulation', 'opacity': '0.95'
    });
    b.addEventListener('click', function (event) {
      // Synthetic page clicks must never open the native UI.
      if (!event.isTrusted) return;
      event.preventDefault();
      event.stopPropagation();
      try { window.webkit.messageHandlers.moodyvidVideoButton.postMessage({type: 'videoButton'}); }
      catch (ignored) {}
    });
    return b;
  }

  function update() {
    scheduled = false;
    if (!document.body) return;
    var best = null;
    var bestArea = 0;
    var width = window.innerWidth || document.documentElement.clientWidth || 0;
    var height = window.innerHeight || document.documentElement.clientHeight || 0;
    Array.prototype.forEach.call(document.querySelectorAll('video'), function (video) {
      var r = video.getBoundingClientRect();
      // Ignore tiny thumbnails and off-screen players. Use only the visible area.
      var left = Math.max(0, r.left), top = Math.max(0, r.top);
      var right = Math.min(width, r.right), bottom = Math.min(height, r.bottom);
      var visibleWidth = right - left, visibleHeight = bottom - top;
      if (visibleWidth < 120 || visibleHeight < 70) return;
      var style = window.getComputedStyle(video);
      if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return;
      var area = visibleWidth * visibleHeight;
      if (area > bestArea) { bestArea = area; best = {right: right, top: top}; }
    });
    if (!best) {
      if (button) button.style.setProperty('display', 'none', 'important');
      return;
    }
    if (!button) button = createButton();
    if (!button.isConnected) document.body.appendChild(button);
    button.style.setProperty('left', Math.max(0, best.right - 48) + 'px', 'important');
    button.style.setProperty('top', Math.max(0, best.top + 8) + 'px', 'important');
    button.style.setProperty('display', 'block', 'important');
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(function () {
      try { update(); } catch (ignored) { scheduled = false; }
    });
  }
  document.addEventListener('DOMContentLoaded', schedule);
  window.addEventListener('load', schedule);
  window.addEventListener('scroll', schedule, true);
  window.addEventListener('resize', schedule);
  try {
    new MutationObserver(schedule).observe(document.documentElement || document, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['src', 'hidden']
    });
  } catch (ignored) {}
  // Some SPAs resize existing players without changing the DOM or firing resize.
  window.setInterval(schedule, 2000);
  schedule();
})();
