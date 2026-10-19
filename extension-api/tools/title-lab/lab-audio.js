"use strict";
// Sound for the title lab: plays the title sound candidates (mods/tools/sound/gen/, made by ai_titles.py, SOUND-SYSTEM.md S7)
// on the lab's own timeline, as the game would: the sound of a moment starts when the lab's clock reaches it, a hold loops from the
// land to the end of the title and follows 1 - the leave's progress down to nothing, and what is left is cut short (0.15 s) when
// the title is gone. It never keeps a clock of its own: the lab's time t is the only time (a paused or slowed lab pauses or
// slows its sound, a jump of the timeline restarts what should be sounding at that point).
//
// The page calls LabAudio.frame(info) once a frame (see title-lab.html); everything else is here, with its own panel under the
// timeline: a candidate picker for each cue of the style on show (none, the candidates, what the game has now), each with a
// button that plays it alone, the master volume, and two switches. The candidates are listed by gen/manifest.js.
//
// Opened from a server the oggs are decoded to buffers (WebAudio: gapless loops). Opened from a file the browser will not
// hand them to WebAudio, so each sound is an <audio> element instead (a loop then has a small gap at its join).
(function () {
  const KIT = "../../../mods/pz-ui-kit/PZUIKit/42/media/sound/";
  const GEN = "../../../mods/tools/sound/gen/";
  const FADE_OFF = 0.15;        // seconds: what is left of a title's sound is cut in this time when it is gone (SOUND-SYSTEM.md S7)
  const SEEK_JUMP = 0.5;        // a step of the lab's clock bigger than this (seconds) is a jump (scrub, "바로 사라지기", restart), not a frame
  const LINE_DB = -6;           // a line that plays its title's sounds (when asked to) does so this much lower

  // The lab's styles that have title sounds, and the sound style each one is.
  const STYLE_OF = {
    "stamp-new": "stamp", "discovery-new": "discovery", "notice-new": "notice", "unveil-new": "unveil", "bleed-new": "bleed",
    "pulse-new": "pulse", "type-new": "type", "sink-new": "sink", "dust-paper": "dust", "brief": "brief",
  };
  // The cues of each sound style: [id, label, moment, line?]. A cue's file is KIT_T_<style>_<moment>[_line]_<a|b|c>.ogg.
  const CUES = {
    stamp: [["land", "착지", "land"]],
    notice: [["enter", "등장", "enter"], ["leave", "퇴장 (여운)", "leave"]],
    dust: [["enter", "등장", "enter"], ["leave", "퇴장 (여운)", "leave"]],
    discovery: [["enter", "등장", "enter"], ["leave", "퇴장 (여운)", "leave"]],
    unveil: [["enter", "등장", "enter"], ["leave", "퇴장 (여운)", "leave"]],
    sink: [["enter", "등장", "enter"]],
    pulse: [["enter", "등장", "enter"]],
    bleed: [["enter", "등장", "enter"]],
    brief: [["enter", "등장", "enter"], ["leave", "퇴장 (여운)", "leave"]],
    type: [],
  };
  // The kit's keyboard (PZUIKit.Sound "kit.terminal", the sound lab's): a typed title strikes a key for each character (the
  // same character, the same key: Sound.keyOf), and presses the return with each feed of its leave.
  const KEYS = ["KIT_Key_1", "KIT_Key_2", "KIT_Key_3", "KIT_Key_4", "KIT_Key_5", "KIT_Key_6", "KIT_Key_7", "KIT_Key_8"];
  const keyFile = ch => {
    if (ch === " ") return KIT + "KIT_KeySpace_1.ogg";
    const spread = (ch ? ch.charCodeAt(0) : 0) * 0.6180339887;
    return KIT + KEYS[Math.floor((spread - Math.floor(spread)) * KEYS.length)] + "_1.ogg";
  };
  const RETURN = KIT + "KIT_KeyEnter_1.ogg";
  // What the game has now, to compare with: a cue's single option (or an extra one beside a, b, c).
  const NOW = {
  };
  // The candidates of each cue ({ "style:cue": [files in gen/] }, gen/manifest.js); type has only what it has now.
  let MADE = {}, PICKED = {};
  const candidatesOf = (style, cue) => MADE[style + ":" + cue[0]] || [];
  const hasCandidates = (style, cue) => candidatesOf(style, cue).length > 0;
  const firstPick = (style, cue) => hasCandidates(style, cue) ? candidatesOf(style, cue)[0] : "now";
  // The choice on the panel: what was chosen, unless its file is gone (a pick made, the rest cleared), then the first.
  const chosen = (style, cue) => {
    const p = state.picks[style + ":" + cue[0]];
    return p && (p === "none" || p === "now" || candidatesOf(style, cue).includes(p)) ? p : firstPick(style, cue);
  };
  // A pick is "none", "now" or a candidate's file name; the url it plays.
  const fileOf = (style, cue, pick) => {
    if (pick === "now") return NOW[style + ":" + cue[0]] ? KIT + NOW[style + ":" + cue[0]] : null;
    if (!pick || pick === "none" || !candidatesOf(style, cue).includes(pick)) return null;
    return GEN + pick;
  };

  const KEY = "labAudio.v3";
  const state = { picks: {}, master: 0.7, lineToo: false };
  try { Object.assign(state, JSON.parse(localStorage.getItem(KEY) || "{}")); } catch (e) { }
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { } };

  const fromFile = location.protocol === "file:";
  // (made at once, suspended until the first click: decoding needs it)
  let ctx = null, master = null, unlocked = false;
  if (!fromFile) {
    try {
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      master = ctx.createGain(); master.gain.value = state.master; master.connect(ctx.destination);
    } catch (e) { ctx = null; }
  }
  const buffers = new Map();     // url -> { buf | el, duration, failed }
  const log = [];                // what was started and stopped (LabAudio.log): for checking, and the panel's status
  const note = (what) => { log.push({ at: Number(clock.t.toFixed(3)), what }); if (log.length > 400) log.shift(); };

  // ------------------------------------------------------------------------------------------------ loading
  function load(file) {
    const url = file;
    if (buffers.has(url)) return buffers.get(url);
    const entry = { url, duration: 0, buf: null, failed: false };
    buffers.set(url, entry);
    if (fromFile) {
      const el = new Audio(url);
      el.preload = "auto";
      el.addEventListener("loadedmetadata", () => { entry.duration = el.duration; });
      el.addEventListener("error", () => { entry.failed = true; });
      entry.probe = el;
    } else if (ctx) {
      fetch(url).then(r => { if (!r.ok) throw new Error(r.status); return r.arrayBuffer(); })
        .then(b => ctx.decodeAudioData(b)).then(buf => { entry.buf = buf; entry.duration = buf.duration; })
        .catch(() => { entry.failed = true; });
    }
    return entry;
  }

  // all the candidates of a style, ready before they are asked for
  function preload(style) {
    if (!style) return;
    for (const cue of CUES[style]) for (const pick of [...candidatesOf(style, cue), "now"]) {
      const f = fileOf(style, cue, pick);
      if (f) load(f);
    }
  }

  // ------------------------------------------------------------------------------------------------ voices
  // A voice is one playing sound: start(offset), gain(v), rate(r), stop(fade seconds), pause(), resume().
  function makeVoice(entry, loop) {
    if (fromFile) {
      const el = new Audio(entry.url);
      el.loop = loop;
      let dead = false;
      return {
        start(offset) { try { el.currentTime = offset; } catch (e) { } el.play().catch(() => { }); },
        gain(v) { el.volume = Math.max(0, Math.min(1, v * state.master)); },
        rate(r) { el.playbackRate = Math.max(0.0625, Math.min(16, r)); },
        stop(fade) { if (dead) return; dead = true; const t0 = performance.now(), v0 = el.volume; const step = () => { const k = (performance.now() - t0) / (fade * 1000); if (k >= 1 || fade <= 0) { el.pause(); } else { el.volume = v0 * (1 - k); requestAnimationFrame(step); } }; step(); },
        pause() { el.pause(); },
        resume() { if (!dead) el.play().catch(() => { }); },
        get ended() { return el.ended || dead && el.paused; },
      };
    }
    const src = ctx.createBufferSource(), g = ctx.createGain();
    src.buffer = entry.buf; src.loop = loop;
    src.connect(g).connect(master);
    let ended = false;
    src.onended = () => { ended = true; };
    return {
      start(offset) { src.start(0, loop ? offset % entry.buf.duration : Math.min(offset, entry.buf.duration - 0.001)); },
      gain(v) { g.gain.value = Math.max(0, v); },
      rate(r) { src.playbackRate.value = Math.max(0.0625, Math.min(16, r)); },
      stop(fade) { const now = ctx.currentTime; g.gain.cancelScheduledValues(now); g.gain.setValueAtTime(g.gain.value, now); g.gain.linearRampToValueAtTime(0, now + Math.max(fade, 0.005)); try { src.stop(now + Math.max(fade, 0.005) + 0.02); } catch (e) { } },
      pause() { },
      resume() { },
      get ended() { return ended; },
    };
  }

  const voices = [];             // { voice, kind: "shot" | "hold", file, base (linear), piece, born (lab seconds) }
  function stopAll(fade) { for (const v of voices) v.voice.stop(fade); voices.length = 0; }

  // ------------------------------------------------------------------------------------------------ the run
  const clock = { t: 0 };        // the lab's time as last seen (for the log)
  let prevT = null, prevWall = 0, rate = 1, needSeek = true, curStyle = null, wasLive = false, lastLiveT = null;

  // What a title (and its line) has to play, from what the lab says of its pieces.
  function planOf(info) {
    const style = STYLE_OF[info.style];
    if (!style) return null;
    const cues = CUES[style];
    const events = [];
    let lifeEnd = 0;
    info.pieces.forEach((p, i) => {
      const isLine = i > 0;
      const land = p.delay + (p.impact ? Math.min(0.16, p.enterTime) : p.enterTime);
      const times = { enter: p.delay, land, hold: land, leave: p.leaveAt };
      lifeEnd = Math.max(lifeEnd, p.leaveAt + p.leaveTime * (1 + p.ash));
      if (p.strikes) p.strikes.forEach((k, n) => events.push({ key: "key" + i + "." + n, file: keyFile(k.ch), moment: "key", at: p.delay + k.at, db: isLine ? -3 : 0 }));
      // (the return as the title is all in: its land, as the kit sounds it; its line is typed after it)
      if (p.strikes && i === 0) events.push({ key: "return", file: RETURN, moment: "land", at: p.delay + p.enterTime, db: -3 });
      if (p.feeds && i === 0) p.feeds.forEach((f, n) => events.push({ key: "feed" + n, file: RETURN, moment: "feed", at: p.leaveAt + f, db: -2 * n }));
      for (const cue of cues) {
        const own = !!cue[3];
        if (own !== isLine && !(isLine && state.lineToo && !own && cue[2] !== "hold")) continue;
        const pick = chosen(style, cue);
        const file = fileOf(style, cue, pick);
        if (!file) continue;
        events.push({ key: style + ":" + cue[0] + (isLine && !own ? ":line" : ""), file, moment: cue[2], at: times[cue[2]], hold: cue[2] === "hold",
          db: isLine && !own ? LINE_DB : 0, leaveAt: p.leaveAt, leaveTime: p.leaveTime });
      }
    });
    return { style, events, lifeEnd };
  }

  const holdGain = (ev, t) => {
    if (t < ev.leaveAt) return 1;
    return 1 - Math.min(1, Math.max(0, (t - ev.leaveAt) / Math.max(ev.leaveTime, 1e-6)));
  };

  const LATE = 0.4;              // a one-shot whose file is not decoded yet is still played if it comes within this many seconds of its moment
  const waiting = [];            // one-shots whose file was not ready at their moment
  function fire(ev, t, offsetNow) {
    const entry = load(ev.file);
    const ready = fromFile ? entry.duration > 0 : !!entry.buf;
    if (!ready) {
      if (!ev.hold && offsetNow < LATE && !waiting.includes(ev)) waiting.push(ev);
      return;
    }
    const v = makeVoice(entry, ev.hold);
    v.rate(rate);
    const nominal = Math.pow(10, ev.db / 20) * (ev.hold ? holdGain(ev, t) : 1);
    v.gain(nominal);
    v.start(offsetNow);
    voices.push({ voice: v, kind: ev.hold ? "hold" : "shot", ev, entry, nominal });
    note((ev.hold ? "hold " : ev.moment + " ") + ev.file + (offsetNow > 0.005 ? " @" + offsetNow.toFixed(2) : ""));
  }

  function seek(plan, t) {
    stopAll(0.03);
    for (const ev of plan.events) {
      if (ev.at > t) continue;
      const entry = load(ev.file);
      if (ev.hold) {
        if (t < plan.lifeEnd && holdGain(ev, t) > 0) fire(ev, t, t - ev.at);
      } else if (t - ev.at < 0.04 || (entry.duration && t - ev.at < entry.duration)) {
        fire(ev, t, Math.max(0, t - ev.at));
      }
    }
  }

  let failed = false;
  // (what goes wrong here must never stop the lab's own frame loop)
  function frame(info) {
    try { step(info); } catch (e) { if (!failed) console.error("LabAudio:", e); failed = true; }
  }

  function step(info) {
    const t = info.t, wall = performance.now();
    clock.t = t;
    const plan = planOf(info);
    if (info.style !== curStyle) {
      curStyle = info.style; panel.show(STYLE_OF[info.style] || null); needSeek = true; waiting.length = 0;
      preload(STYLE_OF[info.style]);
    }
    if (plan) for (const ev of plan.events) load(ev.file);   // (cached: a pick changed on the panel loads its file)
    const live = !!info.live && unlocked && (fromFile || !!ctx) && !!plan && state.master > 0;
    if (!live) {
      // (the sound stands where the lab stands: paused, or being scrubbed, or a style with no sound)
      if (wasLive && fromFile) for (const v of voices) v.voice.pause();
      if (wasLive && !fromFile) ctx.suspend().catch(() => { });
      wasLive = false; prevT = t; prevWall = wall;
      if (!plan) { stopAll(0.03); needSeek = true; }
      return;
    }
    if (!wasLive) {
      wasLive = true;
      if (!fromFile && ctx.state === "suspended") ctx.resume().catch(() => { });
      if (fromFile) for (const v of voices) v.voice.resume();
      // what was sounding goes on if the lab is where it stopped; if it was moved (a scrub, a restart) it is set again
      if (Math.abs(t - lastLiveT) > 0.05 || !voices.length && lastLiveT === null) needSeek = true;
      prevT = lastLiveT === null ? null : t;
    }
    // the speed the lab is really going at (its speed setting, less what its own frame-time cap takes off a slow frame)
    if (prevT !== null && wall - prevWall > 2) {
      const r = (t - prevT) / ((wall - prevWall) / 1000);
      if (r > 0) rate += (Math.max(0.1, Math.min(4, r)) - rate) * 0.25;
    } else if (prevT === null) rate = info.speed || 1;
    if (needSeek || prevT === null || t < prevT - 1e-6 || t - prevT > SEEK_JUMP) {
      waiting.length = 0;
      seek(plan, t);
      needSeek = false;
    } else {
      for (const ev of plan.events) if (!ev.hold && ev.at > prevT && ev.at <= t) fire(ev, t, t - ev.at);
    }
    // (a sound whose file came late is played from where it would be now, if that is not long after its moment)
    for (let i = waiting.length - 1; i >= 0; i--) {
      const ev = waiting[i], e = load(ev.file);
      if (t - ev.at >= LATE || t < ev.at) { waiting.splice(i, 1); if (t >= ev.at) note("not loaded in time: " + ev.file); continue; }
      if (fromFile ? e.duration > 0 : e.buf) { waiting.splice(i, 1); fire(ev, t, t - ev.at); }
    }
    // a hold is there from its moment to the end of the title (started late if its file came late)
    for (const ev of plan.events) {
      if (!ev.hold || t < ev.at || t >= plan.lifeEnd || holdGain(ev, t) <= 0) continue;
      if (!voices.some(v => v.kind === "hold" && v.ev.key === ev.key && v.ev.file === ev.file)) fire(ev, t, t - ev.at);
    }
    // holds follow the leave; everything is cut when the title is gone; voices that ended are dropped
    for (let i = voices.length - 1; i >= 0; i--) {
      const v = voices[i];
      if (v.kind === "hold") {
        const g = holdGain(v.ev, t) * Math.pow(10, v.ev.db / 20);
        if (t >= plan.lifeEnd || g <= 0) { v.voice.stop(FADE_OFF); voices.splice(i, 1); note("stop hold " + v.ev.file); continue; }
        v.nominal = g;
        v.voice.gain(g);
      }
      v.voice.rate(rate);
      if (v.voice.ended) voices.splice(i, 1);
    }
    if (t >= plan.lifeEnd && voices.length) { stopAll(FADE_OFF); note("title gone"); }
    prevT = t; prevWall = wall; lastLiveT = t;
  }

  // ------------------------------------------------------------------------------------------------ the panel
  const panel = (() => {
    const css = document.createElement("style");
    css.textContent = `
      #labAudio { margin-top: 6px; padding: 6px 8px; border: 1px solid var(--line, #2a2f36); border-radius: 6px; font-size: 12px; }
      #labAudio .top { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
      #labAudio .top input[type=range] { width: 140px; }
      #labAudio .cue { display: flex; gap: 8px; align-items: center; margin: 3px 0; }
      #labAudio .cue .name { min-width: 112px; color: var(--dim, #8a919a); }
      #labAudio .cue { flex-wrap: wrap; }
      #labAudio .cue label { display: inline-flex; gap: 2px; align-items: center; cursor: pointer; }
      #labAudio .cue button { font-size: 10px; padding: 0 4px; margin-right: 6px; cursor: pointer; }
      #labAudio .status { color: var(--dim, #8a919a); }
    `;
    document.head.appendChild(css);
    const root = document.createElement("div");
    root.id = "labAudio";
    root.innerHTML = `<div class="top"><b>소리</b>
      <label>볼륨 <input type="range" id="laVol" min="0" max="1" step="0.01"> <span id="laVolV"></span></label>
      <label><input type="checkbox" id="laLine"> 자막도 같은 소리 (−6 dB, 유지는 제외)</label>
      <span class="status" id="laStatus"></span></div><div id="laCues"></div>`;
    const stage = document.querySelector(".stage") || document.body;
    stage.appendChild(root);
    const $ = id => root.querySelector("#" + id);
    const vol = $("laVol"), volV = $("laVolV"), line = $("laLine"), cues = $("laCues"), status = $("laStatus");
    vol.value = state.master; volV.textContent = Math.round(state.master * 100) + "%";
    line.checked = state.lineToo;
    vol.addEventListener("input", () => { state.master = Number(vol.value); volV.textContent = Math.round(state.master * 100) + "%"; if (master) master.gain.value = state.master; for (const v of voices) if (fromFile) v.voice.gain(v.nominal); save(); });
    line.addEventListener("change", () => { state.lineToo = line.checked; needSeek = true; save(); });
    let shown = null;
    function show(style) {
      shown = style;
      cues.innerHTML = "";
      if (style === "type") { cues.innerHTML = '<div class="status">글자마다 키보드 녹음 (사운드랩의 kit.terminal), 줄 바꿈과 종이 올라갈 때마다 엔터</div>'; return; }
      if (!style) { cues.innerHTML = '<div class="status">이 스타일에는 소리 후보가 없습니다 (스타일 목록의 "…: 이름" 항목이나 dust, brief에 있습니다).</div>'; return; }
      for (const cue of CUES[style]) {
        const id = style + ":" + cue[0];
        const opts = [["none", "없음"]];
        // (the user's pick (title_picks.json) and its refinements (<pick>_r<n>) read as such; fresh candidates by number)
        const list = candidatesOf(style, cue), picked = PICKED[id], stem = picked ? picked.slice(0, -4) + "_r" : null;
        list.forEach((f, i) => {
          const r = stem && f.startsWith(stem) ? f.slice(stem.length).match(/^(\d+)\.ogg$/) : null;
          opts.push([f, f === picked ? "선택" : r ? "다듬음 " + r[1] : String(+((f.match(/_(\d+)\.ogg$/) || [0, i + 1])[1]))]);
        });
        if (NOW[id]) opts.push(["now", hasCandidates(style, cue) ? "지금 게임" : "지금"]);
        const row = document.createElement("div");
        row.className = "cue";
        row.innerHTML = `<span class="name">${cue[1]}</span>`;
        const cur = chosen(style, cue);
        for (const [val, label] of opts) {
          const l = document.createElement("label");
          l.innerHTML = `<input type="radio" name="la_${id}" value="${val}"${cur === val ? " checked" : ""}> ${label}`;
          l.firstChild.addEventListener("change", () => { state.picks[id] = val; needSeek = true; save(); });
          row.appendChild(l);
          const url = fileOf(style, cue, val);
          if (url) {
            const b = document.createElement("button");
            b.textContent = "▶"; b.title = "이것만 들어 보기";
            b.addEventListener("click", (e) => { e.preventDefault(); solo(url); });
            row.appendChild(b);
          }
        }
        cues.appendChild(row);
      }
    }
    function setStatus(text) { status.textContent = text; }
    return { show, setStatus };
  })();

  // One candidate played alone, from its start (a button beside it): the one before stops.
  let soloVoice = null;
  function solo(url) {
    unlock();
    if (soloVoice) { soloVoice.stop(0.03); soloVoice = null; }
    const entry = load(url);
    const go = () => {
      if (!(fromFile ? entry.duration > 0 : entry.buf)) return setTimeout(go, 50);
      if (!fromFile && ctx.state === "suspended") ctx.resume().catch(() => { });
      soloVoice = makeVoice(entry, false); soloVoice.gain(1); soloVoice.start(0);
    };
    go();
  }

  // The candidates' list (gen/manifest.js sets window.TITLE_SOUND_CANDIDATES): a script, so that the lab opened from a file reads it too.
  (function loadManifest() {
    const el = document.createElement("script");
    el.src = GEN + "manifest.js?" + Date.now();
    el.onload = () => { MADE = window.TITLE_SOUND_CANDIDATES || {}; PICKED = window.TITLE_SOUND_PICKS || {}; needSeek = true; panel.show(STYLE_OF[curStyle] || null); preload(STYLE_OF[curStyle]); };
    el.onerror = () => panel.setStatus("후보 목록(mods/tools/sound/gen/manifest.js)이 없습니다: ai_titles.py로 만드세요");
    document.head.appendChild(el);
  })();

  // The browser starts sound only after a click or a key: the first one unlocks it.
  function unlock() {
    if (unlocked) return;
    unlocked = true;
    if (ctx) ctx.resume().catch(() => { });
    needSeek = true;
    updateStatus();
  }
  for (const kind of ["pointerdown", "keydown", "click"]) document.addEventListener(kind, unlock, { capture: true });
  function updateStatus() {
    panel.setStatus(!fromFile && !ctx ? "이 브라우저에는 WebAudio가 없습니다" : unlocked ? (fromFile ? "(파일로 열림: <audio>로 재생. 반복 이음새에 틈이 있을 수 있음. 서버로 열면 끊김 없는 반복)" : "") : "페이지를 한 번 클릭하면 소리가 켜집니다");
  }
  updateStatus();

  // (what is going on inside, for looking at from the console)
  const debug = () => ({ ctx: ctx && ctx.state, unlocked, prevT, wasLive, needSeek, curStyle, rate, lastLiveT, failed,
    loaded: [...buffers.values()].filter(e => e.buf || e.duration).length, files: buffers.size });
  window.LabAudio = { frame, log, state, voices, CUES, STYLE_OF, planOf, debug, stopAll: () => stopAll(0.03) };
})();
