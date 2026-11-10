"""작은 얼굴의 인물 찾기 정확도(이슈 #9): 폰이 쓴 small_eval.csv·small_found.csv(Who.debugSmall)를 요약한다.

small_eval: 크게 찍힌 정답 얼굴의 사진을 줄여 얼굴을 32~96px로 만든 뒤 실제와 같은 검출·SFace·붙이는 규칙을 적용한 결과.
  크기마다: 못 찾음(검출 안 됨), 찾음-맞음, 찾음-틀림(다른 사람), 확인 필요(맞음/틀림), 안 붙음.
  그리고 '찾음' 기준을 크기마다 올리면(0.45 → 0.50 …) 틀림·맞음이 얼마나 줄어드나.
small_found: 지금 붙은 얼굴(찾음·확인 필요)의 크기 분포 — 크기 기준을 바꾸면 몇 개가 영향을 받나.
번호·점수만 다룬다.
사용: uv run small_face_eval.py ../eval_data/phone/small_eval.csv ../eval_data/phone/small_found.csv
"""
import csv
import sys
from collections import Counter

MARGIN = 0.10


def main() -> None:
    allrows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
    found = list(csv.DictReader(open(sys.argv[2], encoding="utf-8")))
    # 남(person -1, 등록 안 한 사람으로 보이는 자동 묶음의 얼굴): 줄였을 때 가족으로 붙으면 잘못 붙은 것
    strangers = [r for r in allrows if r["person"] == "-1"]
    rows = [r for r in allrows if r["person"] != "-1"]
    if strangers:
        print(f"남 {len({r['face'] for r in strangers})}개: 크기별 가족으로 붙은 비율 (찾음 / 확인 필요), 찾음 기준을 올리면")
        ths = [0.45, 0.50, 0.55, 0.60]
        print("크기   못찾음   찾음    확인필요   " + "  ".join(f"찾음@{th:.2f}" for th in ths))
        for t in sorted({float(r["target"]) for r in strangers}):
            rs = [r for r in strangers if float(r["target"]) == t]
            n = len(rs)
            miss = sum(r["detected"] == "0" for r in rs)
            f = sum(r["result"] == "found" for r in rs); m = sum(r["result"] == "maybe" for r in rs)
            at = [sum(r["detected"] == "1" and float(r["sim"]) >= th and float(r["sim"]) - float(r["second"]) >= MARGIN for r in rs) for th in ths]
            print(f"{int(t):4d}  {miss / n:6.1%}  {f / n:6.1%}  {m / n:6.1%}     " + "  ".join(f"{a / n:9.1%}" for a in at))
        print()
    print(f"정답 얼굴 {len({r['face'] for r in rows})}개 × 크기 {sorted({int(float(r['target'])) for r in rows})}")
    print("크기   못찾음  찾음-맞음  찾음-틀림  확인필요-맞음  확인필요-틀림  안붙음")
    for t in sorted({float(r["target"]) for r in rows}):
        rs = [r for r in rows if float(r["target"]) == t]
        c = Counter()
        for r in rs:
            if r["detected"] == "0":
                c["miss"] += 1
            elif r["result"] == "none":
                c["none"] += 1
            else:
                c[f"{r['result']}-{'ok' if r['best'] == r['person'] else 'bad'}"] += 1
        n = len(rs)
        pct = lambda k: f"{c[k] / n:6.1%}"
        print(f"{int(t):4d}  {pct('miss')}   {pct('found-ok')}    {pct('found-bad')}      {pct('maybe-ok')}       {pct('maybe-bad')}   {pct('none')}")
    # 크기별로 찾음 기준을 올리면
    print("\n찾음 기준을 올리면 (크기별, 찾음-맞음 / 찾음-틀림)")
    ths = [0.45, 0.50, 0.55, 0.60]
    print("크기  " + "  ".join(f"{th:.2f}" + " " * 8 for th in ths))
    for t in sorted({float(r["target"]) for r in rows}):
        rs = [r for r in rows if float(r["target"]) == t and r["detected"] == "1"]
        line = []
        for th in ths:
            hit = [r for r in rs if float(r["sim"]) >= th and float(r["sim"]) - float(r["second"]) >= MARGIN]
            ok = sum(r["best"] == r["person"] for r in hit)
            line.append(f"{ok:3d} / {len(hit) - ok:3d}    ")
        print(f"{int(t):4d}  " + "  ".join(line))
    # 지금 붙은 얼굴의 크기 분포
    print("\n지금 붙은 얼굴 크기(검출 해상도 짧은 변)")
    bins = [(0, 40), (40, 48), (48, 64), (64, 96), (96, 10_000)]
    for kind in ("found", "maybe"):
        fs = [f for f in found if f["kind"] == kind]
        cnt = Counter(next(f"{a}-{b if b < 10_000 else ''}" for a, b in bins if a <= int(f["side"]) < b) for f in fs)
        print(f"  {kind:5s} {len(fs):5d}개: " + ", ".join(f"{k}px {cnt[k]}" for k in (f"{a}-{b if b < 10_000 else ''}" for a, b in bins)))


if __name__ == "__main__":
    main()
