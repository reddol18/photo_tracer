"""얼굴 임베딩을 사람별로 묶고, 묶음에 이름을 붙이는 로컬 라벨링 페이지를 만든다.

사용: uv run cluster_faces.py [--threshold 0.45]
  → eval_data/label.html 을 브라우저로 열어 묶음마다 호칭·관계·생년을 적고 'labels.json 저장'을 누른다.
  잘못 묶인 얼굴은 선택해서 새 묶음이나 다른 묶음으로 옮긴다. 작업 내용은 브라우저에 자동 저장된다.
  labels.json 형식: {"f00012": {"name": "할머니", "relation": "부모", "birth_year": 1960, "group": 3}, ...}
  얼굴 사진이 들어 있으므로 이 페이지는 로컬에서만 연다 (어디에도 올리지 않음).
"""
import argparse
import base64
import html
import json
from collections import Counter
from pathlib import Path

import numpy as np
from sklearn.cluster import AgglomerativeClustering

DEFAULT_DATA = Path(__file__).parent.parent / "eval_data"
NAMES = ["아기", "아빠", "엄마", "할머니", "할아버지", "사촌언니", "큰아빠", "기타인물", "얼굴아님"]
# 사용자(앱 주인) 기준 관계. 호칭은 가족마다 다르지만 관계는 앱이 분류·검색에 공통으로 쓴다.
RELATIONS = ["본인", "배우자", "자녀", "부모", "배우자의 부모", "형제자매", "조카", "친척", "친구", "지인", "모르는 사람", "얼굴아님"]


def cluster(emb: np.ndarray, threshold: float) -> np.ndarray:
    # 코사인 거리 = 1 - 유사도. 0.6에선 아기 얼굴 전부가 한 덩어리로 뭉쳐서 라벨링용으로는 잘게 나눈다.
    model = AgglomerativeClustering(n_clusters=None, metric="cosine", linkage="average",
                                    distance_threshold=threshold)
    return model.fit_predict(emb)


def render(faces: list[dict], labels: np.ndarray, data: Path) -> str:
    groups: dict[int, list[dict]] = {}
    for face, c in zip(faces, labels):
        groups.setdefault(int(c), []).append(face)
    ordered = sorted(groups.values(), key=len, reverse=True)

    def img(face: dict) -> str:
        b64 = base64.b64encode((data / "crops" / f"{face['face_id']}.jpg").read_bytes()).decode()
        title = html.escape(f"{face['photo']} · {face['face_id']}")
        return (f'<img src="data:image/jpeg;base64,{b64}" data-id="{face["face_id"]}" '
                f'data-year="{face["year"]}" title="{title}">')

    sections = "".join(
        f'<section data-no="{i + 1}">{{{{HEAD}}}}<div class="grid">{"".join(img(f) for f in group)}</div></section>'
        for i, group in enumerate(ordered))
    names = "".join(f'<option value="{n}">' for n in NAMES)
    relations = "".join(f'<option value="{r}">' for r in RELATIONS)
    return (PAGE.replace("{{SECTIONS}}", sections).replace("{{HEAD}}", HEAD)
                .replace("{{NAMES}}", names).replace("{{RELATIONS}}", relations)
                .replace("{{FACES}}", str(len(faces))))


# 묶음 머리. 새 묶음은 JS가 같은 마크업을 복제해 만든다.
HEAD = """<h2><span class="title"></span> <small class="meta"></small>
<input class="name" list="names" placeholder="호칭 (예: 할머니)">
<input class="relation" list="relations" placeholder="나와의 관계 (예: 부모)">
<input class="birth" type="number" min="1900" max="2100" placeholder="생년 (예: 1960)">
<button type="button" class="all">모두 선택</button></h2>"""

PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>얼굴 라벨링</title>
<style>
:root { color-scheme: light dark; --bg:#fff; --fg:#1b1b1b; --muted:#666; --line:#ddd; --sel:#1a73e8; --new:#e8f0fe; }
@media (prefers-color-scheme: dark) { :root { --bg:#151515; --fg:#eee; --muted:#999; --line:#333; --sel:#8ab4f8; --new:#1c2533; } }
body { background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, sans-serif; margin:0 16px 120px; }
header { position:sticky; top:0; background:var(--bg); border-bottom:1px solid var(--line); padding:12px 0; z-index:2; }
section { border-radius:8px; padding:0 8px 8px; margin-top:16px; }
section.new { background:var(--new); }
h2 { font-size:16px; display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin:0; padding-top:8px; }
small { color:var(--muted); font-weight:normal; }
input { font:inherit; padding:4px 8px; }
input.birth { width:9em; }
.grid { display:flex; flex-wrap:wrap; gap:4px; margin-top:8px; min-height:20px; }
.grid img { width:72px; height:72px; border:3px solid transparent; cursor:pointer; border-radius:4px; }
.grid img.sel { border-color:var(--sel); }
button { font:inherit; padding:4px 12px; cursor:pointer; }
#bar { position:fixed; left:0; right:0; bottom:0; background:var(--bg); border-top:2px solid var(--sel);
       padding:10px 16px; display:flex; gap:8px; align-items:center; flex-wrap:wrap; z-index:3; }
#bar[hidden] { display:none; }
</style></head><body>
<header><b>얼굴 라벨링</b> · 얼굴 {{FACES}}개 · <span id="count"></span><br>
<small>묶음마다 호칭·관계·생년을 적으세요. 잘못 묶인 얼굴은 눌러서 선택한 뒤 아래 막대에서 새 묶음이나 다른 묶음으로 보내세요. 작업은 이 브라우저에 자동 저장됩니다.</small><br>
<button onclick="save()">labels.json 저장</button> <button onclick="reset()">처음부터 다시</button></header>
<datalist id="names">{{NAMES}}</datalist>
<datalist id="relations">{{RELATIONS}}</datalist>
<main id="groups">{{SECTIONS}}</main>
<div id="bar" hidden>
  <b id="selcount"></b>
  <button onclick="moveToNew()">새 묶음 만들어 보내기</button>
  <select id="target"></select> <button onclick="moveToTarget()">이 묶음으로 보내기</button>
  <button onclick="clearSel()">선택 해제</button>
</div>
<template id="head">{{HEAD}}</template>
<script>
const KEY = 'photo_tracer_label_v2';
const main = document.getElementById('groups');
const bar = document.getElementById('bar');
const selected = new Set();
const sections = () => [...main.querySelectorAll('section')];
let nextNo = sections().length + 1;

function title(sec) {
  const name = sec.querySelector('.name').value.trim();
  return `묶음 ${sec.dataset.no}${sec.classList.contains('new') ? ' (새로 만듦)' : ''}${name ? ' · ' + name : ''}`;
}
function refresh() {
  let shown = 0;
  sections().forEach(sec => {
    const imgs = [...sec.querySelectorAll('img')];
    const years = {};
    imgs.forEach(i => years[i.dataset.year] = (years[i.dataset.year] || 0) + 1);
    sec.querySelector('.title').textContent = title(sec);
    sec.querySelector('.meta').textContent = `${imgs.length}개 · ` +
      Object.keys(years).sort().map(y => `${y}:${years[y]}`).join(' ');
    sec.hidden = imgs.length === 0;
    if (!sec.hidden) shown++;
  });
  document.getElementById('count').textContent = `묶음 ${shown}개`;
  document.getElementById('selcount').textContent = `선택 ${selected.size}개`;
  bar.hidden = selected.size === 0;
  const target = document.getElementById('target');
  const keep = target.value;
  target.innerHTML = sections().filter(s => !s.hidden)
    .map(s => `<option value="${s.dataset.no}">${title(s)}</option>`).join('');
  if (keep) target.value = keep;
}
function makeSection(no) {
  const sec = document.createElement('section');
  sec.dataset.no = no; sec.classList.add('new');
  sec.append(document.getElementById('head').content.cloneNode(true));
  const grid = document.createElement('div'); grid.className = 'grid'; sec.append(grid);
  main.prepend(sec);
  return sec;
}
function moveTo(sec) {
  const grid = sec.querySelector('.grid');
  document.querySelectorAll('img.sel').forEach(img => { img.classList.remove('sel'); grid.append(img); });
  selected.clear(); refresh(); persist();
  sec.scrollIntoView({behavior: 'smooth', block: 'start'});
}
function moveToNew() { const sec = makeSection(nextNo++); moveTo(sec); sec.querySelector('.name').focus(); }
function moveToTarget() {
  const sec = main.querySelector(`section[data-no="${document.getElementById('target').value}"]`);
  if (sec) moveTo(sec);
}
function clearSel() { document.querySelectorAll('img.sel').forEach(i => i.classList.remove('sel')); selected.clear(); refresh(); }

main.addEventListener('click', e => {
  if (e.target.matches('.grid img')) {
    const img = e.target, id = img.dataset.id;
    img.classList.toggle('sel');
    img.classList.contains('sel') ? selected.add(id) : selected.delete(id);
    refresh();
  } else if (e.target.matches('button.all')) {
    const imgs = [...e.target.closest('section').querySelectorAll('img')];
    const on = imgs.some(i => !i.classList.contains('sel'));
    imgs.forEach(i => { i.classList.toggle('sel', on); on ? selected.add(i.dataset.id) : selected.delete(i.dataset.id); });
    refresh();
  }
});
main.addEventListener('input', () => { refresh(); persist(); });

function state() {
  return {nextNo, groups: sections().map(s => ({
    no: s.dataset.no, isNew: s.classList.contains('new'),
    name: s.querySelector('.name').value, relation: s.querySelector('.relation').value,
    birth: s.querySelector('.birth').value, ids: [...s.querySelectorAll('img')].map(i => i.dataset.id)}))};
}
function persist() { try { localStorage.setItem(KEY, JSON.stringify(state())); } catch (e) {} }
function restore() {
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(KEY)); } catch (e) {}
  if (!saved) return;
  const imgs = {};
  document.querySelectorAll('.grid img').forEach(i => imgs[i.dataset.id] = i);
  // 저장된 얼굴 목록이 지금 페이지와 다르면(다시 추출함) 복원하지 않는다
  const savedIds = saved.groups.flatMap(g => g.ids);
  if (savedIds.length !== Object.keys(imgs).length || savedIds.some(id => !imgs[id])) return;
  [...saved.groups].reverse().forEach(g => {
    const sec = main.querySelector(`section[data-no="${g.no}"]`) || makeSection(g.no);
    if (!g.isNew) main.append(sec);
    sec.querySelector('.name').value = g.name;
    sec.querySelector('.relation').value = g.relation;
    sec.querySelector('.birth').value = g.birth;
    const grid = sec.querySelector('.grid');
    g.ids.forEach(id => grid.append(imgs[id]));
  });
  // 순서 정리: 새 묶음은 위, 원래 묶음은 번호순
  sections().sort((a, b) => (b.classList.contains('new') - a.classList.contains('new')) ||
    (a.classList.contains('new') ? b.dataset.no - a.dataset.no : a.dataset.no - b.dataset.no))
    .forEach(s => main.append(s));
  nextNo = Math.max(saved.nextNo || 0, nextNo);
}
function reset() {
  if (!confirm('지금까지 적은 내용과 옮긴 묶음을 모두 지울까요?')) return;
  try { localStorage.removeItem(KEY); } catch (e) {}
  location.reload();
}
function save() {
  const labels = {}; let noName = 0, noBirth = 0;
  sections().forEach(sec => {
    const name = sec.querySelector('.name').value.trim();
    const relation = sec.querySelector('.relation').value.trim();
    const birth = parseInt(sec.querySelector('.birth').value, 10);
    const known = !['모르는 사람', '얼굴아님'].includes(relation);
    sec.querySelectorAll('img').forEach(img => {
      labels[img.dataset.id] = {name, relation, birth_year: Number.isFinite(birth) ? birth : null, group: Number(sec.dataset.no)};
      if (!name || !relation) noName++;
      else if (known && !Number.isFinite(birth)) noBirth++;
    });
  });
  const warn = [noName && `호칭이나 관계가 빠진 얼굴 ${noName}개`, noBirth && `생년이 빠진 얼굴 ${noBirth}개`].filter(Boolean);
  if (warn.length && !confirm(warn.join(', ') + '가 있습니다. 그대로 저장할까요?')) return;
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(labels, null, 1)], {type: 'application/json'}));
  a.download = 'labels.json'; a.click();
}
restore(); refresh();
</script></body></html>"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--threshold", type=float, default=0.45, help="코사인 거리 기준 (작을수록 잘게 나뉨)")
    args = ap.parse_args()

    faces = json.loads((args.data / "faces.json").read_text(encoding="utf-8"))
    emb = np.load(args.data / "embeddings.npy")
    labels = cluster(emb, args.threshold)
    sizes = sorted(Counter(labels.tolist()).values(), reverse=True)
    print(f"얼굴 {len(faces)}개 → 묶음 {len(sizes)}개 (상위 크기 {sizes[:12]}, 1개짜리 {sizes.count(1)}개)")
    out = args.data / "label.html"
    out.write_text(render(faces, labels, args.data), encoding="utf-8")
    print(f"라벨링 페이지: {out.resolve()}")


if __name__ == "__main__":
    main()
