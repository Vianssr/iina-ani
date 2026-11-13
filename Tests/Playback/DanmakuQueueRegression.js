'use strict';

// Exercise delivery latency and lifecycle through the shipped settings controller.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../IINA-ANI/WebFiles/Danmaku/danmaku-settings.js'), 'utf8');

function fixture() {
    let now = 0;
    let nextID = 0;
    const timers = new Map();
    const received = [];
    const documentListeners = new Map();
    const document = {
        visibilityState: 'visible',
        addEventListener(name, handler) { documentListeners.set(name, handler); },
        removeEventListener(name) { documentListeners.delete(name); }
    };
    const context = vm.createContext({
        document,
        performance: { now: () => now },
        setTimeout(handler, delay) {
            const id = ++nextID;
            timers.set(id, { due: now + delay, handler });
            return id;
        },
        clearTimeout(id) { timers.delete(id); }
    });
    context.window = context;
    vm.runInContext(source, context);
    const cm = {
        _accepting: true, _hidden: false, _listeners: {}, runline: [],
        stage: { style: {}, offsetWidth: 960 },
        options: { global: {}, scroll: {} },
        factory: { create() { throw new Error('Queue tests do not create DOM comments'); } },
        validate() { return true; }, _preprocess(data) { return data; },
        addEventListener(name, handler) { (this._listeners[name] ||= []).push(handler); },
        start() { this._accepting = true; },
        stop() { this._accepting = false; },
        clear() {},
        setHidden(hidden) { this._hidden = hidden; },
        send(comment) { received.push({ text: comment.text, at: now }); }
    };
    const controller = new context.DanmakuSettingsController(cm);
    function advance(target, stalled = false) {
        if (stalled) now = target;
        for (;;) {
            const next = [...timers].filter(([, timer]) => timer.due <= target)
                .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
            if (!next) break;
            if (!stalled) now = next[1].due;
            timers.delete(next[0]);
            next[1].handler();
        }
        now = target;
    }
    return { controller, cm, timers, received, advance, hideDocument() {
        document.visibilityState = 'hidden';
        documentListeners.get('visibilitychange')();
    } };
}

const busy = fixture();
const arrival = new Map();
for (let time = 0; time < 60000; time += 500) {
    busy.advance(time);
    const batch = Array.from({ length: 10 }, (_, index) => ({ text: `${time}:${index}` }));
    for (const comment of batch) arrival.set(comment.text, time);
    busy.controller.send(batch);
}
busy.advance(62000);
assert.equal(busy.received.length, arrival.size, 'ordinary overlapping batches must not lose comments');
assert.equal(new Set(busy.received.map(comment => comment.text)).size, arrival.size, 'comments must be delivered once');
assert.ok(busy.received.every(comment => comment.at - arrival.get(comment.text) <= 2000),
    'sustained batches must remain near-live instead of accumulating FIFO delay');
assert.ok(busy.received.findIndex(comment => comment.text === '500:0') <
    busy.received.findIndex(comment => comment.text === '0:9'), 'new batches must not wait for older batches to finish');
busy.controller.dispose();

const burst = fixture();
burst.controller.send(Array.from({ length: 100000 }, (_, index) => ({ text: `old:${index}` })));
assert.ok(burst.timers.size <= 200, 'a single oversized batch must not allocate unbounded pending timers');
burst.controller.send([{ text: 'latest' }]);
assert.ok(burst.timers.size <= 200, 'overlapping batches must share the pending-work bound');
burst.advance(0);
assert.ok(burst.received.some(comment => comment.text === 'latest'), 'new chat must not wait behind an oversized burst');
burst.advance(2000);
assert.ok(!burst.received.some(comment => comment.text === 'old:0'), 'overload drops old messages rather than retaining stale backlog');
burst.controller.dispose();

const stalled = fixture();
stalled.controller.send([{ text: 'expired' }, { text: 'also expired' }]);
stalled.advance(5000, true);
assert.deepEqual(stalled.received, [], 'a suspended event loop must not replay expired live comments');
stalled.controller.send([{ text: 'fresh' }]);
stalled.advance(5000);
assert.deepEqual(stalled.received.map(comment => comment.text), ['fresh']);
stalled.controller.dispose();

for (const stop of [f => f.cm.stop(), f => f.cm.clear(), f => f.cm.setHidden(true),
    f => f.hideDocument(), f => f.controller.dispose()]) {
    const f = fixture();
    f.controller.send([{ text: 'before' }, { text: 'cancelled' }]);
    f.advance(0);
    stop(f);
    f.advance(5000);
    assert.deepEqual(f.received.map(comment => comment.text), ['before'], 'teardown/hiding must cancel pending delivery');
    assert.equal(f.timers.size, 0, 'teardown/hiding must release timers');
    f.controller.dispose();
}
console.log('PASS: bounded near-live batch delivery, overload freshness, stalled-view expiry and lifecycle cancellation');
