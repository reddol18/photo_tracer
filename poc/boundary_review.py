"""애매한 경계만 모아 "같은 일 / 다른 일"을 고르는 페이지: eval_data/boundary_review.html (로컬 전용).

사용: uv run boundary_review.py ../eval_data/phone/meta_*.json   (썸네일은 phone_bench.py thumbs로 미리 받아 둠)
후보는 boundary_check.candidates()와 같다. 경계마다 앞 조각의 끝 6장과 뒤 조각의 첫 6장을 나란히 보여 준다.
결과는 boundary_labels.json({labels: {경계 뒤 첫 사진 ID: same|diff|unsure}})으로 저장해 boundary_check.py 셋째 인자로 쓴다.
"""
import json
import sys
from pathlib import Path

from boundary_check import candidates, load_shot
from time_events import km

EVAL = Path(__file__).parent.parent / "eval_data"
SHOW = 6

PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>경계 확인</title>
<style>
:root{--bg:#f6f7f5;--card:#fff;--ink:#1d2320;--sub:#66706b;--line:#dde2de;--accent:#0b6b5c;--warn:#b4441c;--sel:#1a73e8}
@media (prefers-color-scheme:dark){:root{--bg:#141816;--card:#1d2320;--ink:#e6ebe8;--sub:#9aa5a0;--line:#2f3833;--accent:#5cc7b2;--warn:#f0956f;--sel:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
header b{margin-right:auto}button{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:1200px;margin:0 auto;padding:12px 16px 80px}.help{color:var(--sub);font-size:14px;margin:4px 0 12px}
.b{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:12px}
.b.done{opacity:.55}.b.cur{border-color:var(--sel);border-width:2px}
.meta{font-size:14px;color:var(--sub);display:flex;gap:10px;flex-wrap:wrap}.meta .t{color:var(--ink);font-weight:600}
.pair{display:flex;gap:10px;align-items:center;margin:8px 0;flex-wrap:wrap}
.side{display:flex;gap:4px;flex-wrap:wrap}.side img{width:88px;height:88px;object-fit:cover;border-radius:6px;background:var(--line)}
.sep{font-size:13px;color:var(--warn);font-weight:600;padding:0 4px;text-align:center}
.ans{display:flex;gap:8px}.ans button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
.ans button.unsure[aria-pressed=true]{background:var(--sub);border-color:var(--sub)}
.count{font-variant-numeric:tabular-nums}
@media (max-width:600px){.side img{width:64px;height:64px}}
</style></head><body>
<header><b>경계 확인</b><span class="count" id="stat"></span><label><input type="checkbox" id="todo"> 안 고른 것만</label>
<button id="reset">처음부터 다시</button><button class="primary" id="save">결과 저장</button></header>
<main><p class="help">시간 차이가 3시간 안쪽인데 잘릴 수도 있는 곳만 모았습니다. 빨간 줄 왼쪽은 경계 앞, 오른쪽은 경계 뒤 사진입니다.
기억에 같은 일이면 <b>같은 일</b>, 다른 일이면 <b>다른 일</b>을 고르세요. 키보드: 1 같은 일 · 2 다른 일 · 3 모르겠음 (고르면 다음으로 넘어갑니다).
작업은 이 브라우저에 자동 저장됩니다.</p><div id="list"></div></main>
<script>
const B = __BOUNDARIES__;
const KEY = "photo_tracer_boundary_review_v1";
let st = {};
try { st = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) {}
const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} };
let cur = B.findIndex(b => !st[b.id]);
const NAMES = {same: "같은 일", diff: "다른 일", unsure: "모르겠음"};
function fmtGap(min) { return min < 60 ? `${Math.round(min)}분` : `${(min / 60).toFixed(1)}시간`; }
const imgs = ids => ids.map(id => `<img loading="lazy" src="phone/thumbs/${id}.jpg" alt="">`).join("");
function render() {
  const todo = document.getElementById("todo").checked;
  document.getElementById("list").innerHTML = B.map((b, i) => (todo && st[b.id]) ? "" :
    `<div class="b ${st[b.id] ? "done" : ""} ${i === cur ? "cur" : ""}" id="b${i}"><div class="meta">
      <span class="t">${b.day} ${b.end}→${b.start}</span><span>${fmtGap(b.gap_min)} 차이</span>
      <span>${b.km === null ? "위치 없음" : b.km.toFixed(1) + "km 이동"}</span><span>${i + 1}/${B.length}</span></div>
     <div class="pair"><div class="side">${imgs(b.before)}</div><div class="sep">┃<br>${fmtGap(b.gap_min)}</div><div class="side">${imgs(b.after)}</div></div>
     <div class="ans">${Object.entries(NAMES).map(([k, v]) =>
       `<button class="${k}" data-i="${i}" data-v="${k}" aria-pressed="${st[b.id] === k}">${v}</button>`).join("")}</div></div>`).join("");
  const n = B.filter(b => st[b.id]).length, c = k => B.filter(b => st[b.id] === k).length;
  document.getElementById("stat").textContent = `${n}/${B.length} · 같은 일 ${c("same")} · 다른 일 ${c("diff")} · 모르겠음 ${c("unsure")}`;
}
function pick(i, v) {
  const id = B[i].id;
  st[id] = st[id] === v ? undefined : v;
  if (!st[id]) delete st[id];
  persist();
  const next = B.findIndex((b, j) => j > i && !st[b.id]);
  cur = next >= 0 ? next : i;
  render();
  if (next >= 0) document.getElementById(`b${next}`)?.scrollIntoView({behavior: "smooth", block: "center"});
}
document.getElementById("list").addEventListener("click", ev => {
  const t = ev.target.closest("button[data-v]");
  if (t) pick(Number(t.dataset.i), t.dataset.v);
  else { const box = ev.target.closest(".b"); if (box) { cur = Number(box.id.slice(1)); render(); } }
});
document.addEventListener("keydown", ev => {
  const v = {"1": "same", "2": "diff", "3": "unsure"}[ev.key];
  if (v && cur >= 0) pick(cur, v);
});
document.getElementById("todo").onchange = render;
document.getElementById("reset").onclick = () => { if (confirm("고른 내용을 모두 지울까요?")) { st = {}; persist(); cur = 0; render(); } };
document.getElementById("save").onclick = () => {
  const blob = new Blob([JSON.stringify({labels: st, total: B.length}, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "boundary_labels.json"; a.click();
};
render();
</script></body></html>"""


def main() -> None:
    shot = load_shot(Path(sys.argv[1]))
    out = []
    for a, b in candidates(shot):
        la = next((p for p in reversed(a) if "lat" in p), None)
        lb = next((p for p in b if "lat" in p), None)
        out.append({"id": b[0]["id"], "day": a[-1]["t"].strftime("%Y-%m-%d"),
                    "end": a[-1]["t"].strftime("%H:%M"), "start": b[0]["t"].strftime("%H:%M"),
                    "gap_min": (b[0]["t"] - a[-1]["t"]).total_seconds() / 60,
                    "km": round(km(la, lb), 2) if la and lb else None,
                    "before": [p["id"] for p in a[-SHOW:]], "after": [p["id"] for p in b[:SHOW]]})
    page = EVAL / "boundary_review.html"
    page.write_text(PAGE.replace("__BOUNDARIES__", json.dumps(out)), encoding="utf-8")
    print(f"{page} (경계 {len(out)}개)")


if __name__ == "__main__":
    main()
