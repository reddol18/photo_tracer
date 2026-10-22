"""구간 사진을 접촉 인화지(한 장에 구간 10개) PNG로 만든다 — Claude가 직접 보고 구간 설명 정답을 쓰기 위한 입력.

사용: uv run contact_sheets.py ../eval_data/phone/meta_*.json
구간은 segments.py(사용자 판정 모두 반영). 구간마다 시간상 고르게 최대 8장, 줄 앞에 구간 번호를 크게 쓴다.
결과: eval_data/sheets/sheet_NN.png 와 sheets/index.json(시트별 구간 번호·키·시각·사진 수). 가족 사진이므로 로컬 전용.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from boundary_check import THUMBS
from segments import EVAL, final_events

PER_SHEET, PER_ROW, CELL, LABEL = 10, 8, 112, 90


def main() -> None:
    events, unresolved, _ = final_events(Path(sys.argv[1]))
    out = EVAL / "sheets"
    out.mkdir(exist_ok=True)
    font = ImageFont.load_default(size=30)
    index = []
    for s in range(0, len(events), PER_SHEET):
        chunk = list(enumerate(events))[s:s + PER_SHEET]
        sheet = Image.new("RGB", (LABEL + PER_ROW * (CELL + 4), len(chunk) * (CELL + 8)), "white")
        draw = ImageDraw.Draw(sheet)
        rows = []
        for r, (i, e) in enumerate(chunk):
            y = r * (CELL + 8)
            draw.text((8, y + CELL // 2 - 18), str(i), fill="black", font=font)
            step = max(1, len(e) / PER_ROW)
            for c, p in enumerate([e[int(j * step)] for j in range(min(PER_ROW, len(e)))]):
                with Image.open(THUMBS / f"{p['id']}.jpg") as im:
                    im = im.convert("RGB")
                    im.thumbnail((CELL, CELL))
                    sheet.paste(im, (LABEL + c * (CELL + 4), y + (CELL - im.height) // 2))
            rows.append({"event": i, "key": e[0]["id"], "start": e[0]["t"].isoformat(), "end": e[-1]["t"].isoformat(),
                         "photos": len(e), "unresolved": i in unresolved})
        name = f"sheet_{s // PER_SHEET:02d}.png"
        sheet.save(out / name)
        index.append({"sheet": name, "events": rows})
    (out / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{out} · 시트 {len(index)}장 · 구간 {len(events)}개")


if __name__ == "__main__":
    main()
