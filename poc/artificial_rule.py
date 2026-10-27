"""앱의 화면 캡처 규칙(스크린샷 폴더 · 제조사 없는 PNG)에 SigLIP 점수를 더하면 무엇을 더 잡나.

두 점수(높을수록 실사가 아님):
  캡처   = max(화면 캡처 문구) - max(실사 문구)
  인물   = max(AI 생성 인물·연예인 화보 문구) - max(실사 문구)
규칙이 못 잡은 사진만 점수 순으로 접촉 시트를 만든다 → 사람이 보고 실제 가족 사진이 몇 위부터 섞이는지 센다.
사용: uv run artificial_rule.py ../eval_data/phone/meta_*.json [capture|person] [시작 순위=0] [장 수=64]
"""
import collections
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from artificial_eval import REAL, SHEETS
from boundary_check import THUMBS
from boundary_siglip import CACHE
from short_query_eval import text_vectors

SCREEN_DIRS = ("DCIM/Screenshots", "DCIM/Videocaptures")  # Scanner.kt 와 같다
PROMPTS = {"capture": ["휴대폰 화면 캡처", "웹페이지 캡처", "카카오톡 대화 캡처"],
           "person": ["AI로 생성한 인물 이미지", "연예인 화보"]}


def rule_capture(p: dict) -> bool:
    path = p.get("path") or ""
    return any(d in path for d in SCREEN_DIRS) or (p.get("make") is None and p.get("mime") == "image/png")


def folder(p: dict) -> str:
    """폴더 종류만 (이름은 안 쓴다): DCIM/Camera, Pictures/KakaoTalk 처럼 두 단계"""
    parts = (p.get("path") or "").replace("\\", "/").split("/")
    i = next((k for k, s in enumerate(parts) if s in ("DCIM", "Pictures", "Download", "Movies")), None)
    return "/".join(parts[i:i + 2]) if i is not None else "기타"


def main() -> None:
    meta = {p["id"]: p for p in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["photos"]}
    kind = sys.argv[2] if len(sys.argv) > 2 else "capture"
    start = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 64
    d = np.load(CACHE)
    ids = [int(k) for k in d.files if int(k) in meta]
    V = np.stack([d[str(i)] for i in ids])
    V /= np.linalg.norm(V, axis=1, keepdims=True)
    real = (V @ text_vectors(REAL).T).max(1)
    score = {k: (V @ text_vectors(t).T).max(1) - real for k, t in PROMPTS.items()}
    rule = np.array([rule_capture(meta[i]) for i in ids])
    print(f"사진 {len(ids)}장 · 규칙상 화면 캡처 {rule.sum()}장")
    for k, s in score.items():
        print(f"[{k}] 점수 문턱별: 전체 / 규칙 캡처 / 규칙 밖")
        for th in (0.0, 0.01, 0.02, 0.03, 0.04):
            hit = s > th
            print(f"  > {th:+.2f}: {hit.sum():5d} / {(hit & rule).sum():5d} / {(hit & ~rule).sum():5d}")
    s = score[kind]
    if kind == "person":  # 캡처로 이미 빠질 사진은 빼고 본다
        rule = rule | (score["capture"] > 0.01)
        nomake = np.array([meta[i].get("make") is None for i in ids])
        for th in (0.0, 0.005, 0.01, 0.015, 0.02):
            hit = (s > th) & ~rule
            print(f"  인물 > {th:+.3f} (캡처 뺀 나머지): {hit.sum()}장, 그중 제조사 없음 {(hit & nomake).sum()}장")
        rule = rule | ~nomake  # 아래 시트는 제조사 없는 사진만
        rank = {j: r for r, j in enumerate(j for j in np.argsort(-s) if not rule[j])}
        for f in ("Pictures/Lensa", "DCIM/PhotoDirector"):
            rs = sorted(rank[j] + 1 for j in range(len(ids)) if folder(meta[ids[j]]) == f and j in rank)
            print(f"  {f}: {len(rs)}장, 인물 점수 순위 중앙 {rs[len(rs) // 2] if rs else '-'} · 상위 100위 안 {sum(r <= 100 for r in rs)}장")
    out_rule = [j for j in np.argsort(-s) if not rule[j]]
    print(f"[{kind}] 규칙 밖 상위 {start + 1}~{start + n}위 폴더:",
          dict(collections.Counter(folder(meta[ids[j]]) for j in out_rule[start:start + n]).most_common()))
    print(f"  규칙 밖 상위 {start + n}위 점수 {s[out_rule[start + n - 1]]:+.4f}")
    pick = out_rule[start:start + n]
    cols, cell = 8, 160
    sheet = Image.new("RGB", (cols * cell, ((len(pick) + cols - 1) // cols) * (cell + 18)), "white")
    draw = ImageDraw.Draw(sheet)
    for k, j in enumerate(pick):
        x, y = (k % cols) * cell, (k // cols) * (cell + 18)
        im = Image.open(THUMBS / f"{ids[j]}.jpg")
        im.thumbnail((cell, cell))
        sheet.paste(im, (x + (cell - im.width) // 2, y))
        p = meta[ids[j]]
        draw.text((x + 2, y + cell + 2), f"{start + k + 1} {s[j]:+.3f} {'M' if p.get('make') else '-'}", fill="black")
    path = SHEETS / f"rule_{kind}_{start}.png"
    sheet.save(path)
    print(f"시트: {path} (M = 카메라 제조사 있음)")


if __name__ == "__main__":
    main()
