"use strict";
// The sound lab: plays every cue of the mods the way the game does (SOUND-SYSTEM.md S5), from manifest.js (lab.py).
// Our sounds are played from their built clips (a random clip each time, at the script's volume and pitch); the game's own
// sounds are inside its FMOD banks and cannot be played here. Candidates (tools/sound/candidates/) are played in the same
// ways, and the choice and the notes are kept in localStorage and can be exported.
(function () {
  const D = window.SOUNDLAB;
  const $ = (id) => document.getElementById(id);
  const GROUPS = [["ui", "UI"], ["comms", "교신, 서류"], ["actions", "액션"], ["world", "월드"]];
  const STORE = "soundlab.v1";
  const TEXT = "현장 승인 권한 밖의 사안입니다. 이상.\nCopy that, moving out.";
  const FADE = 0.04;      // seconds: a sound cut at the end of an action fades this fast
  const GOLDEN = 0.6180339887;

  // ------------------------------------------------------------------------------------------------ state
  let state = { picks: {}, notes: {}, params: {}, shared: { text: TEXT, cps: 14, eraseN: 10, eraseCps: 10 }, vol: 1 };
  try { Object.assign(state, JSON.parse(localStorage.getItem(STORE) || "{}")); } catch (e) { /* private window: no memory */ }
  state.shared = Object.assign({ text: TEXT, cps: 14, eraseN: 10, eraseCps: 10 }, state.shared);
  function save() { try { localStorage.setItem(STORE, JSON.stringify(state)); } catch (e) { /* ignore */ } }

  // ------------------------------------------------------------------------------------------------ audio
  let ctx = null, master = null;
  const buffers = new Map();
  const live = new Set();
  function audio() {
    if (!ctx) {
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      master = ctx.createGain();
      master.gain.value = state.vol;
      master.connect(ctx.destination);
    }
    if (ctx.state === "suspended") ctx.resume();
    return ctx;
  }
  function load(url) {
    if (!buffers.has(url)) {
      buffers.set(url, fetch(url).then((r) => {
        if (!r.ok) throw new Error(url + " " + r.status);
        return r.arrayBuffer();
      }).then((b) => audio().decodeAudioData(b)));
    }
    return buffers.get(url);
  }
  // A voice: a buffer started at time `at` (loop: until stopped), at a volume and pitch, optionally cut at `until`.
  function voice(buffer, at, o) {
    const c = audio();
    const src = c.createBufferSource(), g = c.createGain();
    src.buffer = buffer;
    src.playbackRate.value = o.pitch || 1;
    src.loop = !!o.loop;
    g.gain.value = o.volume == null ? 1 : o.volume;
    src.connect(g);
    g.connect(master);
    src.start(at);
    const v = {
      src, g, stopped: false,
      stop(fade) {
        if (v.stopped) return;
        v.stopped = true;
        const now = Math.max(c.currentTime, at), f = fade == null ? 0.02 : fade;
        g.gain.cancelScheduledValues(now);
        g.gain.setValueAtTime(g.gain.value, now);
        g.gain.linearRampToValueAtTime(0, now + f);
        try { src.stop(now + f + 0.01); } catch (e) { /* not started */ }
      },
    };
    if (o.until != null) {
      const end = Math.max(o.until, at + FADE);
      g.gain.setValueAtTime(o.volume == null ? 1 : o.volume, end - FADE);
      g.gain.linearRampToValueAtTime(0, end);
      try { src.stop(end + 0.01); } catch (e) { /* ignore */ }
    }
    live.add(v);
    src.onended = () => live.delete(v);
    return v;
  }
  function stopEverything() {
    runs.forEach((run) => run.stop());
    live.forEach((v) => v.stop(0.02));
  }

  // ------------------------------------------------------------------------------------------------ the game's rules
  // PZUIKit.Sound.keyOf, exactly: the key's sound of a character (the golden ratio's fractional part spreads the codes
  // evenly; string.byte of a one-character string is its code, as ord() is for preview.py).
  function keyOf(board, ch, erase) {
    const L = board.letters;
    if (erase) return board.back || L[0];
    if (ch === " ") return board.space || L[0];
    if (ch === "\n") return board.enter || L[0];
    const code = ch && ch !== "" ? ch.charCodeAt(0) : 0;
    const spread = code * GOLDEN;
    return L[Math.floor((spread - Math.floor(spread)) * L.length)];
  }
  const sounds = D.sounds;
  const boards = {};
  D.keyboards.forEach((b) => { boards[b.id] = b; });
  const pick = (a) => a[Math.floor(Math.random() * a.length)];

  // ------------------------------------------------------------------------------------------------ sources
  // A source is { clips: [{ url, volume, pitch }], loop }: our sound as the script has it, or a candidate.
  function ourSource(name) {
    const s = sounds[name];
    if (!s) return null;
    return { name, loop: s.loop, clips: s.clips.filter((c) => c.exists).map((c) => ({ url: c.url, volume: c.volume, pitch: c.pitch })) };
  }
  function candidateSource(c, loop) {
    return { name: c.label, loop, clips: c.clips.map((x) => ({ url: x.url, volume: 1, pitch: 1 })) };
  }
  function db(x) { return (Math.round(x * 10) / 10).toFixed(1); }
  function levelText(clips, volume) {
    const ok = clips.filter((c) => c.peak != null);
    if (!ok.length) return "";
    const g = volume ? 20 * Math.log10(volume) : 0;
    const peak = Math.max(...ok.map((c) => c.peak + g)), loud = Math.max(...ok.map((c) => c.loud50 + g));
    const durs = ok.map((c) => c.dur);
    return "길이 " + Math.min(...durs).toFixed(2) + (Math.max(...durs) - Math.min(...durs) > 0.005 ? "~" + Math.max(...durs).toFixed(2) : "") +
      " s, 피크 " + db(peak) + ", 50 ms " + db(loud) + " dBFS";
  }

  // ------------------------------------------------------------------------------------------------ playing
  const runs = new Map();   // a row's key -> the run now sounding { stop }
  const last = {};          // the last run of each row, for the page's self-checks: { plays: [{ t, name }] }

  async function prime(source) {
    return Promise.all(source.clips.map((c) => load(c.url).then((b) => { c.buffer = b; })));
  }
  function clipVoice(source, at, o) {
    const clip = pick(source.clips);
    return voice(clip.buffer, at, Object.assign({ volume: clip.volume, pitch: clip.pitch }, o));
  }

  // The ways to play: each schedules everything at once on the audio clock and returns { voices, dur, timers }.
  const PLAYERS = {
    once(source, p, cue, rec) {
      const t0 = audio().currentTime + 0.03;
      rec.plays.push({ t: 0, name: source.name });
      const v = clipVoice(source, t0, {});
      return { voices: [v], dur: v.src.buffer.duration / (v.src.playbackRate.value || 1) };
    },
    burst(source, p, cue, rec) {
      const t0 = audio().currentTime + 0.03, gap = Math.max(p.ms, 5) / 1000, voices = [];
      for (let i = 0; i < p.n; i++) {
        voices.push(clipVoice(source, t0 + i * gap, {}));
        rec.plays.push({ t: i * gap, name: source.name });
      }
      return { voices, dur: p.n * gap + 0.5 };
    },
    // A timed action's sound while it works (Sound.timed's `during`): a looped sound runs the action's length and is
    // stopped as the game stops it; one that is not looped sounds once, cut at the end if still going.
    during(source, p, cue, rec) {
      const t0 = audio().currentTime + 0.03;
      rec.plays.push({ t: 0, name: source.name, loop: p.loop });
      const v = clipVoice(source, t0, { loop: p.loop, until: t0 + p.len });
      return { voices: [v], dur: p.len + 0.1 };
    },
    // A print row: one row's sound a line.
    rows(source, p, cue, rec) {
      const t0 = audio().currentTime + 0.03, voices = [];
      for (let i = 0; i < p.lines; i++) {
        voices.push(clipVoice(source, t0 + i * p.lineGap, {}));
        rec.plays.push({ t: i * p.lineGap, name: source.name });
      }
      return { voices, dur: p.lines * p.lineGap + 0.5 };
    },
    // Typing (preview.py --keyboard): a character every 1/cps s (a little uneven, a pause at a new line), none sounding within the
    // cue's gap of the one before (Sound.name's gap), then the erasing key taking `eraseN` away at an even pace.
    type(source, p, cue, rec) {
      return typing(source, p, cue, rec, true);
    },
    erase(source, p, cue, rec) {
      return typing(source, p, cue, rec, false);
    },
  };

  function typing(source, p, cue, rec, withText) {
    const c = audio(), t0 = c.currentTime + 0.05, voices = [], timers = [];
    const board = cue.keyboard ? boards[cue.keyboard] : null;
    const gap = cue.gap || 0;
    let t = 0, lastAt = null, typed = "";
    const play = (at, name) => {
      const clips = source.board ? source.board[name] : source.clips;
      const clip = pick(clips);
      voices.push(voice(clip.buffer, t0 + at, { volume: clip.volume, pitch: clip.pitch }));
      rec.plays.push({ t: at, name: name || source.name });
    };
    const show = (at, text) => timers.push(setTimeout(() => { p.out.textContent = text; }, at * 1000));
    if (withText) {
      for (const ch of Array.from(p.text)) {
        if (lastAt === null || (t - lastAt) * 1000 >= gap) {
          play(t, board ? keyOf(board, ch, false) : null);
          lastAt = t;
        }
        typed += ch;
        show(t, typed);
        t += (1 / p.cps) * (0.75 + Math.random() * 0.55) + (ch === "\n" ? 0.25 : 0);
      }
      t += 0.8;
    }
    lastAt = null;
    let left = typed;
    for (let i = 0; i < p.eraseN; i++) {
      if (lastAt === null || (t - lastAt) * 1000 >= gap) {
        play(t, board ? keyOf(board, null, true) : null);
        lastAt = t;
      }
      left = Array.from(left).slice(0, -1).join("");
      if (withText) show(t, left);
      t += 1 / p.eraseCps;
    }
    return { voices, dur: t + 0.5, timers };
  }

  // Plays a source in a way; the row's run is the one thing sounding for that row.
  async function play(key, btn, cue, source, method, p) {
    const was = runs.get(key);
    if (was) {
      was.stop();
      if (was.btn === btn) return;
    }
    audio();
    btn.disabled = true;
    try {
      if (source.board) {
        await Promise.all(Object.values(source.board).flat().map((c) => load(c.url).then((b) => { c.buffer = b; })));
      } else {
        await prime(source);
      }
    } catch (e) {
      btn.disabled = false;
      btn.title = "불러오지 못했습니다: " + e.message;
      btn.textContent = "!";
      return;
    }
    btn.disabled = false;
    const rec = { cue: cue.id, method, source: source.name, plays: [] };
    last[key] = rec;
    last.latest = rec;
    const r = PLAYERS[method](source, p, cue, rec);
    const run = {
      btn,
      stop() {
        r.voices.forEach((v) => v.stop(0.03));
        (r.timers || []).forEach(clearTimeout);
        clearTimeout(run.end);
        btn.textContent = btn.dataset.label;
        runs.delete(key);
      },
    };
    run.end = setTimeout(() => run.stop(), r.dur * 1000 + 100);
    btn.textContent = "■";
    runs.set(key, run);
  }

  // ------------------------------------------------------------------------------------------------ the page
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const k in attrs || {}) {
      if (k === "class") el.className = attrs[k];
      else if (k === "text") el.textContent = attrs[k];
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), attrs[k]);
      else if (attrs[k] !== false && attrs[k] != null) el.setAttribute(k, attrs[k] === true ? "" : attrs[k]);
    }
    kids.flat().forEach((c) => { if (c != null) el.append(c.nodeType ? c : document.createTextNode(c)); });
    return el;
  }
  function shortWhere(w) { return w.replace(/^.*\//, ""); }
  const HOW = { ui: "화면", at: "칸", on: "캐릭터", loop: "반복", name: "이름으로", sync: "서버에서", typed: "타이핑", timed: "액션", ref: "표" };

  // The ways a cue can be played, from what the code says about it.
  function methodsOf(cue, hasLoop) {
    if (cue.keyboard) return cue.erase ? ["erase"] : ["type"];
    const m = ["once"];
    if (cue.gap) m.push("burst");
    if (cue.timed.some((t) => t.mode === "during") || hasLoop) m.push("during");
    if (cue.id.split(".").pop() === "row") m.push("rows");
    return m;
  }
  const METHOD_LABEL = { once: "한 번", burst: "연타", during: "액션 중", rows: "줄 출력", type: "타이핑", erase: "지우기" };

  function paramsOf(cue, hasLoop) {
    const saved = state.params[cue.id] || {};
    const methods = methodsOf(cue, hasLoop);
    const first = cue.keyboard ? methods[0] : cue.timed.some((t) => t.mode === "during") ? "during" : methods.includes("rows") ? "rows" : "once";
    const p = Object.assign({ method: first, n: 8, ms: cue.gap || 40, len: 4, loop: hasLoop, lines: 4, lineGap: 0.5 }, saved);
    if (!methods.includes(p.method)) p.method = first;
    state.params[cue.id] = p;
    return p;
  }

  function num(p, key, min, step, onchange) {
    return h("input", { type: "number", min, step: step || 1, value: p[key], onchange: (e) => {
      const v = parseFloat(e.target.value);
      if (!isNaN(v)) { p[key] = v; save(); if (onchange) onchange(); }
    } });
  }

  function cueRow(cue) {
    const board = cue.keyboard ? boards[cue.keyboard] : null;
    const current = board ? boardSource(board) : cue.sound && sounds[cue.sound] ? ourSource(cue.sound) : null;
    const vanilla = cue.sound && !sounds[cue.sound];
    const hasLoop = !!(current && current.loop);
    const p = paramsOf(cue, hasLoop);
    const row = h("div", { class: "cue", id: "cue-" + cue.id });
    row.dataset.find = [cue.id, cue.sound, cue.keyboard, cue.desc, cue.comment, cue.group].join(" ").toLowerCase();
    row.dataset.vanilla = vanilla && !cue.candidates.length && !cue.recording ? "1" : "";

    const badge = board || (cue.sound && !vanilla) ? h("span", { class: "badge ours", text: "우리 소리" })
      : vanilla ? h("span", { class: "badge vanilla", text: "바닐라 (게임에서만)" })
      : h("span", { class: "badge silent", text: "무음" });
    row.append(h("div", { class: "head" }, h("code", { class: "id", text: cue.id }), badge,
      h("span", { class: "dim", title: cue.file + ":" + cue.line, text: shortWhere(cue.file) + ":" + cue.line }),
      cue.gap ? h("span", { class: "dim", text: "gap " + cue.gap + " ms" }) : null,
      Object.keys(cue.extra).map((k) => h("span", { class: "dim", text: k + " = " + cue.extra[k] }))));

    const desc = h("div", { class: "desc" }, cue.desc || h("span", { class: "dim", text: cue.comment ? "(코드 주석) " + cue.comment : "(설명 없음)" }));
    if (cue.memo && !["바닐라", "녹음"].includes(cue.memo)) desc.append(" ", h("span", { class: "dim", text: "메모: " + cue.memo }));
    row.append(desc);

    // where the code asks for it
    const during = cue.timed.filter((t) => t.mode === "during"), done = cue.timed.filter((t) => t.mode === "done");
    const cls = (t) => t.cls + (t.cond ? " (조건부)" : "");
    if (cue.timed.length) {
      row.append(h("div", { class: "dim" },
        during.length ? "액션 중 (반복): " + during.map(cls).join(", ") : null, during.length && done.length ? " / " : null,
        done.length ? "액션 끝 (한 번): " + done.map(cls).join(", ") : null));
    }
    if (cue.uses.length) {
      row.append(h("details", { class: "uses" }, h("summary", { text: "쓰는 곳 " + cue.nUses + "곳" }),
        h("div", { class: "dim mono" }, cue.uses.map((u) => h("div", { text: u.where + "  (" + (HOW[u.how] || u.how) + ")" })),
          cue.nUses > cue.uses.length ? h("div", { text: "…" }) : null)));
    }

    // the sources: what it is now, and the candidates
    const sources = [];
    if (current) sources.push({ id: "current", label: "현재: " + (board ? "키보드 " + board.id : cue.sound), source: current, info: board ? boardInfo(board) : sounds[cue.sound] });
    else if (vanilla) sources.push({ id: "current", label: "현재: " + cue.sound + " (바닐라)", source: null });
    else sources.push({ id: "current", label: "현재: 무음", source: null });
    cue.candidates.forEach((c) => sources.push({ id: c.id, label: "후보 " + c.label + (c.folder !== cue.id ? "  [" + c.folder + "]" : ""), source: candidateSource(c, hasLoop), cand: c }));
    const canPlay = sources.some((s) => s.source);
    const methods = canPlay ? methodsOf(cue, hasLoop) : [];

    // how to play, with its settings
    const out = h("div", { class: "typed" });
    const paramBox = h("div", { class: "params" });
    const methodBar = h("div", { class: "methods" });
    function paramFields() {
      paramBox.replaceChildren();
      const m = p.method, s = state.shared;
      if (m === "burst") paramBox.append("횟수", num(p, "n", 1), "간격 ms", num(p, "ms", 5), h("span", { class: "dim", text: "(큐의 gap " + cue.gap + " ms부터)" }));
      if (m === "during") {
        paramBox.append("액션 길이 s", num(p, "len", 0.5, 0.5), h("label", {}, h("input", { type: "checkbox", checked: p.loop, onchange: (e) => { p.loop = e.target.checked; save(); } }), " 소리를 반복"));
        paramBox.append(h("span", { class: "dim", text: hasLoop ? "(스크립트 loop = true: 게임도 반복합니다)" : "(반복이 아니면 한 번 울리고 길이에서 자릅니다)" }));
      }
      if (m === "rows") paramBox.append("줄 수", num(p, "lines", 1), "줄 간격 s", num(p, "lineGap", 0.1, 0.1));
      if (m === "type") {
        const ta = h("textarea", { rows: 2, class: "shared-text", oninput: (e) => { s.text = e.target.value; save(); document.querySelectorAll(".shared-text").forEach((x) => { if (x !== e.target) x.value = s.text; }); } });
        ta.value = s.text;
        paramBox.append(h("div", { style: "flex-basis:100%" }, ta));
      }
      if (m === "type") paramBox.append("초당 글자", sharedNum("cps", 1, 1));
      if (m === "type" || m === "erase") paramBox.append("지우기 개수", sharedNum("eraseN", 0, 1), "지우기 초당", sharedNum("eraseCps", 1, 1));
      if (m === "type" || m === "erase") paramBox.append(h("span", { class: "dim", text: "gap " + (cue.gap || 0) + " ms 안의 글자는 소리 없음" }));
      if (m === "type" || m === "erase") paramBox.append(out);
    }
    function sharedNum(key, min, step) {
      return h("input", { type: "number", min, step, value: state.shared[key], onchange: (e) => {
        const v = parseFloat(e.target.value);
        if (!isNaN(v)) { state.shared[key] = v; save(); }
      } });
    }
    function methodButtons() {
      methodBar.replaceChildren();
      if (methods.length < 2) return;
      methodBar.append(h("span", { class: "dim", text: "재생 방식" }));
      methods.forEach((m) => methodBar.append(h("button", { class: m === p.method ? "on" : "", text: METHOD_LABEL[m], onclick: () => { p.method = m; save(); methodButtons(); paramFields(); } })));
    }
    if (methods.length) { methodButtons(); paramFields(); row.append(methodBar, paramBox); }

    const chosen = state.picks[cue.id] && sources.some((s) => s.id === state.picks[cue.id]) ? state.picks[cue.id] : "current";
    const radioName = "pick-" + cue.id;
    sources.forEach((s) => {
      const line = h("div", { class: "src" + (sources.length > 1 && s.id === chosen ? " picked" : "") });
      if (sources.length > 1) {
        line.append(h("label", {}, h("input", { type: "radio", name: radioName, checked: s.id === chosen, onchange: () => {
          state.picks[cue.id] = s.id;
          save();
          row.querySelectorAll(".src").forEach((x) => x.classList.remove("picked"));
          line.classList.add("picked");
        } }), s.label));
      } else {
        line.append(h("span", { text: s.label }));
      }
      if (s.source) {
        const btn = h("button", { class: "play", text: "▶", title: "이 소리를 위의 방식으로 재생" });
        btn.dataset.label = "▶";
        btn.addEventListener("click", () => play(cue.id, btn, cue, s.source, p.method, Object.assign({}, p, state.shared, { out })));
        line.append(btn);
      }
      if (s.info && s.id === "current") line.append(h("span", { class: "dim", text: infoText(s.info, board) }));
      if (s.cand) line.append(h("span", { class: "dim", text: levelText(s.cand.clips) }));
      row.append(line);
    });
    if (vanilla) {
      const line = h("div", { class: "src" });
      if (cue.recording) {
        const btn = h("button", { class: "play", text: "▶", title: "게임에서 녹음한 소리" });
        btn.dataset.label = "▶";
        const rec = { clips: [{ url: cue.recording, volume: 1, pitch: 1 }], name: cue.sound + " (게임 녹음)" };
        btn.addEventListener("click", () => play("rec-" + cue.id, btn, cue, rec, "once", {}));
        line.append(h("span", { text: "게임 녹음 (" + (cue.recordingKind === "ref" ? "기준" : "액션 중 3 s") + "): " + cue.sound }), btn);
      } else {
        line.append(h("span", { class: "dim", text: "소리는 게임의 FMOD 뱅크 안에 있어 여기서는 재생할 수 없습니다." }));
      }
      row.append(line);
    }

    // notes
    const ta = h("textarea", { placeholder: "메모", oninput: (e) => { state.notes[cue.id] = e.target.value; save(); } });
    ta.value = state.notes[cue.id] || "";
    row.append(h("div", { class: "note" }, ta));
    return row;
  }

  function boardSource(board) {
    const names = new Set([...board.letters, board.space, board.enter, board.back].filter(Boolean));
    const map = {};
    names.forEach((n) => { const s = ourSource(n); if (s) map[n] = s.clips; });
    const first = map[board.letters[0]];
    return { name: "키보드 " + board.id, board: map, clips: first || [], loop: false };
  }
  function boardInfo(board) {
    const names = [...board.letters, board.space, board.enter, board.back].filter(Boolean);
    return { board: true, names };
  }
  function infoText(info, board) {
    if (info.board) return info.names.length + "개 키 (" + info.names[0] + " … " + info.names[info.names.length - 1] + ")";
    const v = Math.max(...info.clips.map((c) => c.volume));
    return info.clips.length + "클립, 볼륨 " + v + ", " + (info.loop ? "loop, " : "") + levelText(info.clips, v) +
      (info.peakTarget != null ? " (목표 피크 " + info.peakTarget + ")" : "");
  }

  function build() {
    $("gen").textContent = "manifest " + D.generated + " · 큐 " + D.cues.length + "개";
    $("titleLab").href = D.titleLab;
    $("titleLab").textContent = "제목 소리 " + D.titleCues + "개는 타이틀랩에서";
    const refs = $("refs");
    D.refs.forEach((r) => {
      const btn = h("button", { class: "play", text: "▶" });
      btn.dataset.label = "▶";
      btn.addEventListener("click", () => play("ref-" + r.name, btn, { id: r.name }, { clips: [{ url: r.url, volume: 1, pitch: 1 }], name: r.name }, "once", {}));
      refs.append(h("span", {}, btn, " ", r.name.startsWith("UI") ? "바닐라 UI 클릭 기준 " : "바닐라 ", h("code", { text: r.name }), h("span", { class: "dim", text: "  " + db(r.peak) + " / " + db(r.loud50) })));
    });
    if (!D.refs.length) $("refsBox").classList.add("hidden");

    const root = $("root");
    D.mods.forEach((mod) => {
      const ofMod = D.cues.filter((c) => c.mod === mod);
      if (!ofMod.length) return;
      root.append(h("h2", { text: mod + " (" + ofMod.length + ")" }));
      GROUPS.forEach(([g, label]) => {
        const rows = ofMod.filter((c) => c.group === g);
        if (!rows.length) return;
        const box = h("details", { class: "group", open: true }, h("summary", { text: label + " (" + rows.length + ")" }));
        rows.forEach((c) => box.append(cueRow(c)));
        root.append(box);
      });
    });
    if (D.extraCandidates.length) {
      root.append(h("h2", { text: "큐 없는 후보 폴더" }));
      D.extraCandidates.forEach((e) => {
        const cue = { id: "candidates:" + e.folder, file: "candidates/" + e.folder, line: 0, sound: null, keyboard: null, gap: null, extra: {}, desc: "이 이름의 큐나 소리는 아직 없습니다.",
          comment: "", uses: [], nUses: 0, timed: [], candidates: e.candidates, group: "world", recording: null };
        root.append(cueRow(cue));
      });
    }
    const foot = $("foot");
    if (D.problems.length) {
      foot.append(h("div", { class: "problems", text: "읽지 못한 것 " + D.problems.length + "건" }), D.problems.map((x) => h("div", { class: "mono", text: x })));
    }
  }

  // ------------------------------------------------------------------------------------------------ controls
  function exported() {
    const out = {};
    const ids = new Set([...Object.keys(state.picks), ...Object.keys(state.notes)]);
    const all = D.cues.concat(D.extraCandidates.map((e) => ({ id: "candidates:" + e.folder, sound: null, candidates: e.candidates })));
    ids.forEach((id) => {
      const cue = all.find((c) => c.id === id);
      if (!cue) return;
      const picked = state.picks[id] && cue.candidates.some((c) => c.id === state.picks[id]) ? state.picks[id] : "current";
      const note = (state.notes[id] || "").trim();
      if (picked === "current" && !note) return;
      const entry = { pick: picked === "current" ? "현재 소리 유지" : "후보 " + picked };
      if (cue.sound) entry.sound = cue.sound;
      if (note) entry.note = note;
      out[id] = entry;
    });
    return { sound_lab: 1, picks: out };
  }

  $("vol").addEventListener("input", (e) => { state.vol = parseFloat(e.target.value); if (master) master.gain.value = state.vol; save(); });
  $("vol").value = state.vol;
  $("stopAll").addEventListener("click", stopEverything);
  $("export").addEventListener("click", () => {
    const box = $("exportBox");
    box.style.display = box.style.display === "block" ? "none" : "block";
    $("exportText").value = JSON.stringify(exported(), null, 2);
  });
  $("copy").addEventListener("click", async () => {
    const t = $("exportText");
    t.value = JSON.stringify(exported(), null, 2);
    try { await navigator.clipboard.writeText(t.value); } catch (e) { t.select(); document.execCommand("copy"); }
    $("copied").textContent = "복사했습니다";
    setTimeout(() => { $("copied").textContent = ""; }, 2000);
  });
  function refilter() {
    const q = $("find").value.trim().toLowerCase(), hideVanilla = !$("showVanilla").checked;
    document.querySelectorAll(".cue").forEach((row) => {
      const hide = (q && !row.dataset.find.includes(q)) || (hideVanilla && row.dataset.vanilla);
      row.classList.toggle("hidden", !!hide);
    });
    document.querySelectorAll("details.group").forEach((d) => {
      if (d.id === "refsBox") return;
      d.classList.toggle("hidden", !d.querySelector(".cue:not(.hidden)"));
    });
  }
  $("find").addEventListener("input", refilter);
  $("showVanilla").addEventListener("change", refilter);

  build();
  window.SoundLab = { state, keyOf, runs, last, exported, play, prime, load, stopEverything, data: D };
}());
