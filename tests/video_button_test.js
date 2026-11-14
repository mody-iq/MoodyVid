'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

let videos = [], installedButton, messages = [], raf = [];
const listeners = {};
const document = {
  documentElement: {clientWidth: 390, clientHeight: 800},
  body: {appendChild(node) { installedButton = node; node.isConnected = true; }},
  querySelectorAll(selector) { assert.equal(selector, 'video'); return videos; },
  addEventListener(name, fn) { listeners['document:' + name] = fn; },
  createElement(tag) {
    assert.equal(tag, 'button');
    const properties = {};
    return {
      isConnected: false, properties,
      style: {setProperty(key, value, priority) { assert.equal(priority, 'important'); properties[key] = value; }},
      setAttribute(key, value) { this[key] = value; },
      addEventListener(name, fn) { this[name] = fn; }
    };
  }
};
const window = {
  innerWidth: 390, innerHeight: 800,
  webkit: {messageHandlers: {moodyvidVideoButton: {postMessage(msg) { messages.push(msg); }}}},
  getComputedStyle(v) { return v.style; },
  requestAnimationFrame(fn) { raf.push(fn); },
  addEventListener(name, fn) { listeners['window:' + name] = fn; },
  setInterval(fn) { listeners.timer = fn; }
};
class MutationObserver { constructor(fn) { listeners.mutation = fn; } observe() {} }
const context = vm.createContext({window, document, MutationObserver});
const source = fs.readFileSync('Resources/video-button.js', 'utf8')
  .replace('__MV_VIDEO_BUTTON_LABEL__', JSON.stringify('Download this video'));
function tick() { const callbacks = raf; raf = []; callbacks.forEach(fn => fn()); }
function video(left, top, right, bottom, extraStyle = {}) {
  return {getBoundingClientRect() { return {left, top, right, bottom}; },
    style: {display: 'block', visibility: 'visible', opacity: '1', ...extraStyle}};
}

vm.runInContext(source, context);
tick();
assert.equal(installedButton, undefined, 'no video must not create a button');
videos = [video(0, 0, 90, 50), video(0, 850, 390, 1100), video(0, 0, 390, 200, {display: 'none'})];
listeners.mutation(); tick();
assert.equal(installedButton, undefined, 'tiny, off-screen and hidden players are ignored');
videos = [video(-20, 100, 320, 300), video(0, 400, 150, 480)];
listeners.mutation(); tick();
assert.equal(installedButton['aria-label'], 'Download this video');
assert.equal(installedButton.properties.display, 'block');
assert.equal(installedButton.properties.left, '272px');
assert.equal(installedButton.properties.top, '108px');
const first = installedButton;
let prevented = false, stopped = false;
first.click({isTrusted: false, preventDefault() { prevented = true; }, stopPropagation() { stopped = true; }});
assert.equal(messages.length, 0, 'synthetic clicks cannot open native UI');
first.click({isTrusted: true, preventDefault() { prevented = true; }, stopPropagation() { stopped = true; }});
assert.equal(messages.length, 1);
assert.equal(messages[0].type, 'videoButton');
assert.ok(prevented && stopped);
vm.runInContext(source, context); // cannot install a second button in one frame
listeners['window:scroll'](); tick();
assert.equal(installedButton, first);
videos = [];
listeners.timer(); tick();
assert.equal(first.properties.display, 'none');
first.isConnected = false;
videos = [video(10, -50, 390, 150)];
listeners.timer(); tick();
assert.equal(installedButton, first, 'site removal recreates placement without a second handler');
assert.equal(first.properties.top, '8px');
console.log('video button tests passed');
