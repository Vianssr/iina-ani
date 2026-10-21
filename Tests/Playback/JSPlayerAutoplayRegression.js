'use strict';

// Exercises the shipped bridge without fetching media or starting an App window.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const messages = [];
const players = [];
let video;
function makeVideo() {
    const listeners = new Map();
    return {
        currentTime: 12, duration: 30, ended: false, error: null,
        addEventListener(name, callback) {
            if (!listeners.has(name)) listeners.set(name, []);
            listeners.get(name).push(callback);
        },
        dispatch(name) {
            for (const callback of listeners.get(name) || []) callback({});
        },
        cloneNode() { return makeVideo(); },
        replaceWith(replacement) { video = replacement; }
    };
}
video = makeVideo();
const events = Object.fromEntries([
    'ERROR', 'LOADING_COMPLETE', 'RECOVERED_EARLY_EOF', 'MEDIA_INFO',
    'SCRIPTDATA_ARRIVED', 'STATISTICS_INFO', 'DESTROYING'
].map(name => [name, name]));
const context = vm.createContext({
    console,
    document: { getElementById: () => video },
    mpegts: {
        isSupported: () => true,
        Events: events,
        LoggingControl: { addLogListener() {}, removeLogListener() {} },
        createPlayer() {
            const callbacks = new Map();
            const instance = {
                on(name, callback) {
                    assert.notEqual(name, undefined, 'bridge must register real MPEGTS event constants');
                    callbacks.set(name, callback);
                },
                emit(name, data = {}) { callbacks.get(name)?.(data); },
                attachMediaElement(element) { this.element = element; },
                load() {}, play() {}, unload() {}, detachMediaElement() {},
                pause() { this.element.dispatch('pause'); },
                destroy() {
                    // Teardown is allowed to synchronously dispatch stale media callbacks.
                    this.element.ended = true;
                    this.element.dispatch('ended');
                }
            };
            players.push(instance);
            return instance;
        }
    }
});
context.window = context;
context.webkit = { messageHandlers: new Proxy({}, {
    get: (_, name) => ({ postMessage: body => messages.push({ name, body }) })
}) };
vm.runInContext(fs.readFileSync(path.join(__dirname, '../../IINA-ANI/WebFiles/flvplayer/flvplayer.js'), 'utf8'), context);
const count = name => messages.filter(message => message.name === name).length;
function open(generation, live = false) {
    context.openUrl('https://media.invalid/video.flv', live, 0, generation);
    return { video, player: players.at(-1) };
}
function end(element) {
    element.ended = true;
    element.dispatch('ended');
}

const first = open('first');
first.player.emit(events.LOADING_COMPLETE);
assert.equal(count('end'), 0, 'buffering EOF must not advance an episode');
assert.equal(messages.at(-1).body.generation, 'first');
first.video.dispatch('pause');
first.video.dispatch('seeked');
assert.equal(count('end'), 0, 'pause/seek must not advance an episode');
first.video.dispatch('ended');
assert.equal(count('end'), 0, 'synthetic ended without actual media EOF must be ignored');
end(first.video);
end(first.video);
assert.equal(count('end'), 1, 'natural EOF must be delivered once');
assert.equal(messages.at(-1).body.generation, 'first');
assert.equal(messages.at(-2).name, 'playbackProgress');
assert.equal(messages.at(-2).body.completed, true, 'history completion precedes next selection');

const second = open('second');
const afterReplacement = messages.length;
end(first.video);
first.video.dispatch('timeupdate');
first.player.emit(events.ERROR, 'stale error');
first.player.emit(events.LOADING_COMPLETE);
assert.equal(messages.length, afterReplacement, 'old playback callbacks must not inherit the new generation');
second.player.emit(events.ERROR, 'network failure');
assert.equal(messages.at(-1).name, 'error');
assert.equal(messages.at(-1).body.generation, 'second');
end(second.video);
assert.equal(count('end'), 1, 'MPEGTS errors must disarm natural EOF');

const third = open('third');
third.video.error = { code: 3 };
third.video.dispatch('error');
end(third.video);
assert.equal(count('end'), 1, 'native decode errors must not advance an episode');
assert.equal(messages.at(-1).body.generation, 'third');

const fourth = open('fourth');
context.playerDestroy();
end(fourth.video);
assert.equal(count('end'), 1, 'manual destruction and detached media cannot advance an episode');

const live = open('live', true);
const progressBeforeLiveEnd = count('playbackProgress');
end(live.video);
assert.equal(messages.at(-1).name, 'end', 'live EOF retains the existing native reconnect route');
assert.equal(messages.at(-1).body.generation, 'live');
assert.equal(count('playbackProgress'), progressBeforeLiveEnd, 'live EOF must not create VOD completion history');
console.log('PASS: JSPlayer natural EOF, generation identity, buffering/pause/seek, errors, teardown and live lifecycle');
