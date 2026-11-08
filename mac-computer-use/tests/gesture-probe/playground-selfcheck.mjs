import fs from 'node:fs'
import vm from 'node:vm'
import assert from 'node:assert/strict'
const html = fs.readFileSync(new URL('playground.html', import.meta.url), 'utf8')
const context = {}
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context)
const fit = context.fitGesture
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-8, a + ' != ' + b)
let result = fit([{id: 1, x: 0, y: 0}], [{id: 1, x: 30, y: -20}])
near(result.x, 30); near(result.y, -20); near(result.scale, 1); near(result.angle, 0)
result = fit([{id: 1, x: -1, y: 0}, {id: 2, x: 1, y: 0}], [{id: 1, x: 10, y: 18}, {id: 2, x: 10, y: 22}])
near(result.x, 10); near(result.y, 20); near(result.scale, 2); near(result.angle, Math.PI / 2)
result = fit([{id: 1, x: 0, y: 0}, {id: 2, x: 2, y: 0}, {id: 3, x: 0, y: 2}], [{id: 3, x: 4, y: 10}, {id: 1, x: 4, y: 6}, {id: 2, x: 8, y: 6}])
near(result.scale, 2); near(result.angle, 0)
result = fit([{id: 1, x: 0, y: 0}, {id: 2, x: 2, y: 0}], [{id: 2, x: 8, y: 4}])
near(result.x, 6); near(result.y, 4); near(result.scale, 1)
let now = 0
const elements = new Map()
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    style: {setProperty() {}}, classList: {add() {}, remove() {}, toggle() {}},
    listeners: {}, addEventListener(type, fn) { this.listeners[type] = fn },
    setPointerCapture() {}, setAttribute() {}, closest() { return null },
    getBoundingClientRect() { return {left: 0, top: 0, width: 400, height: 400} }
  })
  return elements.get(id)
}
const ui = {
  document: {getElementById: element, querySelectorAll: () => [], addEventListener() {}},
  performance: {now: () => now}, requestAnimationFrame: fn => fn(),
  setTimeout: () => 1, clearTimeout() {}, addEventListener() {}
}
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], ui)
function input(type, id, x, y, target = element('stage')) {
  now += 10
  element('stage').listeners[type]({pointerId: id, clientX: x, clientY: y, pointerType: 'touch', isTrusted: true, target, preventDefault() {}})
}
input('pointerdown', 1, 100, 100); input('pointerdown', 2, 200, 100)
input('pointercancel', 1, 100, 100); input('pointerup', 2, 200, 100)
assert.equal(ui.probeState.active, 0)
assert.equal(ui.probeState.sessions.at(-1).cancelled, true)
assert.equal(ui.probeState.sessions.at(-1).taps, 0)
ui.resetProbe()
input('pointerdown', 1, 100, 100); input('pointerup', 1, 100, 100)
input('pointerdown', 1, 350, 300); input('pointerup', 1, 350, 300)
assert.equal(ui.probeState.sessions.at(-1).taps, 1)
input('pointerdown', 1, 350, 300); input('pointerup', 1, 350, 300)
assert.equal(ui.probeState.sessions.at(-1).taps, 2)
ui.resetProbe()
const handle = {closest: selector => selector === '[data-handle]' ? {dataset: {handle: 'rotate'}} : null}
input('pointerdown', 1, 200, 80, handle); input('pointerup', 1, 200, 80, handle)
assert.equal(ui.probeState.selected, true)
console.log('Web playground checks passed: transforms, independent lift, partial cancellation, spatial taps and handle selection.')
