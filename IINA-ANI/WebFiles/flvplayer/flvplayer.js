$ = function(a) {
    return document.getElementById(a);
};
var isLiving = true;
var uuid = '';

var player;
var activePlayback = null;
var videoDuration;


function print(text) {
    window.webkit.messageHandlers.print.postMessage(text);
};

var playerLogListener = function(type, str) {
    print(str);
};

function playerDestroy() {
    // Invalidate callbacks before pause/unload can dispatch events from the old media.
    activePlayback = null;
    if (!player) return;
    player.pause();
    player.unload();
    player.detachMediaElement();
    player.destroy();
    player = null;
    mpegts.LoggingControl.removeLogListener(playerLogListener);

    document.getElementById('videoElement').replaceWith(document.getElementById('videoElement').cloneNode());
};

window.openUrl = function(url, live = true, startPosition = 0, generation = '') {
    if (player != null) {
        playerDestroy();
    };

	if (mpegts.isSupported()) {
        var videoElement = document.getElementById('videoElement');
        isLiving = live;
        const playback = { generation, failed: false, ended: false };
        activePlayback = playback;
        function isCurrentPlayback() {
            return activePlayback === playback;
        }
        let seekApplied = live || startPosition <= 0;
        let lastPosition = -1;
        function reportProgress(completed = false, flush = false) {
            if (!isCurrentPlayback() || live || !seekApplied || !Number.isFinite(videoElement.currentTime)) return;
            const position = videoElement.currentTime;
            if (!flush && !completed && Math.abs(position - lastPosition) < 1) return;
            lastPosition = position;
            window.webkit.messageHandlers.playbackProgress.postMessage({
                generation, position,
                duration: Number.isFinite(videoElement.duration) ? videoElement.duration : null,
                completed, flush
            });
        }
        function applyResume() {
            if (!isCurrentPlayback() || seekApplied || !Number.isFinite(videoElement.duration)) return;
            player.currentTime = Math.min(startPosition, Math.max(0, videoElement.duration - 0.01));
            seekApplied = true;
        }
        function reportError(data) {
            if (!isCurrentPlayback() || playback.failed) return;
            playback.failed = true;
            reportProgress(false, true);
            window.webkit.messageHandlers.error.postMessage({ generation, data });
        }
        videoElement.addEventListener('loadedmetadata', applyResume);
        videoElement.addEventListener('canplay', applyResume);
        videoElement.addEventListener('timeupdate', () => reportProgress());
        videoElement.addEventListener('pause', () => reportProgress(false, true));
        videoElement.addEventListener('seeked', () => reportProgress(false, true));
        videoElement.addEventListener('ended', () => {
            if (!isCurrentPlayback() || playback.failed || playback.ended ||
                !videoElement.ended || videoElement.error) return;
            playback.ended = true;
            reportProgress(true, true);
            window.webkit.messageHandlers.end.postMessage({ generation });
        });
        videoElement.addEventListener('error', () => reportError(videoElement.error ? videoElement.error.code : null));

        var mediaDataSource = {
            type: 'flv',
            isLive: live,
            hasAudio: true,
            hasVideo: true,
            withCredentials: false,
            url: url
        };

        player = mpegts.createPlayer(mediaDataSource, {
            enableWorker: true,
            enableWorkerForMSE: true,
            liveBufferLatencyChasing: live,
            liveBufferLatencyChasingOnPaused: live,
            liveBufferLatencyMaxLatency: 5.0,
            liveSync: live,
            lazyLoad: false,
            rangeLoadZeroStart: true,
        });

        mpegts.LoggingControl.addLogListener(playerLogListener);

        videoElement.addEventListener("loadeddata", function(e) {
            print("loadeddata");
            window.webkit.messageHandlers.size.postMessage([videoElement.videoWidth, videoElement.videoHeight]);
        });
        
        videoElement.addEventListener("resize", function(e) {
            window.webkit.messageHandlers.size.postMessage([videoElement.videoWidth, videoElement.videoHeight]);
        });

        videoElement.addEventListener("durationchange", function(e) {
            var d = parseInt(videoElement.duration, 10);
            if (videoDuration != d) {
                videoDuration = d;
                window.webkit.messageHandlers.duration.postMessage(d);
            };
        });



        player.on(mpegts.Events.ERROR, reportError);

        player.on(mpegts.Events.LOADING_COMPLETE, function(data) {
            if (!isCurrentPlayback()) return;
            // Download completion is not the media element's natural EOF.
            window.webkit.messageHandlers.loadingComplete.postMessage({ generation, data });
        });

        player.on(mpegts.Events.RECOVERED_EARLY_EOF, function(data) {
            window.webkit.messageHandlers.recoveredEarlyEof.postMessage(data);
        });

        player.on(mpegts.Events.MEDIA_INFO, function(data) {
            window.webkit.messageHandlers.mediaInfo.postMessage(data);
        });

        // player.on(mpegts.Events.METADATA_ARRIVED, function(data) {
        //     print(data);
        //     print('METADATA_ARRIVED');
        // });

        
        player.on(mpegts.Events.SCRIPTDATA_ARRIVED, function(data) {
            window.webkit.messageHandlers.metaData.postMessage(data.onMetaData);
        });

        // stuckChecker
        player.on(mpegts.Events.STATISTICS_INFO, function(data) {
            window.webkit.messageHandlers.stuckChecker.postMessage(data.decodedFrames);
        });

        player.on(mpegts.Events.DESTROYING, function(data) {
            print(data);
            print('DESTROYING');
        });
        player.attachMediaElement(videoElement);

        player.load();
        player.play();

    }
};

window.dmMessage = function(event) {    
    if (event.method != 'sendDM') {
        console.log(event.method, event.text);
    };
    
    switch(event.method) {
    case 'start':
        window.cm.start();
        break;
    case 'stop':
        window.cm.stop();
        window.cm.clear();
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
            loadDM('/danmaku/' + 'danmaku' + '-' + uuid + '.xml');
            
            console.log('/danmaku/' + 'danmaku' + '-' + uuid + '.xml');
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
    };
};

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
        resize();
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

function initContent(){
    bind();
    initDM();
    resize();
    // Block unknown types.
    // https://github.com/jabbany/CommentCoreLibrary/issues/97
    cm.filter.allowUnknownTypes = false;
    console.log('initContent');
}
