/* Shared by the built-in players and the IINA overlay. No injected stylesheet. */
(function (global) {
    'use strict';

    function number(value, fallback, min, max) {
        return typeof value === 'number' && Number.isFinite(value)
            ? Math.max(min, Math.min(max, value)) : fallback;
    }

    function fontWeight(value) {
        var weights = {
            ultralight: '100', thin: '100', extralight: '200', light: '300',
            regular: '400', normal: '400', medium: '500', semibold: '600',
            demibold: '600', bold: '700', extrabold: '800', heavy: '900', black: '900'
        };
        var normalized = value.toLowerCase().replace(/[\s-]/g, '');
        return weights[normalized] || (/^[1-9]00$/.test(normalized) ? normalized : '400');
    }

    function DanmakuSettingsController(cm, options) {
        if (cm.danmakuSettingsController) cm.danmakuSettingsController.dispose();
        this.cm = cm;
        this.options = options || {};
        this.settings = {
            fontFamily: '', fontWeight: 'normal', fontSize: 24, speed: 680,
            opacity: 1, useSourceColor: true, blockTypes: [], hoverPause: true
        };
        this.records = new Map();
        this.hoverCount = 0;
        this.disposed = false;
        this.pending = new Set();
        this.stagePointerEvents = cm.stage.style.pointerEvents;
        cm.stage.style.pointerEvents = 'none';
        cm.danmakuSettingsController = this;
        var self = this;
        this.preprocess = cm._preprocess;
        this.preprocessWrapper = function (data) {
            if (!cm.validate(data)) return null;
            // Live send() bypasses CCL validation; filter before mode 8 scripting too.
            if (self.isBlocked({ comment: data, color: data.color === undefined ? 0xffffff : data.color })) {
                return null;
            }
            return self.preprocess.call(this, data);
        };
        cm._preprocess = this.preprocessWrapper;
        this.factory = cm.factory;
        this.create = this.factory.create;
        this.createWrapper = function (manager, data) {
            var comment = self.create.call(this, manager, data);
            if (manager === cm) self.attach(comment, data);
            return comment;
        };
        this.factory.create = this.createWrapper;
        this.start = cm.start;
        this.startWrapper = function () {
            if (this._hidden) {
                this._userPaused = false;
                return;
            }
            var result = self.start.apply(this, arguments);
            // CCL start() resumes every CSS animation; keep hovered instances paused.
            self.records.forEach(function (record) {
                if (record.hovered) record.comment.stop();
            });
            return result;
        };
        cm.start = this.startWrapper;
        this.stop = cm.stop;
        this.clear = cm.clear;
        this.stopWrapper = function () {
            self.cancelPending();
            return self.stop.apply(this, arguments);
        };
        this.clearWrapper = function () {
            self.cancelPending();
            return self.clear.apply(this, arguments);
        };
        cm.stop = this.stopWrapper;
        cm.clear = this.clearWrapper;
        this.setHidden = cm.setHidden;
        this.setHiddenWrapper = function (hidden) {
            var result = self.setHidden.call(this, hidden);
            if (hidden) {
                self.cancelPending();
                self.records.forEach(function (record) { self.setHovered(record, false); });
            }
            return result;
        };
        cm.setHidden = this.setHiddenWrapper;
        this.visibilityListener = function () {
            if (document.visibilityState !== 'visible') self.cancelPending();
        };
        document.addEventListener('visibilitychange', this.visibilityListener);
        this.listeners = {
            enterComment: function (comment) { self.attach(comment); },
            exitComment: function (comment) { self.detach(comment); },
            resize: function () { self.refresh(); }
        };
        Object.keys(this.listeners).forEach(function (event) {
            cm.addEventListener(event, self.listeners[event]);
        });
        cm.runline.forEach(function (comment) { self.attach(comment); });
        this.refresh();
    }

    DanmakuSettingsController.prototype.comment = function (element) {
        var comment = { text: element.text, stime: 0, mode: 1, color: 0xffffff, border: false };
        if (Number.isInteger(element.mode)) comment.mode = element.mode;
        if (Number.isInteger(element.color) && element.color >= 0 && element.color <= 0xffffff) {
            comment.color = element.color;
        }
        if (typeof element.fontSize === 'number' && element.fontSize > 0) comment.size = element.fontSize;
        ['imageSrc', 'imageWidth', 'content'].forEach(function (key) {
            if (element[key] !== undefined) comment[key] = element[key];
        });
        return comment;
    };
    DanmakuSettingsController.prototype.cancelPending = function () {
        this.pending.forEach(function (timer) { clearTimeout(timer); });
        this.pending.clear();
    };

    DanmakuSettingsController.prototype.send = function (elements) {
        if (this.disposed || !this.cm._accepting || this.cm._hidden ||
            document.visibilityState !== 'visible') return;
        // Each batch has its own pacing; a busy room must not serialize all
        // batches behind a 150 ms FIFO. Keep at most 200 pending comments and
        // spread even a large burst over at most 1.5 seconds.
        var maximumPending = 200;
        var start = Math.max(0, elements.length - maximumPending);
        var count = elements.length - start;
        var spacing = count > 1 ? Math.min(150, 1500 / (count - 1)) : 0;
        var receivedAt = performance.now();
        var self = this;
        function schedule(element, delay) {
            if (self.pending.size >= maximumPending) {
                var oldest = self.pending.values().next().value;
                clearTimeout(oldest);
                self.pending.delete(oldest);
            }
            var timer = setTimeout(function () {
                if (!self.pending.delete(timer)) return;
                if (self.disposed || !self.cm._accepting || self.cm._hidden ||
                    document.visibilityState !== 'visible') {
                    self.cancelPending();
                    return;
                }
                // Timers delayed by a suspended view must not replay stale live chat.
                if (performance.now() - receivedAt > 2000) return;
                self.cm.send(self.comment(element));
            }, delay);
            self.pending.add(timer);
        }
        for (var index = start; index < elements.length; index++) {
            schedule(elements[index], (index - start) * spacing);
        }
    };


    DanmakuSettingsController.prototype.apply = function (settings) {
        if (this.disposed || !settings || typeof settings !== 'object') return;
        var old = this.settings;
        this.settings = {
            fontFamily: typeof settings.fontFamily === 'string' ? settings.fontFamily : old.fontFamily,
            fontWeight: typeof settings.fontWeight === 'string' ? settings.fontWeight : old.fontWeight,
            fontSize: Math.round(number(settings.fontSize, old.fontSize, 12, 72)),
            speed: number(settings.speed, old.speed, 100, 2000),
            opacity: number(settings.opacity, old.opacity, 0, 1),
            useSourceColor: typeof settings.useSourceColor === 'boolean' ? settings.useSourceColor : old.useSourceColor,
            blockTypes: Array.isArray(settings.blockTypes) ? settings.blockTypes.slice() : old.blockTypes,
            hoverPause: typeof settings.hoverPause === 'boolean' ? settings.hoverPause : old.hoverPause
        };
        this.refresh();
    };

    DanmakuSettingsController.prototype.isBlocked = function (record) {
        var types = this.settings.blockTypes;
        var mode = record.comment.mode;
        return (types.indexOf('Scroll') !== -1 && [1, 2, 6].indexOf(mode) !== -1) ||
            (types.indexOf('Top') !== -1 && mode === 5) ||
            (types.indexOf('Bottom') !== -1 && mode === 4) ||
            (types.indexOf('Advanced') !== -1 && [7, 8, 17].indexOf(mode) !== -1) ||
            (types.indexOf('Color') !== -1 && record.color !== 0xffffff);
    };

    DanmakuSettingsController.prototype.setHovered = function (record, hovered) {
        if (record.hovered === hovered) return;
        record.hovered = hovered;
        var wasActive = this.hoverCount > 0;
        this.hoverCount += hovered ? 1 : -1;
        if (hovered) {
            record.comment.stop();
        } else if (record.comment.dom && this.cm._accepting && !this.cm._hidden) {
            record.comment.dom.style.animationPlayState = 'running';
        }
        if (wasActive !== (this.hoverCount > 0) && this.options.onHoverChange) {
            this.options.onHoverChange(this.hoverCount > 0);
        }
    };

    DanmakuSettingsController.prototype.attach = function (comment, data) {
        if (this.records.has(comment) || !comment.dom) return;
        var self = this;
        var record = {
            comment: comment, color: comment.color, size: (data && data.size) || comment.size || 25,
            time: comment.time, startAnimation: comment._startCssAnimation,
            hovered: false, scale: this.cm.options.scroll.scale,
            pointerEvents: comment.dom.style.pointerEvents,
            clickable: comment.dom.getAttribute('data-clickable')
        };
        // IINA hit-tests only the exact element, not its ancestors.
        record.children = Array.prototype.map.call(comment.dom.querySelectorAll('*'), function (element) {
            var saved = { element: element, pointerEvents: element.style.pointerEvents };
            element.style.pointerEvents = 'none';
            return saved;
        });
        this.records.set(comment, record);
        comment.time = function (elapsed) {
            if (!record.hovered) record.time.call(this, elapsed);
        };
        if (record.startAnimation) {
            comment._startCssAnimation = function () {
                record.startAnimation.call(this);
                // CCL restarts a full-width animation on invalidate(). Start from the
                // current TTL position and travel only the remaining distance instead.
                this.x = this.x;
                var distance = (this.parent.width + this.width) * this.ttl / this.dur;
                this.dom.style.setProperty('--ccl-scroll-distance',
                    (this.axis % 2 === 0 ? -distance : distance) + 'px');
                if (record.hovered || !self.cm._accepting || self.cm._hidden) this.stop();
            };
        }
        record.enter = function () {
            if (self.settings.hoverPause && !self.isBlocked(record)) self.setHovered(record, true);
        };
        record.leave = function () { self.setHovered(record, false); };
        comment.dom.addEventListener('mouseenter', record.enter);
        comment.dom.addEventListener('mouseleave', record.leave);
        this.update(record);
    };

    DanmakuSettingsController.prototype.update = function (record) {
        var comment = record.comment;
        var settings = this.settings;
        var scrolling = [1, 2, 6].indexOf(comment.mode) !== -1;
        var scale = this.cm.options.scroll.scale;
        if (scrolling && record.scale > 0 && record.scale !== scale) {
            var ratio = scale / record.scale;
            comment.dur *= ratio;
            comment.ttl *= ratio;
        }
        record.scale = scale;
        // Preserve source-relative sizes (CCL/Bilibili normal size is 25).
        comment.size = Math.max(1, record.size * settings.fontSize / 25);
        comment.font = settings.fontFamily;
        comment.dom.style.fontWeight = fontWeight(settings.fontWeight);
        comment.color = settings.useSourceColor ? record.color : 0xffffff;
        comment.dom.classList.toggle('reverse-shadow', comment.color === 0);
        comment.alpha = comment._alpha;
        var blocked = this.isBlocked(record);
        // Hide rather than destroy active instances so toggling a filter is reversible.
        comment.dom.style.visibility = blocked ? 'hidden' : '';
        var interactive = settings.hoverPause && !blocked;
        comment.dom.style.pointerEvents = interactive ? 'auto' : 'none';
        if (interactive) comment.dom.setAttribute('data-clickable', 'true');
        else comment.dom.removeAttribute('data-clickable');
        if (!interactive) this.setHovered(record, false);
        var y = comment.y;
        comment.invalidate();
        comment.y = y;
        if (comment.mode === 4 || comment.mode === 5) {
            comment.x = (this.cm.width - comment.width) / 2;
        }
        if (record.hovered || !this.cm._accepting || this.cm._hidden) comment.stop();
    };

    DanmakuSettingsController.prototype.refresh = function () {
        if (this.disposed) return;
        this.cm.options.global.opacity = this.settings.opacity;
        this.cm.options.scroll.scale = Math.max(1, this.cm.stage.offsetWidth) / this.settings.speed;
        var self = this;
        this.records.forEach(function (record) { self.update(record); });
    };

    DanmakuSettingsController.prototype.detach = function (comment) {
        var record = this.records.get(comment);
        if (!record) return;
        this.setHovered(record, false);
        comment.time = record.time;
        if (record.startAnimation) comment._startCssAnimation = record.startAnimation;
        comment.dom.removeEventListener('mouseenter', record.enter);
        comment.dom.removeEventListener('mouseleave', record.leave);
        comment.dom.style.pointerEvents = record.pointerEvents;
        record.children.forEach(function (child) {
            child.element.style.pointerEvents = child.pointerEvents;
        });
        if (record.clickable === null) comment.dom.removeAttribute('data-clickable');
        else comment.dom.setAttribute('data-clickable', record.clickable);
        comment.color = record.color;
        comment.size = record.size;
        this.records.delete(comment);
    };

    DanmakuSettingsController.prototype.dispose = function () {
        if (this.disposed) return;
        this.disposed = true;
        this.cancelPending();
        document.removeEventListener('visibilitychange', this.visibilityListener);
        var self = this;
        this.records.forEach(function (record) { self.detach(record.comment); });
        // This CCL version exposes addEventListener but no removeEventListener.
        Object.keys(this.listeners).forEach(function (event) {
            var listeners = self.cm._listeners[event];
            var index = listeners ? listeners.indexOf(self.listeners[event]) : -1;
            if (index !== -1) listeners.splice(index, 1);
        });
        if (this.factory.create === this.createWrapper) this.factory.create = this.create;
        if (this.cm.start === this.startWrapper) this.cm.start = this.start;
        if (this.cm.stop === this.stopWrapper) this.cm.stop = this.stop;
        if (this.cm.clear === this.clearWrapper) this.cm.clear = this.clear;
        if (this.cm.setHidden === this.setHiddenWrapper) this.cm.setHidden = this.setHidden;
        if (this.cm._preprocess === this.preprocessWrapper) this.cm._preprocess = this.preprocess;
        this.cm.stage.style.pointerEvents = this.stagePointerEvents;
        if (this.cm.danmakuSettingsController === this) delete this.cm.danmakuSettingsController;
    };

    global.DanmakuSettingsController = DanmakuSettingsController;
})(window);
