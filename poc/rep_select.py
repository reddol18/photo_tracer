"""구간마다 대표 사진을 AI 없이 고르고, 단순 방식(시간상 고르게)과 눈가림 비교하는 페이지를 만든다.

사용: uv run rep_select.py ../eval_data/phone/meta_*.json
고르는 순서 (160px 썸네일 기준 — 선명도는 원본에서 다시 확인해야 함):
  1) 중복 제거: dHash 해밍 거리 ≤ DUP 인 사진은 한 무리로 보고 품질 좋은 1장만 후보로 남긴다
  2) 품질 거르기: 너무 어둡거나 밝거나 하얗게/까맣게 날아간 사진, 구간 안에서 유난히 흐린 사진을 뺀다
  3) 대표성: HSV 색 히스토그램으로 구간 전체와 가장 가까운 사진(메도이드) 1장 → 이미 고른 것과 가장 다른 사진을 차례로
대표 수는 time_events.reps(n). 결과: eval_data/reps.json, 비교 페이지 eval_data/rep_review.html
"""
import json
import random
import statistics
import sys
from pathlib import Path

import cv2
import numpy as np

from boundary_check import THUMBS, corrected_events, hist, load_shot
from time_events import reps, split_place

EVAL = Path(__file__).parent.parent / "eval_data"
DUP = 6  # dHash 64비트 중 다른 비트 수


def features(pid: int) -> dict:
    img = cv2.imread(str(THUMBS / f"{pid}.jpg"))
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    small = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    clip = float(((gray < 10) | (gray > 245)).mean())
    return {"dhash": int("".join("1" if b else "0" for b in bits), 2),
            "sharp": float(cv2.Laplacian(gray, cv2.CV_64F).var()),
            "bright": float(gray.mean()), "clip": clip, "contrast": float(gray.std()),
            "hist": hist(pid).astype(np.float32)}


def bad_exposure(f: dict) -> bool:
    # 대비가 낮은 사진(어두운 상자·벽·바닥 등)은 '가장 다른 사진'으로 뽑히기 쉬워 함께 뺀다
    return f["bright"] < 35 or f["bright"] > 225 or f["clip"] > 0.4 or f["contrast"] < 28


def pick(event: list[dict], F: dict[int, dict]) -> tuple[list[int], dict]:
    ids = [p["id"] for p in event]
    k = reps(len(ids))
    # 1) 중복 무리: 앞에서부터 이미 있는 무리 대표와 가까우면 합류
    groups: list[list[int]] = []
    for i in ids:
        for g in groups:
            if bin(F[i]["dhash"] ^ F[g[0]]["dhash"]).count("1") <= DUP:
                g.append(i)
                break
        else:
            groups.append([i])
    quality = lambda i: np.log1p(F[i]["sharp"]) - (5 if bad_exposure(F[i]) else 0)
    cands = [max(g, key=quality) for g in groups]
    # 2) 품질: 노출 불량, 구간 중앙값의 35%보다 흐린 사진 제외 (후보가 k장보다 적어지면 거르지 않음)
    med = statistics.median(F[i]["sharp"] for i in ids)
    good = [i for i in cands if not bad_exposure(F[i]) and F[i]["sharp"] >= 0.35 * med]
    pool = good if len(good) >= k else cands
    # 3) 메도이드 + 가장 다른 사진. 중복 무리는 크기만큼 무게를 가진다(많이 찍은 장면이 중요)
    D = lambda a, b: cv2.compareHist(F[a]["hist"], F[b]["hist"], cv2.HISTCMP_BHATTACHARYYA)
    chosen = [min(pool, key=lambda c: sum(D(c, i) for i in ids))]
    qmax = max(quality(i) for i in pool) or 1
    while len(chosen) < min(k, len(pool)):
        rest = [c for c in pool if c not in chosen]
        chosen.append(max(rest, key=lambda c: min(D(c, s) for s in chosen) * (0.5 + 0.5 * max(0, quality(c)) / qmax)))
    chosen.sort(key=ids.index)
    return chosen, {"groups": len(groups), "dropped": len(cands) - len(good)}


def baseline(event: list[dict]) -> list[int]:
    """비교용: 시간 순서에서 고르게 k장."""
    n, k = len(event), reps(len(event))
    return [event[int((j + 0.5) * n / k)]["id"] for j in range(k)]


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>대표 사진 비교</title>
<style>
:root{--bg:#f6f7f5;--card:#fff;--ink:#1d2320;--sub:#66706b;--line:#dde2de;--accent:#0b6b5c;--sel:#1a73e8}
@media (prefers-color-scheme:dark){:root{--bg:#141816;--card:#1d2320;--ink:#e6ebe8;--sub:#9aa5a0;--line:#2f3833;--accent:#5cc7b2;--sel:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
header b{margin-right:auto}button,select{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:1200px;margin:0 auto;padding:12px 16px 80px}.help{color:var(--sub);font-size:14px;margin:4px 0 12px}
.e{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:12px}
.e.done{opacity:.55}.e.cur{border-color:var(--sel);border-width:2px}
.meta{font-size:14px;color:var(--sub)}.meta .t{color:var(--ink);font-weight:600}
.all{display:flex;gap:3px;flex-wrap:wrap;margin:6px 0 10px}.all img{width:52px;height:52px;object-fit:cover;border-radius:4px;background:var(--line)}
.sets{display:grid;grid-template-columns:1fr 1fr;gap:12px}.set{border:1px dashed var(--line);border-radius:8px;padding:8px}
.set h3{margin:0 0 6px;font-size:14px}.set div{display:flex;gap:4px;flex-wrap:wrap}.set img{width:110px;height:110px;object-fit:cover;border-radius:6px}
.ans{display:flex;gap:8px;margin-top:8px}.ans button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
@media (max-width:700px){.sets{grid-template-columns:1fr}.set img{width:80px;height:80px}}
</style></head><body>
<header><b>대표 사진 비교</b><select id="year"></select><span id="stat"></span><label><input type="checkbox" id="todo"> 안 고른 것만</label>
<button id="save" class="primary">결과 저장</button></header>
<main><p class="help">위 줄은 구간의 전체 사진입니다. 아래 A와 B는 서로 다른 방법으로 고른 대표 사진입니다(어느 쪽이 어떤 방법인지는 숨겼습니다).
이 일을 떠올리기에 더 나은 쪽을 고르세요. 키보드: 1 A · 2 B · 3 비슷함 (고르면 다음으로). 작업은 이 브라우저에 자동 저장됩니다.</p>
<div id="list"></div></main>
<script>
const E = __EVENTS__;
// v2: 구간 키 = 첫 사진 ID (경계 판정 반영 후 구간 번호가 바뀌어서). v1(기본 규칙 구간 번호)의 판정은 그대로인 구간만 옮긴다
const KEY = "photo_tracer_rep_review_v2", OLD_KEY = "photo_tracer_rep_review_v1";
let st = {}, v1 = {};
try { st = JSON.parse(localStorage.getItem(KEY)) || {}; v1 = JSON.parse(localStorage.getItem(OLD_KEY)) || {}; } catch (e) {}
const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} };
let carried = 0;
E.forEach(e => {
  const v = e.old === undefined ? undefined : v1[e.old];
  if (!v || st[e.key]) return;
  const ours = v === "tie" ? null : (v === "A") === e.old_ours_is_A;
  st[e.key] = ours === null ? "tie" : ours === e.ours_is_A ? "A" : "B";
  carried++;
});
if (carried) persist();
const years = [...new Set(E.map(e => e.start.slice(0, 4)))];
const ysel = document.getElementById("year");
ysel.innerHTML = years.map(y => `<option>${y}</option>`).join("");
ysel.value = years[years.length - 1];
let cur = -1;
const img = id => `<img loading="lazy" src="phone/thumbs/${id}.jpg" alt="">`;
const NAMES = {A: "A가 낫다", B: "B가 낫다", tie: "비슷함"};
function shown() { return E.map((e, i) => i).filter(i => E[i].start.slice(0, 4) === ysel.value && !(document.getElementById("todo").checked && st[E[i].key])); }
function render() {
  const idx = shown();
  if (cur < 0 || !idx.includes(cur)) cur = idx.find(i => !st[E[i].key]) ?? idx[0] ?? -1;
  document.getElementById("list").innerHTML = idx.map(i => { const e = E[i];
    return `<div class="e ${st[e.key] ? "done" : ""} ${i === cur ? "cur" : ""}" id="e${i}"><div class="meta"><span class="t">${e.start.slice(0, 16).replace("T", " ")}</span>
      · ${e.ids.length}장 · 대표 ${e.A.length}장</div><div class="all">${e.ids.map(id => img(id)).join("")}</div>
      <div class="sets"><div class="set"><h3>A</h3><div>${e.A.map(id => img(id)).join("")}</div></div>
      <div class="set"><h3>B</h3><div>${e.B.map(id => img(id)).join("")}</div></div></div>
      <div class="ans">${Object.entries(NAMES).map(([k, v]) => `<button data-i="${i}" data-v="${k}" aria-pressed="${st[e.key] === k}">${v}</button>`).join("")}</div></div>`; }).join("");
  const n = Object.keys(st).length, c = k => Object.values(st).filter(v => v === k).length;
  document.getElementById("stat").textContent = `${n}/${E.length} · A ${c("A")} · B ${c("B")} · 비슷 ${c("tie")}`;
}
function choose(i, v) {
  const ev = E[i].key;
  if (st[ev] === v) delete st[ev]; else st[ev] = v;
  persist();
  const idx = shown(), next = idx.find(j => j > i && !st[E[j].key]);
  cur = next ?? i;
  render();
  if (next !== undefined) document.getElementById(`e${next}`)?.scrollIntoView({behavior: "smooth", block: "start"});
}
document.getElementById("list").addEventListener("click", ev => {
  const t = ev.target.closest("button[data-v]");
  if (t) choose(Number(t.dataset.i), t.dataset.v);
  else { const box = ev.target.closest(".e"); if (box) { cur = Number(box.id.slice(1)); render(); } }
});
document.addEventListener("keydown", ev => { const v = {"1": "A", "2": "B", "3": "tie"}[ev.key]; if (v && cur >= 0) choose(cur, v); });
ysel.onchange = () => { cur = -1; render(); window.scrollTo(0, 0); };
document.getElementById("todo").onchange = render;
document.getElementById("save").onclick = () => {
  // A/B가 어느 방법인지 풀어서 저장한다
  const out = Object.entries(st).map(([ev, v]) => { const e = E.find(x => x.key === Number(ev));
    return {key: Number(ev), event: e.event, choice: v === "tie" ? "tie" : (v === "A") === e.ours_is_A ? "ours" : "base"}; });
  const blob = new Blob([JSON.stringify({labels: out}, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "rep_labels.json"; a.click();
};
render();
</script></body></html>"""


def build(events: list[list[dict]], F: dict[int, dict]) -> tuple[list[dict], list[dict], dict]:
    """구간마다 두 방식으로 고르고, 서로 다른 구간만 A/B(무작위 배치)로 만든다. 구간 키 = 첫 사진 ID."""
    rng = random.Random(7)
    out, review, stat = [], [], {"dup": 0, "drop": 0, "same": 0}
    for i, e in enumerate(events):
        ours, info = pick(e, F)
        base = baseline(e)
        stat["dup"] += len(e) - info["groups"]
        stat["drop"] += info["dropped"]
        out.append({"event": i, "key": e[0]["id"], "reps": ours, "baseline": base, **info})
        if sorted(ours) == sorted(base):
            stat["same"] += 1
            continue
        a_ours = rng.random() < 0.5
        review.append({"event": i, "key": e[0]["id"], "start": e[0]["t"].isoformat(), "ids": [p["id"] for p in e],
                       "A": ours if a_ours else base, "B": base if a_ours else ours, "ours_is_A": a_ours})
    return out, review, stat


def main() -> None:
    shot = load_shot(Path(sys.argv[1]))
    F = {p["id"]: features(p["id"]) for p in shot}
    # 경계 확인 결과(boundary_labels.json)를 반영한 구간으로 고른다. 처음 만든 페이지는 이것을 빠뜨렸다
    labels = json.loads((EVAL / "boundary_labels.json").read_text(encoding="utf-8"))["labels"]
    events = corrected_events(shot, labels)
    out, review, stat = build(events, F)
    # 이전 페이지(기본 규칙 구간, 저장 키 v1)에서 이미 고른 판정을 옮겨 오기 위한 대응표:
    # 구간 사진과 두 방식의 대표가 모두 그대로인 구간만 이어받는다
    _, old_review, _ = build(split_place(shot, 3, 1.0), F)
    old = {(o["key"], tuple(o["ids"]), tuple(sorted(o["A"] + o["B"]))): o for o in old_review}
    for r in review:
        o = old.get((r["key"], tuple(r["ids"]), tuple(sorted(r["A"] + r["B"]))))
        ours = r["A"] if r["ours_is_A"] else r["B"]
        if o and sorted(ours) == sorted(o["A"] if o["ours_is_A"] else o["B"]):
            r["old"], r["old_ours_is_A"] = o["event"], o["ours_is_A"]
    (EVAL / "reps.json").write_text(json.dumps(out), encoding="utf-8")
    page = EVAL / "rep_review.html"
    page.write_text(PAGE.replace("__EVENTS__", json.dumps(review)), encoding="utf-8")
    print(f"구간 {len(events)}개(경계 판정 반영) · 사진 {len(shot)}장 · 중복으로 묶인 사진 {stat['dup']}장 · 품질로 뺀 후보 {stat['drop']}장")
    print(f"대표 {sum(len(o['reps']) for o in out)}장 · 단순 방식과 같은 구간 {stat['same']}개 → 비교할 구간 {len(review)}개"
          f" · 이전 판정을 이어받을 수 있는 구간 {sum('old' in r for r in review)}개")
    print(page)


if __name__ == "__main__":
    main()
