"""장면 검색 순위 비교(이슈 #7): 폰이 쓴 search_eval.csv(Search.debugEval)로 예전·새 방식 상위 칸을 나란히 놓은 시트를 만든다.

예전 = 실사 아닌 이미지도 함께. 새 = 실사 아닌 이미지는 뒤로 (구간은 둘 다 가장 닮은 한 장으로 겨룸).
빨간 테두리 = 실사 아닌 이미지 판정, n = 그 구간에서 장면 벡터가 있는 사진 수(구간 밖 낱장은 1).
시트는 eval_data 밖으로 나가지 않는다(가족 사진).
사용: uv run scene_rank_eval.py ../eval_data/phone/search_eval.csv 검색어목록.txt [상위 개수]
(search_eval.py는 0단계 구간 설명 검색 평가 — 다른 파일)
"""
import csv
import sys
from collections import defaultdict

from PIL import Image, ImageDraw

from artificial_eval import SHEETS
from boundary_check import THUMBS


def thumb(photo: str, cell: int, fake: bool) -> Image.Image:
    path = THUMBS / f"{photo}.jpg"
    im = Image.open(path).convert("RGB") if path.exists() else Image.new("RGB", (cell, cell), "gray")
    im.thumbnail((cell, cell))
    if fake:  # 실사 아닌 이미지 판정: 빨간 테두리
        ImageDraw.Draw(im).rectangle([0, 0, im.width - 1, im.height - 1], outline="red", width=4)
    return im


def main() -> None:
    rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
    queries = open(sys.argv[2], encoding="utf-8").read().split("\n")
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    runs = defaultdict(list)
    for r in rows:
        runs[(int(r["query"]), r["method"])].append(r)
    summary = []
    cell, pad = 120, 4
    for k, q in enumerate(queries):
        old, new = runs[(k, "old")][:top], runs[(k, "new")][:top]
        if not old:
            continue
        keys = lambda rs: {(r["kind"], r["id"]) for r in rs}
        same = len(keys(old) & keys(new))
        fakes = lambda rs: sum(r["fake"] == "1" for r in rs)
        summary.append(f"{k}\t{q}\t상위{top} 같은 칸 {same}\t실사아님 예전 {fakes(old)} → 새 {fakes(new)}")
        # 위 줄: 예전, 아래 줄: 새. 칸 아래 순위·점수·구간의 벡터 장 수
        sheet = Image.new("RGB", (top * (cell + pad), 2 * (cell + 28)), "white")
        draw = ImageDraw.Draw(sheet)
        for line, rs in enumerate((old, new)):
            for i, r in enumerate(rs):
                x, y = i * (cell + pad), line * (cell + 28)
                sheet.paste(thumb(r["cover"], cell, r["fake"] == "1"), (x, y))
                draw.text((x + 2, y + cell + 2), f"{r['rank']} {float(r['score']):.3f} n{r['nvec']}", fill="black")
                draw.text((x + 2, y + cell + 14), ("old " if line == 0 else "new ") + r["cover"], fill="gray")
        sheet.save(SHEETS / f"search_eval_{k}.png")
    (SHEETS / "search_eval.txt").write_text("\n".join(summary), encoding="utf-8")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
