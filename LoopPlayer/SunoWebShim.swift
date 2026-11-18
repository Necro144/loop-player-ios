import Foundation

/// The page script from Suno Legacy (same author), used by Loop Player's Suno tab.
enum SunoWebShim {
    /// Safari on a Mac. Suno's phone site refuses to play songs in a browser, but its computer site plays them
    /// (checked in the simulator), and the page still lays itself out for the phone's screen width.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Safari/605.1.15"
    /// Safari on this iPhone, as it really is.
    static let phoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4.1 Mobile/15E148 Safari/604.1"

    static var userAgent: String {
        let desktop = UserDefaults.standard.object(forKey: "sunoTabDesktop") as? Bool ?? true
        return desktop ? desktopUserAgent : phoneUserAgent
    }

    /// Runs on every page before the site's own code: fills in newer JavaScript features,
    /// paints the page black, hides "out of date" notices, and reports errors to the app.
    static var script: String {
        let css = "html, body { background: #000 !important; }"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: " ")
        // TEST_NOHIDE is only used by the automated simulator test.
        let noHide = ProcessInfo.processInfo.environment["TEST_NOHIDE"] != nil ? "window.__noHide = true;" : ""
        return noHide + #"""
        (function () {
          function post(msg) {
            try { window.webkit.messageHandlers.jsError.postMessage(String(msg)); } catch (e) {}
          }
          try {
            if (!Promise.withResolvers) {
              Promise.withResolvers = function () {
                var resolve, reject;
                var promise = new Promise(function (a, b) { resolve = a; reject = b; });
                return { promise: promise, resolve: resolve, reject: reject };
              };
            }
            if (!Object.groupBy) {
              Object.groupBy = function (items, fn) {
                var out = Object.create(null), i = 0;
                for (var x of items) { var k = fn(x, i++); (out[k] || (out[k] = [])).push(x); }
                return out;
              };
            }
            if (!Map.groupBy) {
              Map.groupBy = function (items, fn) {
                var out = new Map(), i = 0;
                for (var x of items) { var k = fn(x, i++); if (!out.has(k)) out.set(k, []); out.get(k).push(x); }
                return out;
              };
            }
            if (!Array.fromAsync) {
              Array.fromAsync = async function (items, fn) {
                var out = [], i = 0;
                for await (var x of items) { out.push(fn ? await fn(x, i) : x); i++; }
                return out;
              };
            }
            if (!URL.canParse) {
              URL.canParse = function (u, b) { try { new URL(u, b); return true; } catch (e) { return false; } };
            }
            if (typeof AbortSignal !== 'undefined' && !AbortSignal.any) {
              AbortSignal.any = function (signals) {
                var c = new AbortController();
                signals.forEach(function (s) {
                  if (s.aborted) c.abort(s.reason);
                  else s.addEventListener('abort', function () { c.abort(s.reason); });
                });
                return c.signal;
              };
            }
            var sp = Set.prototype;
            function keys(o) { return Array.from(o.keys ? o.keys() : o); }
            if (!sp.union) sp.union = function (o) { var r = new Set(this); keys(o).forEach(function (v) { r.add(v); }); return r; };
            if (!sp.intersection) sp.intersection = function (o) { var r = new Set(); Array.from(this).forEach(function (v) { if (o.has(v)) r.add(v); }); return r; };
            if (!sp.difference) sp.difference = function (o) { var r = new Set(); Array.from(this).forEach(function (v) { if (!o.has(v)) r.add(v); }); return r; };
            if (!sp.symmetricDifference) sp.symmetricDifference = function (o) { var r = new Set(this); keys(o).forEach(function (v) { if (r.has(v)) r.delete(v); else r.add(v); }); return r; };
            if (!sp.isSubsetOf) sp.isSubsetOf = function (o) { return Array.from(this).every(function (v) { return o.has(v); }); };
            if (!sp.isSupersetOf) sp.isSupersetOf = function (o) { var s = this; return keys(o).every(function (v) { return s.has(v); }); };
            if (!sp.isDisjointFrom) sp.isDisjointFrom = function (o) { return !Array.from(this).some(function (v) { return o.has(v); }); };

            if (!Promise.try) {
              Promise.try = function (fn) {
                var args = Array.prototype.slice.call(arguments, 1);
                return new Promise(function (resolve) { resolve(fn.apply(null, args)); });
              };
            }
            if (window.ReadableStream && !ReadableStream.prototype[Symbol.asyncIterator]) {
              ReadableStream.prototype[Symbol.asyncIterator] = function () {
                var reader = this.getReader();
                return {
                  next: function () { return reader.read(); },
                  return: function () { reader.releaseLock(); return Promise.resolve({ done: true, value: undefined }); },
                  [Symbol.asyncIterator]: function () { return this; }
                };
              };
              ReadableStream.prototype.values = ReadableStream.prototype[Symbol.asyncIterator];
            }
            if (window.Element && !Element.prototype.checkVisibility) {
              Element.prototype.checkVisibility = function () { return !!(this.offsetWidth || this.offsetHeight || this.getClientRects().length); };
            }
            if (typeof Iterator === 'undefined') {
              var IterProto = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
              var IteratorShim = function Iterator() {};
              IteratorShim.prototype = IterProto;
              IteratorShim.from = function (o) { return o[Symbol.iterator] ? o[Symbol.iterator]() : o; };
              window.Iterator = IteratorShim;
              var wrap = function (it) { return { [Symbol.iterator]: function () { return it; } }; };
              IterProto.map = function (fn) { var s = this; return (function* () { var i = 0; for (var x of wrap(s)) yield fn(x, i++); })(); };
              IterProto.filter = function (fn) { var s = this; return (function* () { var i = 0; for (var x of wrap(s)) if (fn(x, i++)) yield x; })(); };
              IterProto.take = function (n) { var s = this; return (function* () { var i = 0; if (n <= 0) return; for (var x of wrap(s)) { yield x; if (++i >= n) return; } })(); };
              IterProto.drop = function (n) { var s = this; return (function* () { var i = 0; for (var x of wrap(s)) if (i++ >= n) yield x; })(); };
              IterProto.flatMap = function (fn) { var s = this; return (function* () { var i = 0; for (var x of wrap(s)) yield* wrap(fn(x, i++)[Symbol.iterator]()); })(); };
              IterProto.toArray = function () { return Array.from(wrap(this)); };
              IterProto.forEach = function (fn) { var i = 0; for (var x of wrap(this)) fn(x, i++); };
              IterProto.some = function (fn) { var i = 0; for (var x of wrap(this)) if (fn(x, i++)) return true; return false; };
              IterProto.every = function (fn) { var i = 0; for (var x of wrap(this)) if (!fn(x, i++)) return false; return true; };
              IterProto.find = function (fn) { var i = 0; for (var x of wrap(this)) if (fn(x, i++)) return x; return undefined; };
              IterProto.reduce = function (fn, init) { var acc = init, first = arguments.length < 2, i = 0; for (var x of wrap(this)) { if (first) { acc = x; first = false; } else acc = fn(acc, x, i); i++; } return acc; };
            }
            if (!window.requestIdleCallback) {
              window.requestIdleCallback = function (cb) { return setTimeout(function () { cb({ didTimeout: false, timeRemaining: function () { return 10; } }); }, 1); };
              window.cancelIdleCallback = function (id) { clearTimeout(id); };
            }
          } catch (e) { post('shim: ' + e); }



          // Records how the page loads song files, for Settings > Page errors.
          try {
            var plainUrl = function (u) { return String(u || '').split('?')[0].slice(-90); };
            var realCreate = URL.createObjectURL;
            URL.createObjectURL = function (o) {
              var made = realCreate.apply(URL, arguments);
              try {
                if (o && o.size !== undefined && o.size > 20000) {
                  post('blob created size=' + o.size + ' type="' + o.type + '" from ' +
                       String(new Error().stack || '').split('\n').slice(1, 4).map(function (l) { return plainUrl(l.trim()); }).join(' | '));
                }
              } catch (e) {}
              return made;
            };
            var realFetch = window.fetch;
            window.fetch = function (input, init) {
              var url = typeof input === 'string' ? input : (input && input.url) || '';
              var promise = realFetch.apply(this, arguments);
              try {
                url = String(url);
                promise.then(function (r) {
                  var ct = r.headers.get('content-type') || '';
                  if (/^audio|mpegurl|octet-stream/i.test(ct) || /\.(mp3|m4a|wav|ogg|opus|aac|m3u8)(\?|$)/i.test(url)) {
                    var range = '';
                    try { range = JSON.stringify((init && init.headers) || (input && input.headers && input.headers.get && input.headers.get('range')) || ''); } catch (e) {}
                    post('fetch ' + plainUrl(url) + ' status=' + r.status + ' type=' + ct + ' length=' + r.headers.get('content-length') + ' range=' + (r.headers.get('content-range') || '') + ' request=' + range);
                  }
                }, function (e) { post('fetch failed ' + plainUrl(url) + ' ' + e); });
              } catch (e) {}
              return promise;
            };
          } catch (e) { post('fetch log: ' + e); }

          // Records what the audio player does, so a song that will not play can be explained in Settings > Page errors.
          try {
            var shortSrc = function (u) { u = String(u || ''); return u.length > 70 ? '...' + u.slice(-70) : u; };
            var originalPlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function () {
              var el = this, result;
              try { result = originalPlay.apply(this, arguments); }
              catch (e) { post('media play() threw: ' + e); throw e; }
              if (result && result.catch) {
                result.catch(function (e) { post('media play() rejected: ' + (e && e.name) + ' ' + (e && e.message) + ' src=' + shortSrc(el.currentSrc || el.src)); });
              }
              return result;
            };
            ['play', 'playing', 'pause', 'ended', 'error', 'stalled', 'waiting', 'abort', 'emptied', 'loadstart', 'canplay'].forEach(function (type) {
              document.addEventListener(type, function (e) {
                var m = e.target;
                if (!m || !m.tagName || !/^(AUDIO|VIDEO)$/.test(m.tagName)) return;
                post('media ' + type + ' src=' + shortSrc(m.currentSrc || m.src) + ' t=' + (m.currentTime || 0).toFixed(1) +
                     (m.error ? ' error=' + m.error.code + ' ' + (m.error.message || '') : '') + ' ready=' + m.readyState + ' net=' + m.networkState);
              }, true);
            });
          } catch (e) { post('media log: ' + e); }

          // iOS before 17 cannot decode Opus inside an MP4, which is how Suno ships its songs (the page decrypts the file and
          // plays it from a blob). So when such a blob is about to be played, decode it here with a small Opus decoder and give
          // the player ordinary WAV audio instead.
          try {
            // canPlayType says "maybe" even on iOS 16, so go by the version: iOS 17.1 and later (which have ManagedMediaSource) handle it.
            var canOpusMp4 = typeof ManagedMediaSource !== 'undefined';
            var OpusLib = window['opus-decoder'] && window['opus-decoder'].OpusDecoder;
            var maybeText = '';
            try { maybeText = document.createElement('audio').canPlayType('audio/mp4; codecs="opus"'); } catch (e) {}
            post('opus check: native=' + canOpusMp4 + ' decoder=' + !!OpusLib + ' canPlayType="' + maybeText + '"');
            if (!canOpusMp4 && OpusLib) {
              var fourcc = function (dv, p) { return String.fromCharCode(dv.getUint8(p), dv.getUint8(p + 1), dv.getUint8(p + 2), dv.getUint8(p + 3)); };
              var boxesIn = function (dv, from, to) {
                var out = [], p = from;
                while (p + 8 <= to) {
                  var size = dv.getUint32(p), type = fourcc(dv, p + 4), head = 8;
                  if (size === 1) { size = dv.getUint32(p + 12); head = 16; }
                  else if (size === 0) size = to - p;
                  if (size < head || p + size > to) break;
                  out.push({ type: type, start: p, body: p + head, end: p + size });
                  p += size;
                }
                return out;
              };
              var childOf = function (dv, box, type) {
                if (!box) return undefined;
                return boxesIn(dv, box.body, box.end).filter(function (b) { return b.type === type; })[0];
              };
              var demuxOpus = function (buf) {
                var dv = new DataView(buf);
                var moov = boxesIn(dv, 0, buf.byteLength).filter(function (b) { return b.type === 'moov'; })[0];
                if (!moov) return null;
                var traks = boxesIn(dv, moov.body, moov.end).filter(function (b) { return b.type === 'trak'; });
                for (var t = 0; t < traks.length; t++) {
                  var stbl = childOf(dv, childOf(dv, childOf(dv, traks[t], 'mdia'), 'minf'), 'stbl');
                  var stsd = childOf(dv, stbl, 'stsd');
                  if (!stsd) continue;
                  var entry = boxesIn(dv, stsd.body + 8, stsd.end).filter(function (b) { return b.type === 'Opus'; })[0];
                  if (!entry) continue;
                  var dOps = boxesIn(dv, entry.body + 28, entry.end).filter(function (b) { return b.type === 'dOps'; })[0];
                  if (!dOps) continue;
                  var q = dOps.body;
                  var channels = dv.getUint8(q + 1), preSkip = dv.getUint16(q + 2), family = dv.getUint8(q + 10);
                  var streamCount = 1, coupled = channels === 2 ? 1 : 0, table = channels === 2 ? [0, 1] : [0];
                  if (family !== 0) {
                    streamCount = dv.getUint8(q + 11); coupled = dv.getUint8(q + 12); table = [];
                    for (var c = 0; c < channels; c++) table.push(dv.getUint8(q + 13 + c));
                  }
                  var stsz = childOf(dv, stbl, 'stsz'), stsc = childOf(dv, stbl, 'stsc');
                  var stco = childOf(dv, stbl, 'stco'), co64 = childOf(dv, stbl, 'co64');
                  var fixed = dv.getUint32(stsz.body + 4), count = dv.getUint32(stsz.body + 8), sizes = [];
                  for (var i = 0; i < count; i++) sizes.push(fixed ? fixed : dv.getUint32(stsz.body + 12 + 4 * i));
                  var runs = [], runCount = dv.getUint32(stsc.body + 4);
                  for (var r = 0; r < runCount; r++) runs.push({ first: dv.getUint32(stsc.body + 8 + 12 * r), per: dv.getUint32(stsc.body + 12 + 12 * r) });
                  var offsets = [], chunkBox = stco || co64, chunkCount = dv.getUint32(chunkBox.body + 4);
                  for (var k = 0; k < chunkCount; k++) {
                    offsets.push(stco ? dv.getUint32(chunkBox.body + 8 + 4 * k)
                                      : dv.getUint32(chunkBox.body + 8 + 8 * k) * 4294967296 + dv.getUint32(chunkBox.body + 12 + 8 * k));
                  }
                  var packets = [], index = 0;
                  for (var ch = 0; ch < offsets.length && index < count; ch++) {
                    var per = 1;
                    for (var u = 0; u < runs.length; u++) if (runs[u].first <= ch + 1) per = runs[u].per;
                    var at = offsets[ch];
                    for (var s = 0; s < per && index < count; s++) {
                      packets.push(new Uint8Array(buf, at, sizes[index]));
                      at += sizes[index];
                      index++;
                    }
                  }
                  return { channels: channels, preSkip: preSkip, streamCount: streamCount, coupled: coupled, table: table, packets: packets };
                }
                return null;
              };
              var clamp16 = function (x) { x = x > 1 ? 1 : (x < -1 ? -1 : x); return x < 0 ? x * 32768 : x * 32767; };
              var opusMp4ToWav = async function (blob) {
                var started = Date.now();
                var buf = await blob.arrayBuffer();
                var info = demuxOpus(buf);
                if (!info) throw new Error('no Opus track in the file');
                var decoder = new OpusLib({ channels: info.channels, streamCount: info.streamCount, coupledStreamCount: info.coupled,
                                            channelMappingTable: info.table, preSkip: info.preSkip, sampleRate: 48000 });
                await decoder.ready;
                var outChannels = info.channels > 1 ? 2 : 1, lefts = [], rights = [], total = 0;
                for (var i = 0; i < info.packets.length; i += 250) {
                  var res = await decoder.decodeFrames(info.packets.slice(i, i + 250));
                  lefts.push(res.channelData[0]);
                  rights.push(res.channelData[outChannels > 1 ? 1 : 0]);
                  total += res.samplesDecoded;
                  await new Promise(function (done) { setTimeout(done, 0); });
                }
                decoder.free();
                var pcm = new Int16Array(total * outChannels), o = 0;
                for (var b = 0; b < lefts.length; b++) {
                  var L = lefts[b], R = rights[b];
                  for (var n = 0; n < L.length; n++) {
                    pcm[o++] = clamp16(L[n]);
                    if (outChannels > 1) pcm[o++] = clamp16(R[n]);
                  }
                }
                var head = new ArrayBuffer(44), h = new DataView(head);
                var text = function (at, s) { for (var z = 0; z < s.length; z++) h.setUint8(at + z, s.charCodeAt(z)); };
                text(0, 'RIFF'); h.setUint32(4, 36 + pcm.byteLength, true); text(8, 'WAVE'); text(12, 'fmt ');
                h.setUint32(16, 16, true); h.setUint16(20, 1, true); h.setUint16(22, outChannels, true);
                h.setUint32(24, 48000, true); h.setUint32(28, 48000 * outChannels * 2, true);
                h.setUint16(32, outChannels * 2, true); h.setUint16(34, 16, true);
                text(36, 'data'); h.setUint32(40, pcm.byteLength, true);
                post('opus decoded: ' + info.packets.length + ' packets, ' + (total / 48000).toFixed(1) + ' s, ' + (Date.now() - started) + ' ms');
                return realCreate.call(URL, new Blob([head, pcm.buffer], { type: 'audio/wav' }));
              };

              var pendingBlobs = {}, conversions = {};
              var wrappedCreate = URL.createObjectURL;
              URL.createObjectURL = function (o) {
                var made = wrappedCreate.apply(URL, arguments);
                try { if (o && o.size > 20000 && /^audio[/](mp4|x-m4a|m4a)/i.test(o.type || '')) pendingBlobs[made] = o; } catch (e) {}
                return made;
              };
              var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
              Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                configurable: true, enumerable: srcDesc.enumerable, get: srcDesc.get,
                set: function (v) {
                  var el = this, key = String(v);
                  if (pendingBlobs[key]) {
                    if (!conversions[key]) conversions[key] = opusMp4ToWav(pendingBlobs[key]);
                    el.__converting = conversions[key].then(
                      function (wavUrl) { el.__converting = null; srcDesc.set.call(el, wavUrl); },
                      function (e) { el.__converting = null; post('opus convert failed: ' + e); srcDesc.set.call(el, key); });
                    return;
                  }
                  el.__converting = null;
                  srcDesc.set.call(this, v);
                }
              });
              var playBeforeConvert = HTMLMediaElement.prototype.play;
              HTMLMediaElement.prototype.play = function () {
                var el = this, args = arguments;
                if (el.__converting) return el.__converting.then(function () { return playBeforeConvert.apply(el, args); });
                return playBeforeConvert.apply(this, args);
              };
              post('opus conversion ready (this iOS cannot play Opus in MP4)');
            }
          } catch (e) { post('opus setup: ' + e); }

          // Downloads of files the page builds in memory (blob: links). The page clicks a hidden download link and then
          // immediately discards the file, which the iPhone's own download system is too slow to catch. So take the file
          // right away, send it to the app in pieces, and let the app save it and open the share sheet.
          try {
            var realAnchorClick = HTMLAnchorElement.prototype.click;
            var sendCount = 0;
            var sendBlob = function (blob, name) {
              var id = String(Date.now()) + '-' + (sendCount++);
              var reader = new FileReader();
              reader.onload = function () {
                var text = String(reader.result), base64 = text.slice(text.indexOf(',') + 1);
                var piece = 1000000 - (1000000 % 4), total = Math.max(1, Math.ceil(base64.length / piece));
                for (var i = 0; i < total; i++) {
                  window.webkit.messageHandlers.saveFile.postMessage({ id: id, name: name, index: i, total: total, data: base64.slice(i * piece, (i + 1) * piece) });
                }
              };
              reader.onerror = function () { post('download read failed'); };
              reader.readAsDataURL(blob);
            };
            var takeBlobLink = function (a) {
              if (!a || !a.href || !/^blob:/.test(a.href) || !a.hasAttribute('download')) return false;
              var name = a.getAttribute('download') || 'download';
              post('download from blob: ' + name);
              fetch(a.href).then(function (r) { return r.blob(); }).then(function (b) { sendBlob(b, name); })
                .catch(function (e) { post('download failed: ' + e); });
              return true;
            };
            HTMLAnchorElement.prototype.click = function () {
              if (takeBlobLink(this)) return;
              return realAnchorClick.apply(this, arguments);
            };
            document.addEventListener('click', function (e) {
              var a = e.target && e.target.closest ? e.target.closest('a') : null;
              if (a && takeBlobLink(a)) { e.preventDefault(); e.stopImmediatePropagation(); }
            }, true);
          } catch (e) { post('download hook: ' + e); }

          // Tell the page it is running as an installed app, so it skips "open the app" and "add to home screen" prompts.
          try {
            Object.defineProperty(navigator, 'standalone', { get: function () { return true; }, configurable: true });
            var realMatchMedia = window.matchMedia.bind(window);
            window.matchMedia = function (q) {
              var text = String(q);
              var standalone = /display-mode:\s*(standalone|minimal-ui)/i.test(text);
              var browser = /display-mode:\s*browser/i.test(text);
              if (!standalone && !browser) return realMatchMedia(q);
              return {
                matches: standalone, media: text, onchange: null,
                addListener: function () {}, removeListener: function () {},
                addEventListener: function () {}, removeEventListener: function () {},
                dispatchEvent: function () { return false; }
              };
            };
          } catch (e) { post('standalone: ' + e); }

          try {
            var style = document.createElement('style');
            style.textContent = `__CSS__`;
            (document.head || document.documentElement).appendChild(style);
          } catch (e) { post('css: ' + e); }

          // Removes "out of date" notices and "get the app" prompts, so the page behaves like it is already inside the app.
          var outdated = /software is out of date|browser is out of date|update your browser|unsupported browser/i;
          var appPrompt = /get the full app experience|listen in the app|use the app to get|get the suno app|trusted by grammy|download the app|get the app\b|install the app|open in app/i;
          var appButton = /^\s*(open app|open in app|get app|install)\s*$/i;
          function unlock() {
            [document.body, document.documentElement].forEach(function (el) {
              if (!el) return;
              el.style.removeProperty('pointer-events');
              el.style.removeProperty('overflow');
              el.removeAttribute('data-scroll-locked');
            });
          }
          function hideOverlays() {
            try {
              if (window.__noHide || !document.body) return;
              var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
              var n, hidAny = false;
              while ((n = w.nextNode())) {
                var t = n.nodeValue || '';
                if (!t || t.length > 400) continue;
                var el = n.parentElement;
                if (!el) continue;
                if (outdated.test(t)) {
                  var hops = 0;
                  while (el.parentElement && hops < 4 && el.parentElement !== document.body &&
                         (el.parentElement.textContent || '').length < 500) { el = el.parentElement; hops++; }
                  el.style.display = 'none';
                } else if (appPrompt.test(t)) {
                  // climb to the pop-up's outermost wrapper (a direct child of <body>) and remove it with its backdrop
                  var start = el;
                  while (el.parentElement && el.parentElement !== document.body) el = el.parentElement;
                  if (el && el !== document.body && (el.textContent || '').length < 800) { el.style.display = 'none'; hidAny = true; }
                  else {
                    // a banner inside the page: hide the nearest fixed or sticky box around the text
                    var box = start, climbed = 0;
                    while (box && box !== document.body && climbed < 8) {
                      var pos = getComputedStyle(box).position;
                      if (pos === 'fixed' || pos === 'sticky') { box.style.display = 'none'; hidAny = true; break; }
                      box = box.parentElement; climbed++;
                    }
                  }
                } else if (appButton.test(t)) {
                  var b = el.closest('button, a, [role="button"]') || el;
                  b.style.display = 'none';
                }
              }
              if (hidAny) unlock();
            } catch (e) {}
          }
          var hideTimer = null;
          function scheduleHide() { if (hideTimer) return; hideTimer = setTimeout(function () { hideTimer = null; hideOverlays(); }, 250); }
          try { new MutationObserver(scheduleHide).observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
          setInterval(hideOverlays, 1500);

          var oldError = console.error;
          console.error = function () {
            post('console: ' + Array.prototype.slice.call(arguments).join(' ').slice(0, 300));
            return oldError.apply(console, arguments);
          };
          window.addEventListener('error', function (e) {
            post((e.message || 'error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0) + ' [' + location.href + ']');
          });
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            post('promise: ' + (r && (r.stack || r.message) || r) + ' [' + location.href + ']');
          });
        })();
        """#.replacingOccurrences(of: "__CSS__", with: css)
    }
}
