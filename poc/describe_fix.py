"""구간 설명 정답 만들기: Claude가 접촉 인화지(contact_sheets.py)를 보고 쓴 설명을 사용자가 틀린 것만 고치는 페이지.

사용: uv run describe_fix.py   (먼저 contact_sheets.py, 그리고 eval_data/claude_desc/part_*.json)
페이지: eval_data/describe_fix.html. 고치지 않은 설명은 맞은 것으로 본다. 결과는 describe_truth.json(구간 키 = 첫 사진 ID)으로
저장해 SigLIP 설명(describe.py)과 태그 표를 채점·개선하는 정답으로 쓴다.
"""
import json
from datetime import datetime
from pathlib import Path

from describe import WEEK
from segments import EVAL

PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>구간 설명 고치기</title>
<style>
:root{--bg:#f6f7f5;--card:#fff;--ink:#1d2320;--sub:#66706b;--line:#dde2de;--accent:#0b6b5c;--warn:#b4441c;--sel:#1a73e8}
@media (prefers-color-scheme:dark){:root{--bg:#141816;--card:#1d2320;--ink:#e6ebe8;--sub:#9aa5a0;--line:#2f3833;--accent:#5cc7b2;--warn:#f0956f;--sel:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
header b{margin-right:auto}button,select{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:1200px;margin:0 auto;padding:12px 16px 80px}.help{color:var(--sub);font-size:14px;margin:4px 0 12px}
.e{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:12px}
.e.edited{border-color:var(--accent);border-width:2px}
.when{font-size:14px;color:var(--sub);display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.badge{font-size:12px;border-radius:999px;padding:1px 8px;border:1px solid var(--warn);color:var(--warn)}
.row{display:flex;gap:8px;align-items:center;margin:4px 0 8px}
.row input{flex:1;font:inherit;font-size:17px;font-weight:600;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink)}
.row input:focus{outline:2px solid var(--sel);background:var(--card)}
.orig{font-size:13px;color:var(--sub)}
.all{display:flex;gap:3px;flex-wrap:wrap}.all img{width:72px;height:72px;object-fit:cover;border-radius:4px;background:var(--line)}
</style></head><body>
<header><b>구간 설명 고치기</b><select id="year"></select>
<select id="filter"><option value="all">전체</option><option value="unsure">확인 필요만</option><option value="edited">고친 것만</option></select>
<span id="stat"></span><button id="save" class="primary">결과 저장</button></header>
<main><p class="help">Claude가 사진을 직접 보고(간판·글자 포함) 쓴 설명입니다. <b>틀린 것만</b> 글을 고쳐 주세요 — 고치지 않은 설명은 맞은 것으로 봅니다.
<span class="badge">확인 필요</span>는 Claude가 썸네일만으로 확신하지 못한 구간입니다. 고친 내용은 이 브라우저에 자동 저장되고, 원래대로 하려면 '되돌리기'를 누르세요.</p>
<div id="list"></div></main>
<script>
const E = __EVENTS__;
const KEY = "photo_tracer_describe_fix_v1";  // 구간 키 = 첫 사진 ID
let st = {};
try { st = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) {}
const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} stat(); };
const years = [...new Set(E.map(e => e.when.slice(0, 4)))];
const ysel = document.getElementById("year"), fsel = document.getElementById("filter");
ysel.innerHTML = years.map(y => `<option>${y}</option>`).join("");
ysel.value = years[years.length - 1];
const esc = s => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
function stat() {
  document.getElementById("stat").textContent = `구간 ${E.length}개 · 확인 필요 ${E.filter(e => !e.sure).length} · 고침 ${Object.keys(st).length}`;
}
function render() {
  const f = fsel.value;
  document.getElementById("list").innerHTML = E.filter(e => e.when.slice(0, 4) === ysel.value &&
      (f === "all" || (f === "unsure" && !e.sure) || (f === "edited" && st[e.key] !== undefined))).map(item).join("");
}
// 고친 구간 하나만 다시 그린다. 목록 전체를 다시 그리면 방금 클릭한 다른 입력창이 새로 만들어져 포커스를 잃는다
function redraw(key) {
  const box = document.querySelector(`.e[data-key="${key}"]`);
  if (box) box.outerHTML = item(E.find(x => String(x.key) === String(key)));
}
function item(e) {
    const edited = st[e.key] !== undefined;
    return `<div class="e ${edited ? "edited" : ""}" data-key="${e.key}"><div class="when"><span>${e.when}</span><span>사진 ${e.photos}장</span>
        ${e.sure ? "" : `<span class="badge">확인 필요</span>`}${e.unresolved ? `<span class="badge">여러 일이 섞인 구간</span>` : ""}</div>
      <div class="row"><input value="${esc(edited ? st[e.key] : e.text)}" data-key="${e.key}">
        ${edited ? `<button data-undo="${e.key}">되돌리기</button>` : ""}</div>
      ${edited ? `<div class="orig">원래 설명: ${esc(e.text)}</div>` : ""}
      <div class="all">${e.ids.map(id => `<img loading="lazy" src="phone/thumbs/${id}.jpg" alt="">`).join("")}</div></div>`;
}
const list = document.getElementById("list");
list.addEventListener("change", ev => {
  const t = ev.target; if (!t.dataset.key) return;
  const e = E.find(x => String(x.key) === t.dataset.key), v = t.value.trim();
  if (v === e.text || v === "") delete st[e.key]; else st[e.key] = v;
  persist(); redraw(e.key);
});
list.addEventListener("keydown", ev => { if (ev.key === "Enter" && ev.target.dataset.key) ev.target.blur(); });
list.addEventListener("click", ev => { const k = ev.target.dataset.undo; if (k) { delete st[k]; persist(); redraw(k); } });
ysel.onchange = () => { render(); window.scrollTo(0, 0); };
fsel.onchange = render;
document.getElementById("save").onclick = () => {
  const out = E.map(e => ({key: e.key, event: e.event, text: st[e.key] ?? e.text, edited: st[e.key] !== undefined,
                           claude: e.text, sure: e.sure}));
  const blob = new Blob([JSON.stringify({events: out}, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "describe_truth.json"; a.click();
};
stat(); render();
</script></body></html>"""


def main() -> None:
    index = json.loads((EVAL / "sheets" / "index.json").read_text(encoding="utf-8"))
    desc = {d["event"]: d for p in sorted((EVAL / "claude_desc").glob("part_*.json"))
            for d in json.loads(p.read_text(encoding="utf-8"))}
    siglip = {d["key"]: d for d in json.loads((EVAL / "descriptions.json").read_text(encoding="utf-8"))}
    rows, missing = [], []
    for sheet in index:
        for r in sheet["events"]:
            d = desc.get(r["event"])
            if d is None:
                missing.append(r["event"])
                continue
            a, b = datetime.fromisoformat(r["start"]), datetime.fromisoformat(r["end"])
            hm = lambda t: f"{'오전' if t.hour < 12 else '오후'} {t.hour % 12 or 12}:{t.minute:02d}"
            rows.append({"key": r["key"], "event": r["event"], "photos": r["photos"], "unresolved": r["unresolved"],
                         "when": f"{a:%Y-%m-%d}({WEEK[a.weekday()]}) {hm(a)}" + ("" if a == b else f"–{hm(b)}"),
                         "text": d["text"], "sure": d.get("sure", True), "ids": siglip[r["key"]]["ids"]})
    if missing:
        raise SystemExit(f"설명이 없는 구간 {len(missing)}개: {missing[:20]}")
    page = EVAL / "describe_fix.html"
    page.write_text(PAGE.replace("__EVENTS__", json.dumps(rows, ensure_ascii=False)), encoding="utf-8")
    print(f"{page} · 구간 {len(rows)}개 · 확인 필요 {sum(not r['sure'] for r in rows)}개")


if __name__ == "__main__":
    main()
