"""사람 없는 AI 그림 판정 문구 고르기(이슈 #8): 지금 판정(Fake.kt)은 'AI 인물 이미지·연예인 화보' 문구라 AI 고양이·판타지 장면은
점수가 낮아 장면 검색에 남는다. 그림 문구 후보로 (그림 문구 최대 - 실사 문구 최대) 점수를 매겨, 카메라 정보 없는 사진의
상위를 시트로 본다(실사가 어디서부터 섞이나). PC 벡터(0단계, 160px 썸네일)라 폰 점수와 차이가 있다 — 문턱은 폰에서 다시 고른다.
사용: uv run art_prompts.py ../eval_data/phone/meta_*.json [시작 순위=0] [장 수=64] [확인할 사진 id,...]

결과(2026-11-10, 앱에 넣지 않음): PC 벡터로는 상위 64장이 모두 AI 그림·캡처였지만, 폰 점수로 이미 뒤로 가는 사진(fake·만든 이미지 점수>0)을
빼고 보니 새로 걸리는 상위는 대부분 실사였다(카메라 정보 없는 펫캠·홈캠 실내 화면, 고양이). AI 그림은 이미 앞 단계에서 대부분 걸러져 있었다.
수영장 검색의 AI 고양이(1000002737)도 PC에서 2,924위로 안 걸렸다.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from artificial_eval import REAL, SHEETS
from boundary_check import THUMBS
from boundary_siglip import CACHE
from short_query_eval import text_vectors

ART = ["AI로 생성한 그림", "디지털 아트", "판타지 일러스트", "3D 렌더링 이미지", "AI가 만든 동물 그림", "컴퓨터 그래픽 이미지"]


def main() -> None:
    meta = {p["id"]: p for p in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["photos"]}
    start = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 64
    watch = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else []
    d = np.load(CACHE)
    ids = [int(k) for k in d.files if int(k) in meta and meta[int(k)].get("make") is None]  # 카메라 정보 없는 사진만(앱과 같다)
    V = np.stack([d[str(i)] for i in ids]); V /= np.linalg.norm(V, axis=1, keepdims=True)
    real = (V @ text_vectors(REAL).T).max(1)
    A = V @ text_vectors(ART).T
    score = A.max(1) - real
    order = np.argsort(-score)
    rank = {ids[j]: r + 1 for r, j in enumerate(order)}
    print(f"카메라 정보 없는 사진 {len(ids)}장 · 점수 문턱별 장 수: " + ", ".join(f"> {t:+.3f}: {(score > t).sum()}" for t in (-0.01, 0.0, 0.005, 0.01, 0.02)))
    for w in watch:
        print(f"  사진 {w}: " + (f"{rank[w]}위, 점수 {score[ids.index(w)]:+.4f}, 가장 닮은 문구 {ART[int(A[ids.index(w)].argmax())]}" if w in rank else "없음(카메라 정보 있음 또는 PC 벡터 없음)"))
    pick = order[start:start + n]
    cols, cell = 8, 160
    sheet = Image.new("RGB", (cols * cell, ((len(pick) + cols - 1) // cols) * (cell + 18)), "white")
    draw = ImageDraw.Draw(sheet)
    for k, j in enumerate(pick):
        x, y = (k % cols) * cell, (k // cols) * (cell + 18)
        p = THUMBS / f"{ids[j]}.jpg"
        im = Image.open(p) if p.exists() else Image.new("RGB", (cell, cell), "gray")
        im.thumbnail((cell, cell))
        sheet.paste(im, (x + (cell - im.width) // 2, y))
        draw.text((x + 2, y + cell + 2), f"{start + k + 1} {score[j]:+.3f} a{int(A[j].argmax())}", fill="black")
    out = SHEETS / f"art_{start}.png"
    sheet.save(out)
    print(f"시트: {out} ({start + 1}~{start + len(pick)}위) — a 뒤 숫자는 가장 닮은 문구 번호: " + ", ".join(f"{i} {t}" for i, t in enumerate(ART)))


if __name__ == "__main__":
    main()
