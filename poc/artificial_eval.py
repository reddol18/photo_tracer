"""실사가 아닌 이미지(그림·만화·화면 캡처·AI 생성 이미지·포스터) 가려내기: SigLIP 제로샷이 쓸 만한가.

인물 찾기에서 연예인 사진·AI 인물 그림·캡처 속 얼굴이 아이로 잘못 붙는다. 얼굴 찾기 전에 사진 단위로 빼고 싶다.
점수 = (가짜 쪽 문구들과의 최대 코사인) - (실사 쪽 문구들과의 최대 코사인). 높을수록 실사가 아니다.
thumb_siglip.npz(160px 썸네일을 384로 키운 벡터, 폰보다 불리)에 있는 사진만 본다.
점수 순 접촉 시트를 eval_data/sheets/artificial_*.png 로 만든다(번호만 쓰고 파일 이름은 안 쓴다 — 시트는 eval_data 밖으로 안 나간다).
사용: uv run artificial_eval.py [시트 시작 순위=0] [장 수=64]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from boundary_siglip import CACHE
from boundary_check import THUMBS
from short_query_eval import text_vectors

REAL = ["휴대폰 카메라로 찍은 사진", "실제 사람을 찍은 사진", "가족 사진", "아이를 찍은 사진", "풍경 사진", "음식 사진"]
FAKE = ["만화 그림", "일러스트", "애니메이션 캐릭터", "휴대폰 화면 캡처", "웹페이지 캡처", "카카오톡 대화 캡처",
        "AI로 생성한 인물 이미지", "광고 포스터", "연예인 화보", "글자가 있는 이미지", "그림책 페이지", "아이가 그린 그림"]
SHEETS = Path(__file__).parent.parent / "eval_data" / "sheets"


def main() -> None:
    start = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    d = np.load(CACHE)
    ids = np.array([int(k) for k in d.files])
    V = np.stack([d[k] for k in d.files])
    V /= np.linalg.norm(V, axis=1, keepdims=True)
    if len(sys.argv) > 3:  # 문구 번호만 골라 쓰기: 예) 3,4,5,6,8
        keep = [int(x) for x in sys.argv[3].split(",")]
        FAKE[:] = [FAKE[j] for j in keep]
    R, F = text_vectors(REAL), text_vectors(FAKE)
    sr, sf = V @ R.T, V @ F.T
    score = sf.max(1) - sr.max(1)
    order = np.argsort(-score)
    print(f"사진 {len(ids)}장 · 점수 분포 (가짜-실사):")
    for q in (50, 75, 90, 95, 98, 99):
        print(f"  상위 {100 - q}% 경계 {np.percentile(score, q):+.4f}")
    for th in (0.0, 0.01, 0.02, 0.03):
        print(f"  점수 > {th:+.2f}: {int((score > th).sum())}장")
    pick = order[start:start + n]
    cols, cell = 8, 160
    sheet = Image.new("RGB", (cols * cell, ((len(pick) + cols - 1) // cols) * (cell + 18)), "white")
    draw = ImageDraw.Draw(sheet)
    for k, i in enumerate(pick):
        x, y = (k % cols) * cell, (k // cols) * (cell + 18)
        im = Image.open(THUMBS / f"{ids[i]}.jpg")
        im.thumbnail((cell, cell))
        sheet.paste(im, (x + (cell - im.width) // 2, y))
        top = FAKE[int(sf[i].argmax())]
        draw.text((x + 2, y + cell + 2), f"{start + k + 1} {score[i]:+.3f} {np.argmax(sf[i])}", fill="black")
    out = SHEETS / f"artificial_{start}.png"
    sheet.save(out)
    print(f"시트: {out} ({start + 1}~{start + len(pick)}위) — 숫자 뒤 마지막 값은 FAKE 문구 번호")
    for j, t in enumerate(FAKE):
        print(f"  {j}: {t}")


if __name__ == "__main__":
    main()
