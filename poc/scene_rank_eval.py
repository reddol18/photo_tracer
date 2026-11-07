"""장면 검색 순위 비교(이슈 #7): 폰이 쓴 후보 칸 표(Search.debugEval → search_eval.csv)로 순위 방식을 PC에서 다시 계산해 비교한다.

폰은 검색어마다 후보 칸(낱말 검색어 a, 문형 묶음 b 각각의 상위 150칸 합집합)과 칸마다 표지 사진·점수·실사 판정·
만든 이미지 점수·또렷함(lap)·색 다양함(std)만 내보낸다(벡터·사진은 폰 밖으로 안 나감).
방식(앞 방식에 하나씩 더함):
  old   예전: 낱말, 실사 아닌 이미지도 함께
  fake  실사 아닌 이미지(fake 1·2)는 뒤로
  soft  + 만든 이미지 점수가 SOFT 넘는 카메라 정보 없는 사진도 뒤로 (검색에서만 낮춘 문턱)
  tmpl  + 검색어 문형 묶음(b)
  dull  + 또렷함·색 다양함이 낮은 사진(내용 없는 사진) 뒤로
시트: 방식마다 한 줄, 상위 N칸. 빨간 테두리 = 실사 아닌 이미지 판정(fake), 주황 = soft로 새로 뒤로 간 사진.
시트는 eval_data 밖으로 나가지 않는다(가족 사진).
사용: uv run scene_rank_eval.py ../eval_data/phone/search_eval2.csv 검색어목록.txt [상위 개수] [SOFT] [LAP] [STD]
(search_eval.py는 0단계 구간 설명 검색 평가 — 다른 파일)
"""
import csv
import sys
from collections import defaultdict

from PIL import Image, ImageDraw

from artificial_eval import SHEETS
from boundary_check import THUMBS


def thumb(photo: str, cell: int, color: str | None) -> Image.Image:
    path = THUMBS / f"{photo}.jpg"
    im = Image.open(path).convert("RGB") if path.exists() else Image.new("RGB", (cell, cell), "gray")
    im.thumbnail((cell, cell))
    if color:
        ImageDraw.Draw(im).rectangle([0, 0, im.width - 1, im.height - 1], outline=color, width=4)
    return im


def main() -> None:
    rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
    queries = open(sys.argv[2], encoding="utf-8").read().split("\n")
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    soft = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    lap_min = float(sys.argv[5]) if len(sys.argv) > 5 else 30.0
    std_min = float(sys.argv[6]) if len(sys.argv) > 6 else 25.0
    by_q = defaultdict(list)
    for r in rows:
        by_q[int(r["query"])].append(r)

    def cell(r: dict, side: str) -> dict:
        person = r[f"person_{side}"]
        return {"cover": r[f"cover_{side}"], "score": float(r[f"score_{side}"]), "fake": r[f"fake_{side}"] != "0",
                "soft": person != "" and float(person) > soft, "lap": float(r[f"lap_{side}"]), "std": float(r[f"std_{side}"]),
                "key": (r["kind"], r["id"])}

    def ranked(rs: list[dict], method: str) -> list[dict]:
        side = "b" if method in ("tmpl", "dull") else "a"
        cs = [cell(r, side) for r in rs]
        def back(c):  # 뒤로 보낼 칸이면 True
            if method == "old":
                return False
            b = c["fake"]
            if method != "fake":
                b = b or c["soft"]
            if method == "dull":
                b = b or (0 <= c["lap"] < lap_min and 0 <= c["std"] < std_min)
            return b
        return sorted(cs, key=lambda c: (back(c), -c["score"]))[:top]

    methods = ["old", "fake", "soft", "tmpl", "dull"]
    summary = [f"상위 {top} · SOFT {soft} · 내용 없음: lap<{lap_min} 그리고 std<{std_min}",
               "검색어\t" + "\t".join(f"{m}(실사아님/soft/dull)" for m in methods)]
    cellpx, pad = 110, 4
    for k, q in enumerate(queries):
        rs = by_q.get(k)
        if not rs:
            continue
        line = [q]
        sheet = Image.new("RGB", (top * (cellpx + pad) + 50, len(methods) * (cellpx + 16)), "white")
        draw = ImageDraw.Draw(sheet)
        for j, m in enumerate(methods):
            res = ranked(rs, m)
            line.append(f"{sum(c['fake'] for c in res)}/{sum(c['soft'] and not c['fake'] for c in res)}/"
                        f"{sum((0 <= c['lap'] < lap_min and 0 <= c['std'] < std_min) for c in res)}")
            y = j * (cellpx + 16)
            draw.text((2, y + 2), m, fill="black")
            for i, c in enumerate(res):
                color = "red" if c["fake"] else "orange" if c["soft"] else None
                x = 50 + i * (cellpx + pad)
                sheet.paste(thumb(c["cover"], cellpx, color), (x, y))
                draw.text((x + 2, y + cellpx + 2), f"{c['score']:.3f} L{c['lap']:.0f} S{c['std']:.0f}", fill="gray")
        sheet.save(SHEETS / f"scene_rank_{k}.png")
        summary.append("\t".join(line))
    (SHEETS / "scene_rank.txt").write_text("\n".join(summary), encoding="utf-8")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
