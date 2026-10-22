"""구간 설명: 대표 사진의 SigLIP 임베딩 평균을 태그 표와 비교해 장소·내용 태그를 붙이고, 날짜·시간대를 더한다.

사용: uv run describe.py ../eval_data/phone/meta_*.json
  - 구간·대표 사진은 segments.py(사용자 판정 모두 반영)에서 가져온다
  - 확인 1(자동): 대표 사진만 쓴 설명이 구간 전체 사진을 쓴 설명과 얼마나 같은지
  - 확인 2(사람): eval_data/describe_review.html 에서 설명이 맞는지 판정 → describe_labels.json
아직 없는 것: 사람 이름(폰 사진 얼굴 분석 전), 장소 이름(오프라인 지명 변환 전).
입력은 160px 썸네일을 384로 키운 것이라 폰(원본)보다 불리하다. 384 대 512 비교는 원본이 있어야 의미가 있다.
"""
import json
import os
import sys
from pathlib import Path

import numpy as np
from transformers import AutoTokenizer

from boundary_siglip import embed
from export_siglip import MODEL_ID, OUT, TEXT_LEN, session
from segments import EVAL, final_events, photo_features, representatives

# 처음 표(export_siglip.TAGS 27개)는 장소 위주라, 구간 확인·대표 비교에서 본 사진(병원, 음식, 장난감 가게, 촬영 스튜디오,
# 공연 등)을 설명하지 못했다. 장소와 내용(무엇을 했나)을 나눠 늘린다.
PLACE = {
    "집 거실": "집 거실", "침실": "침실", "부엌": "부엌", "욕실": "욕실", "식당": "식당 안", "카페": "카페",
    "키즈카페": "실내 키즈카페", "놀이터": "놀이터", "공원": "공원", "숲": "숲속", "산": "산", "강가": "강가",
    "바닷가": "바닷가 해변", "수영장": "수영장", "도시 거리": "도시의 거리", "차 안": "자동차 안",
    "병원": "병원 진료실", "마트·가게": "마트나 가게 안", "학교·유치원": "학교나 유치원", "스튜디오": "사진 스튜디오",
    "공연장": "공연장 무대", "동물원": "동물원", "놀이공원": "놀이공원", "캠핑장": "캠핑장 텐트",
    "박물관·전시": "박물관이나 전시장", "결혼식장": "결혼식장", "기차·지하철": "기차나 지하철 안", "공항": "공항",
}
WHAT = {
    "음식": "음식이 담긴 접시", "케이크·생일": "생일 케이크와 파티", "장난감": "장난감", "아기": "아기",
    "잠자는 모습": "잠자는 아이", "목욕": "아이 목욕", "그림·만들기": "그림 그리기와 만들기", "책": "책 읽기",
    "물놀이": "물놀이", "눈": "눈이 쌓인 겨울", "꽃": "꽃", "동물": "동물", "자전거": "자전거 타기",
    "단체 사진": "여러 사람이 함께 찍은 단체 사진", "웨딩 촬영": "웨딩드레스를 입은 신부", "선물": "선물 상자",
    "문서·영수증": "문서나 영수증", "화면": "컴퓨터나 휴대폰 화면", "아픈 아이": "아파서 누워 있는 아이",
}
# '밤 풍경'(밤에 찍은 사진)은 낮 구간에도 거의 다 붙어서 뺐다. 시간대는 촬영 시각으로 이미 안다.
WEEK = "월화수목금토일"
# 태그별 갤러리 평균을 얼마나 뺄지. 1.0은 피자를 '기차·지하철'로 바꿀 만큼 과했고, 0은 '식당'·'학교·유치원'이 너무 많이 붙었다
CENTER = float(os.environ.get("CENTER", "0.5"))


def tag_table() -> tuple[list[str], np.ndarray, dict]:
    """태그 텍스트 임베딩(text.onnx). 폰에는 이 표만 싣는다. 결과는 models/siglip/tags_v2.* 에 둔다."""
    names = [("장소", k) for k in PLACE] + [("내용", k) for k in WHAT]
    prompts = list(PLACE.values()) + list(WHAT.values())
    npy, meta = OUT / "tags_v2.npy", OUT / "tags_v2.json"
    if not npy.exists() or json.loads(meta.read_text(encoding="utf-8"))["prompts"] != prompts:
        tok = AutoTokenizer.from_pretrained(MODEL_ID)
        ids = tok(prompts, padding="max_length", max_length=TEXT_LEN, truncation=True, return_tensors="np")["input_ids"]
        s = session(OUT / "text.onnx")
        emb = np.concatenate([s.run(None, {"input_ids": r[None].astype(np.int64)})[0] for r in ids])
        np.save(npy, emb.astype(np.float32))
        old = json.loads((OUT / "tags.json").read_text(encoding="utf-8"))
        meta.write_text(json.dumps({"tags": [n for _, n in names], "kinds": [k for k, _ in names], "prompts": prompts,
                                    "logit_scale": old["logit_scale"], "logit_bias": old["logit_bias"]},
                                   ensure_ascii=False, indent=1), encoding="utf-8")
    m = json.loads(meta.read_text(encoding="utf-8"))
    return names, np.load(npy), m


def when(e: list[dict]) -> str:
    a, b = e[0]["t"], e[-1]["t"]
    part = lambda h: "새벽" if h < 6 else "아침" if h < 11 else "낮" if h < 14 else "오후" if h < 18 else "저녁" if h < 21 else "밤"
    return f"{a:%Y-%m-%d}({WEEK[a.weekday()]}) {part(a.hour)}{'' if part(a.hour) == part(b.hour) else '~' + part(b.hour)}"


def tags_for(emb: np.ndarray, names, T, base: np.ndarray) -> list[tuple[str, str, float]]:
    """장소 1개 + 내용 최대 2개. 점수 = 코사인 - 그 태그의 갤러리 평균 코사인(base).
    어떤 사진에나 높게 나오는 태그(처음엔 '식당', '학교·유치원', '밤 풍경')가 모든 구간에 붙지 않게 한다.
    내용은 장소 점수와 너무 멀면(0.03 이상 낮으면) 뺀다."""
    v = emb / np.linalg.norm(emb)
    cos = T @ v - CENTER * base
    place = max((i for i, (k, _) in enumerate(names) if k == "장소"), key=lambda i: cos[i])
    what = sorted((i for i, (k, _) in enumerate(names) if k == "내용"), key=lambda i: -cos[i])[:2]
    out = [(names[place][0], names[place][1], float(cos[place]))]
    out += [(names[i][0], names[i][1], float(cos[i])) for i in what if cos[i] >= cos[place] - 0.03]
    return out


PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>구간 설명 확인</title>
<style>
:root{--bg:#f6f7f5;--card:#fff;--ink:#1d2320;--sub:#66706b;--line:#dde2de;--accent:#0b6b5c;--warn:#b4441c;--sel:#1a73e8}
@media (prefers-color-scheme:dark){:root{--bg:#141816;--card:#1d2320;--ink:#e6ebe8;--sub:#9aa5a0;--line:#2f3833;--accent:#5cc7b2;--warn:#f0956f;--sel:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--card);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
header b{margin-right:auto}button,select{font:inherit;padding:6px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--ink);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
main{max-width:1200px;margin:0 auto;padding:12px 16px 80px}.help{color:var(--sub);font-size:14px;margin:4px 0 12px}
.e{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:12px}
.e.done{opacity:.55}.e.cur{border-color:var(--sel);border-width:2px}
.desc{display:flex;gap:6px;flex-wrap:wrap;align-items:center;font-size:16px}.desc .w{font-weight:600;margin-right:4px}
.chip{border:1px solid var(--accent);color:var(--accent);border-radius:999px;padding:2px 10px;cursor:pointer;font-size:14px;background:none}
.chip.wrong{border-color:var(--warn);color:var(--warn);text-decoration:line-through}
.chip small{color:var(--sub);margin-left:4px}.flag{color:var(--warn);font-size:13px}
.all{display:flex;gap:3px;flex-wrap:wrap;margin:8px 0}.all img{width:60px;height:60px;object-fit:cover;border-radius:4px;border:3px solid transparent;background:var(--line)}
.all img.rep{border-color:var(--accent)}
.ans{display:flex;gap:8px}.ans button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
</style></head><body>
<header><b>구간 설명 확인</b><select id="year"></select><span id="stat"></span><label><input type="checkbox" id="todo"> 안 고른 것만</label>
<button id="save" class="primary">결과 저장</button></header>
<main><p class="help">경계 판정까지 반영한 구간입니다. 초록 테두리가 설명을 만드는 데 쓴 대표 사진입니다.
태그 중 틀린 것은 눌러서 지우고(빨간 줄), 설명 전체를 판정하세요. 키보드: 1 맞음 · 2 일부 틀림 · 3 틀림 (고르면 다음으로).
아직 사람 이름과 장소 이름은 넣지 않았습니다. 작업은 이 브라우저에 자동 저장됩니다.</p><div id="list"></div></main>
<script>
const E = __EVENTS__;
const KEY = "photo_tracer_describe_review_v1";  // 구간 키 = 첫 사진 ID
let st = {};
try { st = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) {}
const persist = () => { try { localStorage.setItem(KEY, JSON.stringify(st)); } catch (e) {} };
const years = [...new Set(E.map(e => e.when.slice(0, 4)))];
const ysel = document.getElementById("year");
ysel.innerHTML = years.map(y => `<option>${y}</option>`).join("");
ysel.value = years[years.length - 1];
let cur = -1;
const NAMES = {ok: "맞음", partly: "일부 틀림", wrong: "틀림"};
const entry = k => st[k] || (st[k] = {verdict: null, wrong: []});
function shown() { return E.map((e, i) => i).filter(i => E[i].when.slice(0, 4) === ysel.value && !(document.getElementById("todo").checked && st[E[i].key]?.verdict)); }
function render() {
  const idx = shown();
  if (cur < 0 || !idx.includes(cur)) cur = idx.find(i => !st[E[i].key]?.verdict) ?? idx[0] ?? -1;
  document.getElementById("list").innerHTML = idx.map(i => { const e = E[i], s = st[e.key] || {wrong: []};
    return `<div class="e ${s.verdict ? "done" : ""} ${i === cur ? "cur" : ""}" id="e${i}">
      <div class="desc"><span class="w">${e.when}</span>${e.tags.map(([k, n, c]) =>
        `<button class="chip ${s.wrong.includes(n) ? "wrong" : ""}" data-i="${i}" data-tag="${n}">${n}<small>${k}</small></button>`).join("")}
        <span class="flag">${e.unresolved ? "· 여러 일이 섞인 채 남은 구간" : ""}</span></div>
      <div class="all">${e.ids.map(id => `<img loading="lazy" src="phone/thumbs/${id}.jpg" alt="" class="${e.reps.includes(id) ? "rep" : ""}">`).join("")}</div>
      <div class="ans">${Object.entries(NAMES).map(([k, v]) => `<button data-i="${i}" data-v="${k}" aria-pressed="${s.verdict === k}">${v}</button>`).join("")}</div></div>`; }).join("");
  const done = Object.values(st).filter(s => s.verdict), c = k => done.filter(s => s.verdict === k).length;
  document.getElementById("stat").textContent = `${done.length}/${E.length} · 맞음 ${c("ok")} · 일부 ${c("partly")} · 틀림 ${c("wrong")}`;
}
function choose(i, v) {
  const s = entry(E[i].key);
  s.verdict = s.verdict === v ? null : v;
  persist();
  const next = shown().find(j => j > i && !st[E[j].key]?.verdict);
  cur = next ?? i;
  render();
  if (next !== undefined) document.getElementById(`e${next}`)?.scrollIntoView({behavior: "smooth", block: "start"});
}
document.getElementById("list").addEventListener("click", ev => {
  const t = ev.target.closest("button");
  if (t?.dataset.v) return choose(Number(t.dataset.i), t.dataset.v);
  if (t?.dataset.tag) {
    const s = entry(E[Number(t.dataset.i)].key), n = t.dataset.tag;
    s.wrong = s.wrong.includes(n) ? s.wrong.filter(x => x !== n) : [...s.wrong, n];
    cur = Number(t.dataset.i); persist(); return render();
  }
  const box = ev.target.closest(".e"); if (box) { cur = Number(box.id.slice(1)); render(); }
});
document.addEventListener("keydown", ev => { const v = {"1": "ok", "2": "partly", "3": "wrong"}[ev.key]; if (v && cur >= 0) choose(cur, v); });
ysel.onchange = () => { cur = -1; render(); window.scrollTo(0, 0); };
document.getElementById("todo").onchange = render;
document.getElementById("save").onclick = () => {
  const labels = Object.fromEntries(Object.entries(st).filter(([, s]) => s.verdict || s.wrong.length));
  const blob = new Blob([JSON.stringify({labels}, null, 1)], {type: "application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "describe_labels.json"; a.click();
};
render();
</script></body></html>"""


def main() -> None:
    events, unresolved, shot = final_events(Path(sys.argv[1]))
    F = photo_features(shot)
    R = [representatives(e, F) for e in events]
    names, T, _ = tag_table()
    E = embed([p["id"] for p in shot])  # 전체 사진(대표만 쓴 설명과 비교용) — thumb_siglip.npz 에 쌓인다

    allv = np.stack([E[p["id"]] for p in shot])
    base = (allv / np.linalg.norm(allv, axis=1, keepdims=True) @ T.T).mean(0)
    out, top1_same, overlap = [], 0, []
    for i, (e, r) in enumerate(zip(events, R)):
        rep = tags_for(np.mean([E[x] for x in r], axis=0), names, T, base)
        full = tags_for(np.mean([E[p["id"]] for p in e], axis=0), names, T, base)
        top1_same += rep[0][1] == full[0][1]
        a, b = {t[1] for t in rep}, {t[1] for t in full}
        overlap.append(len(a & b) / len(a | b))
        out.append({"key": e[0]["id"], "event": i, "when": when(e), "photos": len(e), "ids": [p["id"] for p in e],
                    "reps": r, "tags": [[k, n, round(s, 3)] for k, n, s in rep], "unresolved": i in unresolved})
    n = len(events)
    print(f"대표 {sum(map(len, R))}장으로 만든 설명 vs 전체 {len(shot)}장으로 만든 설명:"
          f" 장소 태그 같음 {top1_same}/{n}({top1_same / n:.0%}) · 태그 집합 겹침 평균 {np.mean(overlap):.0%}")
    from collections import Counter
    print("장소 태그 분포:", Counter(o["tags"][0][1] for o in out).most_common(12))
    print("내용 태그 분포:", Counter(t[1] for o in out for t in o["tags"][1:]).most_common(12))
    (EVAL / "descriptions.json").write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    page = EVAL / "describe_review.html"
    page.write_text(PAGE.replace("__EVENTS__", json.dumps(out, ensure_ascii=False)), encoding="utf-8")
    print(page)


if __name__ == "__main__":
    main()
