"""시간 구간 확인 페이지를 만든다: eval_data/event_review.html (로컬 전용, 썸네일은 phone/thumbs/ 를 상대 경로로 읽음).

사용: uv run event_review.py   (먼저 time_events.py, phone_bench.py thumbs)
페이지에서 표시하는 것:
  - 구간 사이 "↑ 앞 구간과 같은 일"  → 경계가 잘못 잘렸다 (너무 잘게 나눔)
  - 구간 안 "여러 일이 섞임"         → 경계가 빠졌다 (너무 크게 묶음)
  - 사진을 눌러 고른 뒤 같은 버튼    → 고른 사진만 앞(↑)·뒤(↓) 구간으로 옮긴다 (경계 위치가 틀림)
아무것도 안 누른 구간은 맞은 것으로 본다. 결과는 event_review.json 으로 저장해 time_events.py 규칙을 고치는 데 쓴다.
"""
import json
from datetime import datetime
from pathlib import Path

EVAL = Path(__file__).parent.parent / "eval_data"

PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>구간 확인</title>
<style>
:root{--bg:#f6f7f5;--card:#fff;--ink:#1d2320;--sub:#66706b;--line:#dde2de;--accent:#0b6b5c;--warn:#b4441c;--sel:#1a73e8}
@media (prefers-color-scheme:dark){:root{--bg:#141816;--card:#1d2320;--ink:#e6ebe8;--sub:#9aa5a0;--line:#2f3833;--accent:#5cc7b2;--warn:#f0956f;--sel:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
header b{margin-right:auto}button,select{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:1100px;margin:0 auto;padding:12px 16px 80px}.help{color:var(--sub);font-size:14px;margin:4px 0 12px}
h2{font-size:16px;margin:22px 0 6px;color:var(--sub)}
.ev{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}.ev.mixed{border-color:var(--warn);border-width:2px}
.meta{display:flex;gap:8px;flex-wrap:wrap;align-items:center;font-size:14px;color:var(--sub)}.meta .t{color:var(--ink);font-weight:600}
.meta .sp{margin-left:auto}.strip{display:flex;gap:4px;flex-wrap:wrap;margin-top:8px}.strip img{width:96px;height:96px;object-fit:cover;border-radius:6px;background:var(--line)}
.gap{display:flex;align-items:center;gap:8px;margin:6px 0 6px 10px;font-size:13px;color:var(--sub)}
.gap label{display:flex;gap:6px;align-items:center;cursor:pointer;padding:3px 8px;border-radius:6px;border:1px dashed var(--line)}
.gap button{font-size:13px;padding:3px 10px;border-style:dashed}
.gap.merged button{border-style:solid;border-color:var(--accent);color:var(--accent);font-weight:600}
.gap button.move{border-style:solid;background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
.strip img{cursor:pointer;border:3px solid transparent}.strip img.sel{border-color:var(--sel)}
.strip img.moved{outline:2px dashed var(--accent);outline-offset:-5px}.empty{color:var(--sub);font-size:13px}
.meta button.all{font-size:13px;padding:2px 10px}
.count{font-variant-numeric:tabular-nums}
#bar{position:fixed;left:0;right:0;bottom:0;z-index:3;background:var(--card);border-top:2px solid var(--sel);
  padding:10px 16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;font-size:14px}#bar[hidden]{display:none}
@media (max-width:600px){.strip img{width:72px;height:72px}}
</style></head><body>
<header><b>시간 구간 확인</b><select id="year"></select><span class="count" id="stat"></span>
<button id="reset">처음부터 다시</button><button class="primary" id="save">결과 저장</button></header>
<main><p class="help">기억과 다르게 나뉜 곳만 고쳐 주세요. 구간 사이 <b>↑ 앞 구간과 같은 일</b>: 한 번의 일이 둘로 쪼개졌을 때.
구간 안 <b>여러 일이 섞임</b>: 서로 다른 일이 한 구간에 묶였을 때. 경계가 몇 장 어긋났으면 사진을 눌러 고른 뒤(Shift로 범위, 전체 선택으로 구간 전체)
구간 사이 버튼으로 앞·뒤 구간에 옮기세요. 아무것도 안 누른 구간은 맞은 것으로 봅니다. 작업은 이 브라우저에 자동 저장됩니다.</p>
<div id="list"></div></main>
<div id="bar" hidden><b id="selcount"></b><span>구간 사이 버튼을 누르면 앞·뒤 구간으로 옮겨집니다</span>
<button id="clear">선택 해제 (Esc)</button></div>
<script>
const EVENTS = __EVENTS__;
const KEY = "photo_tracer_event_review_v1";
let st = {merge: {}, mixed: {}, move: {}};
try { st = JSON.parse(localStorage.getItem(KEY)) || st; } catch (e) {}
st.move = st.move || {};  // 사진 ID → 옮겨 간 구간 번호 (원래 구간이면 지운다)
const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} stat(); };
const PHOTO = {};  // 사진 ID → {home: 원래 구간, t: 촬영 시각}
EVENTS.forEach(e => e.ids.forEach((id, k) => PHOTO[id] = {home: e.event, t: e.ts[k]}));
const owner = id => st.move[id] ?? PHOTO[id].home;
const sel = new Set();
let selEvent = null, lastClick = null;
const years = [...new Set(EVENTS.map(e => e.start.slice(0, 4)))];
const ysel = document.getElementById("year");
ysel.innerHTML = years.map(y => `<option>${y}</option>`).join("");
ysel.value = years[years.length - 1];
function fmtGap(min) { return min < 60 ? `${Math.round(min)}분` : min < 1440 ? `${(min / 60).toFixed(1)}시간` : `${(min / 1440).toFixed(1)}일`; }
function stat() {
  const m = Object.values(st.merge).filter(Boolean).length, x = Object.values(st.mixed).filter(Boolean).length;
  document.getElementById("stat").textContent = `구간 ${EVENTS.length}개 · 합치기 ${m} · 섞임 ${x} · 옮김 ${Object.keys(st.move).length}장`;
}
function gapButton(e, prev) {
  // 사진을 고른 상태면 같은 버튼이 "옮기기"가 된다: 아래 구간에서 고르면 ↑, 위 구간에서 고르면 ↓
  if (sel.size && selEvent === e.event)
    return `<button class="move" data-to="${prev.event}">선택한 ${sel.size}장 ↑ 앞 구간으로</button>`;
  if (sel.size && selEvent === prev.event)
    return `<button class="move" data-to="${e.event}">선택한 ${sel.size}장 ↓ 뒤 구간으로</button>`;
  return `<button data-merge="${e.event}" aria-pressed="${!!st.merge[e.event]}">↑ 앞 구간과 같은 일</button>`;
}
function render() {
  const y = ysel.value, out = [];
  const inEvent = {};
  Object.keys(PHOTO).forEach(id => (inEvent[owner(id)] ||= []).push(id));
  let day = "";
  EVENTS.forEach((e, i) => {
    if (e.start.slice(0, 4) !== y) return;
    const d = e.start.slice(0, 10);
    if (d !== day) { day = d; out.push(`<h2>${d} (${"일월화수목금토"[new Date(d).getDay()]})</h2>`); }
    else {
      out.push(`<div class="gap ${st.merge[e.event] ? "merged" : ""}">${gapButton(e, EVENTS[i - 1])}
        <span>앞 구간과 ${fmtGap(e.gap_min)} 차이 · 나뉜 이유: ${e.why}</span></div>`);
    }
    const mixed = !!st.mixed[e.event];
    const ids = (inEvent[e.event] || []).sort((a, b) => PHOTO[a].t.localeCompare(PHOTO[b].t));
    const delta = ids.filter(id => PHOTO[id].home !== e.event).length - e.ids.filter(id => owner(id) !== e.event).length;
    out.push(`<div class="ev ${mixed ? "mixed" : ""}"><div class="meta"><span class="t">${e.start.slice(11, 16)}–${e.end.slice(11, 16)}</span>
      <span>${e.photos}장${delta ? ` (${delta > 0 ? "+" : ""}${delta})` : ""} · ${fmtGap(e.dur_min)}</span><span class="sp"></span>
      ${ids.length ? `<button class="all" data-all="${e.event}">${selEvent === e.event && sel.size === ids.length ? "선택 해제" : "전체 선택"}</button>` : ""}
      <label><input type="checkbox" data-mixed="${e.event}" ${mixed ? "checked" : ""}> 여러 일이 섞임</label></div>
      <div class="strip">${ids.map(id => `<img loading="lazy" src="phone/thumbs/${id}.jpg" alt="" data-id="${id}" data-ev="${e.event}"
        title="${PHOTO[id].t.slice(11, 16)}" class="${sel.has(id) ? "sel" : ""} ${PHOTO[id].home !== e.event ? "moved" : ""}">`).join("")
        || `<span class="empty">보이는 사진을 모두 옮겼습니다</span>`}</div></div>`);
  });
  document.getElementById("list").innerHTML = out.join("");
  document.getElementById("bar").hidden = sel.size === 0;
  document.getElementById("selcount").textContent = `${sel.size}장 선택`;
}
function clearSel() { sel.clear(); selEvent = lastClick = null; render(); }
const list = document.getElementById("list");
list.addEventListener("change", ev => {
  const t = ev.target;
  if (t.dataset.mixed) st.mixed[t.dataset.mixed] = t.checked;
  persist(); render();
});
list.addEventListener("click", ev => {
  const t = ev.target;
  if (t.matches(".strip img")) {
    const id = t.dataset.id, e = Number(t.dataset.ev);
    if (selEvent !== e) { sel.clear(); selEvent = e; lastClick = null; }  // 한 번에 한 구간에서만 고른다
    if (ev.shiftKey && lastClick) {
      const imgs = [...t.parentNode.querySelectorAll("img")].map(i => i.dataset.id);
      const [a, b] = [imgs.indexOf(lastClick), imgs.indexOf(id)].sort((x, y) => x - y);
      imgs.slice(a, b + 1).forEach(i => sel.add(i));
    } else sel.has(id) ? sel.delete(id) : sel.add(id);
    lastClick = id;
    if (!sel.size) selEvent = null;
    render();
  } else if (t.dataset.all) {
    const e = Number(t.dataset.all);
    const ids = [...t.closest(".ev").querySelectorAll(".strip img")].map(i => i.dataset.id);
    const all = selEvent === e && sel.size === ids.length;
    sel.clear(); selEvent = lastClick = null;
    if (!all) { ids.forEach(id => sel.add(id)); selEvent = e; }
    render();
  } else if (t.dataset.to) {
    const to = Number(t.dataset.to);
    sel.forEach(id => { if (PHOTO[id].home === to) delete st.move[id]; else st.move[id] = to; });
    sel.clear(); selEvent = lastClick = null;
    persist(); render();
  } else if (t.dataset.merge) {
    st.merge[t.dataset.merge] = !st.merge[t.dataset.merge];
    persist(); render();
  }
});
document.getElementById("clear").onclick = clearSel;
document.addEventListener("keydown", ev => { if (ev.key === "Escape" && sel.size) clearSel(); });
ysel.addEventListener("change", () => { sel.clear(); selEvent = lastClick = null; render(); window.scrollTo(0, 0); });
document.getElementById("reset").onclick = () => {
  if (confirm("표시한 내용을 모두 지울까요?")) { st = {merge: {}, mixed: {}, move: {}}; sel.clear(); selEvent = null; persist(); render(); }
};
document.getElementById("save").onclick = () => {
  const ids = o => Object.keys(o).filter(k => o[k]).map(Number);
  const moved = Object.entries(st.move).map(([id, to]) => ({id: Number(id), from: PHOTO[id].home, to, t: PHOTO[id].t}));
  const blob = new Blob([JSON.stringify({merge_with_prev: ids(st.merge), mixed: ids(st.mixed), moved,
    reviewed_years: years}, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "event_review.json"; a.click();
};
stat(); render();
</script></body></html>"""


def main() -> None:
    events = json.loads((EVAL / "time_events.json").read_text(encoding="utf-8"))
    prev_end = None
    for e in events:
        start, end = datetime.fromisoformat(e["start"]), datetime.fromisoformat(e["end"])
        e["dur_min"] = (end - start).total_seconds() / 60
        e["gap_min"] = (start - prev_end).total_seconds() / 60 if prev_end else 0
        prev_end = end
    out = EVAL / "event_review.html"
    out.write_text(PAGE.replace("__EVENTS__", json.dumps(events, ensure_ascii=False)), encoding="utf-8")
    print(f"{out} (구간 {len(events)}개)")


if __name__ == "__main__":
    main()
