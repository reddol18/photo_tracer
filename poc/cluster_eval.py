"""자동 묶음 방식 비교(이슈 #6): 폰이 쓴 cluster_eval.csv(People.debugEval)로 묶음이 얼마나 섞이고 쪼개지는지 잰다.

정답: 사용자가 정답으로 표시한 얼굴(ref) — 강한 정답. 인물 찾기가 붙인 얼굴(who) — 약한 정답(표본 검사로 대부분 맞음).
화면에 보이는 묶음(사진 3장 이상)만 센다. 재는 것:
  묶음 수            화면에 보이는 묶음 개수
  섞인 묶음          정답이 있는 얼굴 중 두 사람 이상이 든 묶음 수 / 정답이 있는 묶음 수
  순도               정답 얼굴 중 그 묶음의 다수 인물인 비율
  쪼개짐(인물별)      그 사람 정답 얼굴이 흩어진 화면 묶음 수, 가장 큰 묶음에 든 비율
  중심과 먼 얼굴      묶음 중심 코사인이 낮은 얼굴 비율(정답 없는 낯선 얼굴이 끼는 정도의 대리 지표)
번호·점수만 다루고 사진은 안 본다. 결과는 eval_data/sheets/cluster_eval.txt.
사용: uv run cluster_eval.py ../eval_data/phone/cluster_eval.csv
"""
import csv
import sys
from collections import Counter, defaultdict

from artificial_eval import SHEETS

MIN_SHOW = 3  # People.MIN_SHOW


def main() -> None:
    rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
    variants = [k for k in rows[0] if k not in ("face", "photo", "side", "ref", "who", "fake") and not k.endswith("_sim")]
    out = [f"얼굴 {len(rows)}개 · 정답 얼굴 {sum(1 for r in rows if r['ref'])}개 · 찾은 얼굴 {sum(1 for r in rows if r['who'])}개"]
    head = "방식                 묶음  섞임(정답)  순도(정답)  섞임(찾음)  순도(찾음)  흩어진 묶음 수(정답, 인물 중앙)  큰 묶음 비율(정답)  중심<0.4"
    out.append(head)
    for v in variants:
        photos = defaultdict(set)
        for r in rows:
            if r[v] != "-1":
                photos[r[v]].add(r["photo"])
        shown = {c for c, ps in photos.items() if len(ps) >= MIN_SHOW}
        line = [f"{v:20s} {len(shown):5d}"]
        for key in ("ref", "who"):
            lab = defaultdict(list)
            for r in rows:
                if r[v] in shown and r[key]:
                    lab[r[v]].append(r[key])
            mixed = sum(len(set(ls)) > 1 for ls in lab.values())
            pure = sum(Counter(ls).most_common(1)[0][1] for ls in lab.values()) / max(1, sum(len(ls) for ls in lab.values()))
            line.append(f"{mixed:4d}/{len(lab):<4d}   {pure:6.1%}  ")
        # 쪼개짐: 정답 얼굴 기준, 인물마다 화면 묶음 몇 개에 흩어졌나, 가장 큰 묶음 비율(안 보이는 묶음에 간 얼굴은 분모에만)
        per = defaultdict(list)
        for r in rows:
            if r["ref"]:
                per[r["ref"]].append(r[v] if r[v] in shown else None)
        spread = sorted(len({c for c in cs if c}) for cs in per.values())
        big = sum(max(Counter(c for c in cs if c).values(), default=0) for cs in per.values()) / sum(len(cs) for cs in per.values())
        far = sum(1 for r in rows if r[v] in shown and float(r[f"{v}_sim"]) < 0.4) / max(1, sum(1 for r in rows if r[v] in shown))
        line.append(f"   {spread[len(spread) // 2]:3d} (최대 {spread[-1]:3d})                 {big:6.1%}        {far:6.1%}")
        out.append(" ".join(line))
    (SHEETS / "cluster_eval.txt").write_text("\n".join(out), encoding="utf-8")
    print("\n".join(out))


if __name__ == "__main__":
    main()
