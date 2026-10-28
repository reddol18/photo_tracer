"""폰 '찾음' 점검(앱 폴더 who_found.csv): 찾은 얼굴과 가장 닮은 정답 얼굴을 나란히 놓은 접촉 시트를 만든다.

연예인 사진·AI 그림이 등록한 인물로 붙는 까닭(이슈 #4)을 본다: 실사 판정을 빠져나갔나(카메라 정보, 점수), 어느 정답과 닮았나.
시트와 요약은 eval_data 밖으로 나가지 않는다(가족 사진).
사용: uv run who_found.py ../eval_data/phone/who_found.csv [인물 번호] [정렬: sim|pscore|cap|low|rand] [개수]
"""
import csv
import random
import sys
from collections import Counter

from PIL import Image, ImageDraw

from artificial_eval import SHEETS
from boundary_check import THUMBS


def crop(photo: str, row: dict | None, cell: int) -> Image.Image:
    """썸네일에 얼굴 상자를 그리고 cell 크기로. 썸네일이 없으면 회색"""
    path = THUMBS / f"{photo}.jpg"
    if not path.exists():
        return Image.new("RGB", (cell, cell), "gray")
    im = Image.open(path).convert("RGB")
    if row:
        x, y, w, h = (float(row[k]) * s for k, s in zip("xywh", (im.width, im.height, im.width, im.height)))
        ImageDraw.Draw(im).rectangle([x, y, x + w, y + h], outline="lime", width=max(2, im.width // 100))
    im.thumbnail((cell, cell))
    return im


def main() -> None:
    rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
    person = sys.argv[2] if len(sys.argv) > 2 else None
    key = sys.argv[3] if len(sys.argv) > 3 else "sim"
    out = []
    out.append(f"찾음 얼굴 {len(rows)}개")
    out.append("날짜 근거: " + str(Counter(r["date_source"] for r in rows)))
    out.append("카메라 정보 없음 (근거, 벡터, 판정): " + str(Counter((r["date_source"], r["vec"], r["fake"]) for r in rows if r["date_source"] != "카메라")))
    out.append("인물별: " + str(Counter(r["person"] for r in rows).most_common()))
    out.append("폴더(카메라 정보 있음): " + str(Counter(r["dir"] for r in rows if r["date_source"] == "카메라").most_common(10)))
    out.append("폴더(없음): " + str(Counter(r["dir"] for r in rows if r["date_source"] != "카메라").most_common(10)))
    sel = [r for r in rows if person is None or r["person"] == person]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else len(sel)
    if key == "rand":  # 무작위 표본(고정 씨앗): 전체 정확도 가늠
        random.Random(0).shuffle(sel)
    elif key == "low":  # 기준(0.45)에 가까운 것부터: 틀린 것이 모일 만한 곳
        sel.sort(key=lambda r: float(r["sim"]))
    else:
        num = lambda r: float(r[key]) if r[key] else -9.0
        sel.sort(key=num, reverse=True)
    sel = sel[:limit]
    # 왼쪽: 찾은 사진(상자), 오른쪽: 가장 닮은 정답 얼굴 사진(상자). 아래: 순번, 유사도, 출처, 점수
    cell, cols = 200, 3
    refs = {r["ref_face"]: r for r in rows}  # 정답 얼굴 상자는 who_found에 없다 → 상자 없이
    sheet = Image.new("RGB", (cols * (2 * cell + 10), ((len(sel) + cols - 1) // cols) * (cell + 30)), "white")
    draw = ImageDraw.Draw(sheet)
    for k, r in enumerate(sel):
        x, y = (k % cols) * (2 * cell + 10), (k // cols) * (cell + 30)
        sheet.paste(crop(r["photo"], r, cell), (x, y))
        sheet.paste(crop(r["ref_photo"], None, cell), (x + cell, y))
        src = "cam" if r["date_source"] == "카메라" else "nocam"
        draw.text((x + 2, y + cell + 2), f"{k + 1} sim{float(r['sim']):.2f} {src} p{r['pscore'] or '-'} c{r['cap'] or '-'}"[:60], fill="black")
        draw.text((x + 2, y + cell + 15), f"photo {r['photo']} ref {r['ref_photo']}", fill="gray")
    name = SHEETS / f"who_found_{person or 'all'}_{key}.png"
    sheet.save(name)
    out.append(f"시트: {name} ({len(sel)}개)")
    (SHEETS / f"who_found_{person or 'all'}.txt").write_text("\n".join(out), encoding="utf-8")
    print(f"시트 {name}, 요약 {SHEETS / f'who_found_{person or 'all'}.txt'}")


if __name__ == "__main__":
    main()
