$ = function(a) {
    return document.getElementById(a);
};
var isLiving = true;
var uuid = '';

function bind() {
    if (window.dmSettings) window.dmSettings.dispose();
    if (window.cm) window.cm.destroy();
    if (window.dmVisibilityListener) {
        document.removeEventListener('visibilitychange', window.dmVisibilityListener);
    }
    window.cm = new CommentManager($('commentCanvas'));
    cm.init();
    window.dmSettings = new DanmakuSettingsController(cm);
    window.resize = function () {
        cm.setBounds();
    };

    window.dmVisibilityListener = function () {
        cm.setHidden(document.visibilityState !== 'visible');
    };
    document.addEventListener('visibilitychange', window.dmVisibilityListener);

    window.initDM = function() {
        if (window._provider && window._provider instanceof CommentProvider) {
            window._provider.destroy();
        }
        window._provider = new CommentProvider();
        cm.clear();
        window._provider.addTarget(cm);
        resize();
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
        resize();
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
            case "bilibili":
            default:
                window._provider.addStaticSource(
                    CommentProvider.XMLProvider('GET', dmf),
                    CommentProvider.SOURCE_XML).addParser(
                    new BilibiliFormat.XMLParser(),
                    CommentProvider.SOURCE_XML);
                break;
        }
        window._provider.start().then(function() {
            cm.start();
        }).catch(function(e) {
            alert(e);
        });
    };

    window.loadFilter = function(ff) {
        var version = window._filterVersion = (window._filterVersion || 0) + 1;
        cm.filter.rules = [];
        CommentProvider.XMLProvider("GET", ff)
        .then(result => result.getElementsByTagName("item"))
        .then(items => [...items].map(r => r.textContent).filter(r => r.startsWith('r=')).map(r => r.replace('r=', '')))
        .then(function(values) {
            if (version !== window._filterVersion) return;
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

function start(websocketServerLocation){
    ws = new WebSocket(websocketServerLocation);
    updateStatus('warning');
    ws.onopen = function(evt) {
        if (isLiving) {
            updateStatus();
            ws.send("iinaWebDM://" + uuid);
        };
    };
    ws.onmessage = function(evt) { 
        var event = JSON.parse(evt.data);
        
        if (event.method != 'sendDM') {
            console.log(event.method, event.text);
        }
        
        switch(event.method) {
        case 'start':
            window.cm.start();
            break;
        case 'stop':
            window.cm.stop();
            break;
        case 'initDM':
            window.initDM();
            break;
        case 'resize':
            window.resize();
            break;
        case 'loadDM':
            if (event.text == 'acfun') {
                loadDM('/danmaku/iina-plus-danmaku.json', 'acfun');
            } else {
                loadDM('/danmaku/' + 'danmaku' + '-' + event.text + '.xml');
                
                console.log('/danmaku/' + 'danmaku' + '-' + event.text + '.xml');
            }
            isLiving = false;
            break;
        case 'sendDM':
            window.dmSettings.send(event.dms);
            break;
        case 'liveDMServer':
            updateStatus(event.text);
            break
        case 'dmSettings':
            window.dmSettings.apply(JSON.parse(event.text));
            if (window.dmSettings.settings.blockTypes.includes('List')) {
                window.loadFilter('/danmaku/iina-plus-blockList.xml');
            } else {
                window._filterVersion = (window._filterVersion || 0) + 1;
                cm.filter.rules = [];
            }
            break;
        default:
            break;
        }

    };
    ws.onclose = function(){
        if (isLiving) {
            updateStatus('warning');
            // Try to reconnect in 1 seconds
            setTimeout(function(){start(websocketServerLocation)}, 1000);
        }
    };
}

function initContent(id, port){
    bind();
    initDM();
    resize();
    uuid = id;
    if (port === undefined){
        port = 19080;
    }
    start('ws://127.0.0.1:' + port + '/danmaku-websocket');
    // Block unknown types.
    // https://github.com/jabbany/CommentCoreLibrary/issues/97
    cm.filter.allowUnknownTypes = false;
    console.log('initContent', id);
}
