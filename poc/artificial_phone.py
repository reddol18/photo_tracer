"""폰이 매긴 실사 아닌 이미지 점수(앱 폴더 fake_scores.csv: id, cap, person)로 Fake.kt 문턱 고르기.

카메라 정보 없는 사진만 점수가 있다. 점수 순으로 썸네일 접촉 시트를 만들어 사람이 보고, 실제 가족 사진이 섞이기 시작하는 점수를 찾는다.
PC 썸네일 점수(artificial_rule.py)는 채팅으로 받은 사진에서 폰보다 낮게 나와 그 문턱을 그대로 쓸 수 없었다.
사용: uv run artificial_phone.py ../eval_data/phone/fake_scores.csv cap|person [시작 순위=0] [장 수=64] [cap 문턱(person 볼 때 이걸 넘는 건 뺌)]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from artificial_eval import SHEETS
from boundary_check import THUMBS


def main() -> None:
    rows = np.loadtxt(sys.argv[1], delimiter=",", skiprows=1)
    kind = sys.argv[2]
    start = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 64
    ids, cap, person = rows[:, 0].astype(np.int64), rows[:, 1], rows[:, 2]
    print(f"점수 있는 사진 {len(ids)}장 (썸네일 있음 {sum((THUMBS / f'{i}.jpg').exists() for i in ids)}장)")
    for name, s in (("cap", cap), ("person", person)):
        print(f"[{name}] " + " · ".join(f"> {th:+.2f}: {(s > th).sum()}" for th in (-0.02, -0.01, 0.0, 0.01, 0.02, 0.03, 0.04)))
    s = cap if kind == "cap" else person
    keep = np.ones(len(ids), bool)
    if kind == "person" and len(sys.argv) > 5:
        keep = cap <= float(sys.argv[5])
        print(f"cap > {sys.argv[5]} 은 캡처로 빠지므로 뺌: 남은 {keep.sum()}장")
    order = [j for j in np.argsort(-s) if keep[j] and (THUMBS / f"{ids[j]}.jpg").exists()]
    pick = order[start:start + n]
    cols, cell = 8, 160
    sheet = Image.new("RGB", (cols * cell, ((len(pick) + cols - 1) // cols) * (cell + 18)), "white")
    draw = ImageDraw.Draw(sheet)
    for k, j in enumerate(pick):
        x, y = (k % cols) * cell, (k // cols) * (cell + 18)
        im = Image.open(THUMBS / f"{ids[j]}.jpg")
        im.thumbnail((cell, cell))
        sheet.paste(im, (x + (cell - im.width) // 2, y))
        draw.text((x + 2, y + cell + 2), f"{start + k + 1} {s[j]:+.3f}", fill="black")
    out = SHEETS / f"phone_{kind}_{start}.png"
    sheet.save(out)
    print(f"시트: {out} ({start + 1}~{start + len(pick)}위, 점수 {s[pick[0]]:+.3f} ~ {s[pick[-1]]:+.3f})")


if __name__ == "__main__":
    main()
