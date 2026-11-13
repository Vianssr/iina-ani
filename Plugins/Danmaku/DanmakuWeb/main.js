// Danmaku overlay (WKWebView) — bridges the IINA plugin and CommentCoreLibrary.

// ---- Globals & Helpers ----

$ = function(a) {
    return document.getElementById(a);
};

var baseWidth = 680;
var liveUrl;
var srcType;
var lastTime = 0;
var settingsController;
var ws;
var reconnectTimer;
var resizeTimer;
var socketLocation;
var socketIdentity;

function applySettings(settings) {
    if (!settingsController) {
        return;
    }
    settingsController.apply(settings);
    baseWidth = Number(settings.speed) || 680;
    window.cmResize();
    iina.postMessage("interactionChanged", { enabled: settings.hoverPause === true });
}

function closeSocket() {
    clearTimeout(reconnectTimer);
    reconnectTimer = undefined;
    socketLocation = undefined;
    socketIdentity = undefined;
    if (ws) {
        ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
        ws.close();
        ws = undefined;
    }
}

function disposeDanmaku() {
    clearTimeout(resizeTimer);
    resizeTimer = undefined;
    closeSocket();
    if (settingsController) {
        settingsController.dispose();
        settingsController = undefined;
    }
    if (window.cm) {
        window.cm.clear();
        window.cm.stop();
    }
    if (window._provider) {
        window._provider.destroy();
        window._provider = undefined;
    }
}

function hexToString(hex) {
    return decodeURIComponent('%' + hex.match(/.{1,2}/g).join('%'));
};

// ---- Danmaku play/visibility state ----
//
// Two independent truths decide whether danmaku should render:
//   wantPlaying — false while the video is paused (user intent)
//   hidden      — true while the window is occluded / in the background
// Rendering only happens when the video plays AND the window is visible.
//
// `hidden` is OR-merged from two sources that disagree during transitions:
// the IINA side (NSWindow.occlusionState) and the webview's own visibility
// API. OR semantics are deliberate — a stale "visible" from one source must
// never resume rendering while the other still reports hidden.

var wantPlaying = true;
var hiddenByIINA = false;
var hiddenByWebview = false;


// Last (hidden, wantPlaying) combination pushed to cm. The IINA side
// re-reports window state on every poll tick, so dedupe here rather than
// doing needless clear()/start() work twice a second.
var lastAppliedState = null;

// Reconcile cm with (wantPlaying, hidden):
//   hidden          — drop everything, nothing should linger on screen
//   visible, paused — keep on-screen danmaku frozen (normal pause look)
//   visible, playing— render
// Pending timers are dropped in both non-rendering cases, since they would
// otherwise all fire at once the moment rendering resumes.
function applyDanmakuState() {
    if (typeof window.cm === 'undefined' || !window.cm.setHidden) {
        return;
    }
    var hidden = hiddenByIINA || hiddenByWebview;
    var state = (hidden ? 'H' : 'V') + (wantPlaying ? 'P' : 'S');
    if (state === lastAppliedState) {
        return;
    }
    lastAppliedState = state;
    if (window.cm.isHidden() !== hidden) {
        window.cm.setHidden(hidden);
    }
    if (hidden) {
        window.cm.clear();
        window.cm.stop();
    } else if (wantPlaying) {
        window.cm.start();
    } else {
        window.cm.stop();
    }
}

// ---- iina Message Handlers ----

iina.onMessage("initDM", (opts) => {
    srcType = opts.type;
    disposeDanmaku();

    // Fresh file — drop leftover timers, reset per-file intent, and force a
    // re-apply since a new cm was just created. Visibility is tracked
    // per-window rather than per-file, so hiddenByIINA keeps its value (the
    // IINA side also re-reports it right after initDM to be safe).
    wantPlaying = true;
    hiddenByWebview = document.hidden;
    lastAppliedState = null;

    window.bind();
    window.initDM();
    settingsController = new DanmakuSettingsController(window.cm);
    applySettings(opts.settings);
    applyDanmakuState();

    switch(srcType) {
        case 0:
            liveUrl = opts.rawUrl;
            initWebsocket(opts.port, liveUrl);
            break;
        case 1:
            window.loadDM(hexToString(opts.xmlContent), 'iina-danmaku');
            initWebsocket(opts.port, 'settings');
            break;
        default:
            return;
    };


    resizeTimer = setTimeout(function () {
        resizeTimer = undefined;
        window.cmResize();
    }, 1000);
});

iina.onMessage("dmSettings", applySettings);

iina.onMessage("resizeWindow", () => {
    window.cmResize();
});

iina.onMessage("sendDM", (t) => {
    if (settingsController) {
        window.cm.send(settingsController.comment(t));
    }
});

iina.onMessage("timeChanged", (t) => {
    if (Math.abs(lastTime - t.time) > 5.5) {
        window.cm.clear();
    };
    lastTime = t.time;
    window.cm.time(Math.floor(t.time * 1000));
});

iina.onMessage("pauseChanged", (t) => {
    wantPlaying = !t.isPaused;
    applyDanmakuState();
});

iina.onMessage("setHidden", (t) => {
    var changed = hiddenByIINA !== t.hidden;
    hiddenByIINA = t.hidden;
    if (!t.hidden) {
        // The IINA side says the window is visible (authoritative, from
        // occlusionState). Drop our own flag too — the webview's
        // visibilitychange can fire in one direction only and latch us hidden.
        hiddenByWebview = false;
    }
    applyDanmakuState();
    if (changed) {
        console.log('setHidden:', t.hidden);
    }
});

iina.onMessage("close", () => {
    disposeDanmaku();
    liveUrl = undefined;
    srcType = undefined;
    updateStatus('');
});

// ---- CommentManager Setup ----

function bind() {
    window.cm = new CommentManager($('commentCanvas'));
    cm.init();
    window.cmResize = function () {
        var scale = $("player").offsetWidth / baseWidth;
        window.cm.options.scroll.scale = scale;
        cm.setBounds();
    };

    window.initDM = function() {
        if (window._provider && window._provider instanceof CommentProvider) {
            window._provider.destroy();
        }
        window._provider = new CommentProvider();
        cm.clear();
        window._provider.addTarget(cm);
        cmResize();
        cm.init();
        cm.start();
    };


    /** Load **/
    window.loadDM = function(dmf, provider) {
        if (window._provider && window._provider instanceof CommentProvider) {
            window._provider.destroy();
        }
        window._provider = new CommentProvider();
        cm.clear();
        window._provider.addTarget(cm);
        cmResize();
        switch (provider) {
            case "acfun":
                window._provider.addStaticSource(
                    CommentProvider.JSONProvider('GET', dmf),
                    CommentProvider.SOURCE_JSON).addParser(
                    new AcfunFormat.JSONParser(),
                    CommentProvider.SOURCE_JSON);
                break;
            case "cdf":
                window._provider.addStaticSource(
                    CommentProvider.JSONProvider('GET', dmf),
                    CommentProvider.SOURCE_JSON).addParser(
                    new CommonDanmakuFormat.JSONParser(),
                    CommentProvider.SOURCE_JSON);
                break;
            case "bilibili-text":
                window._provider.addStaticSource(
                    CommentProvider.TextProvider('GET', dmf),
                    CommentProvider.SOURCE_TEXT).addParser(
                    new BilibiliFormat.TextParser(),
                    CommentProvider.SOURCE_TEXT);
                break;
            case "iina-danmaku":
                window._provider.addStaticSource(
                    Promise.resolve(dmf),
                    CommentProvider.SOURCE_TEXT).addParser(
                    new BilibiliFormat.TextParser(),
                    CommentProvider.SOURCE_TEXT);
                break;
            case "bilibili":
            default:
                window._provider.addStaticSource(
                    CommentProvider.XMLProvider('GET', dmf),
                    CommentProvider.SOURCE_XML).addParser(
                    new BilibiliFormat.XMLParser(),
                    CommentProvider.SOURCE_XML);
                break;
        }
        var provider = window._provider;
        provider.start().then(function() {
            if (window._provider === provider) {
                lastAppliedState = null;
                applyDanmakuState();
            }
        }).catch(function(e) {
            if (window._provider === provider) {
                console.error('Unable to load danmaku:', e);
                updateStatus('error');
            }
        });
    };

    window.loadFilter = function(ff) {
        cm.filter.rules = [];
        CommentProvider.XMLProvider("GET", ff)
        .then(result => result.getElementsByTagName("item"))
        .then(items => [...items].map(r => r.textContent).filter(r => r.startsWith('r=')).map(r => r.replace('r=', '')))
        .then(function(values) {
            values.forEach(v =>
                cm.filter.addRule({
                    "subject": "text",
                    "op": "~",
                    "value": v,
                    "mode": "reject"
                })
            )
        });
    };
};

// ---- Status Indicator ----

function updateStatus(status){
    switch(status) {
    case 'warning':
        document.getElementById("status").style.backgroundColor="#FFB742"
        break
    case 'error':
        document.getElementById("status").style.backgroundColor="#FF2640"
        break
    default:
        document.getElementById("status").style.backgroundColor=""
        break
    }
}

// ---- App-managed settings and live danmaku WebSocket ----

function start(websocketServerLocation, identity) {
    if (socketLocation !== websocketServerLocation || socketIdentity !== identity) {
        return;
    }
    var socket = new WebSocket(websocketServerLocation);
    ws = socket;
    updateStatus('warning');
    socket.onopen = function() {
        if (ws !== socket) {
            return;
        }
        updateStatus();
        socket.send('iinaDM://v=2&' + identity);
    };
    socket.onmessage = function(evt) {
        if (ws !== socket) {
            return;
        }
        var message;
        try {
            message = JSON.parse(evt.data);
            if (message.method === 'dmSettings') {
                applySettings(JSON.parse(message.text));
                return;
            }
        } catch (error) {
            console.error('Invalid danmaku message:', error);
            return;
        }
        if (message.method !== 'sendDM' || srcType !== 0 ||
                !wantPlaying || hiddenByIINA || hiddenByWebview) {
            return;
        }
        settingsController.send(message.dms || []);
    };
    socket.onclose = function() {
        if (ws !== socket || socketLocation !== websocketServerLocation ||
                socketIdentity !== identity) {
            return;
        }
        ws = undefined;
        updateStatus('warning');
        reconnectTimer = setTimeout(function() {
            reconnectTimer = undefined;
            start(websocketServerLocation, identity);
        }, 1500);
    };
    socket.onerror = function() {
        updateStatus('error');
    };
}

function initWebsocket(port, identity) {
    // Standalone XML keeps plugin preferences and must not connect to the App.
    if (!Number.isInteger(Number(port)) || Number(port) < 1 || Number(port) > 65535) {
        return;
    }
    socketLocation = 'ws://127.0.0.1:' + Number(port) + '/danmaku-websocket';
    socketIdentity = identity;
    start(socketLocation, socketIdentity);
}

window.addEventListener("pagehide", disposeDanmaku);

// Visibility — WKWebView's own signal (fast path for occlusion/changes).
// IINA side's window-main.changed provides the cross-check via occlusionState.

document.addEventListener("visibilitychange", () => {
    hiddenByWebview = document.hidden;
    applyDanmakuState();
    console.log('visibilitychange: hidden=' + document.hidden);
});
