"""구간 확인 결과(event_review.json)를 구간 규칙과 맞춰 본다: 어떤 경계가 틀렸고, 왜 그렇게 잘렸는지.

사용: uv run review_analysis.py ../eval_data/phone/meta_*.json ../eval_data/event_review.json
  - 옮긴 사진: 옮겨진 쪽(from)과 받은 쪽(to) 사이 경계의 시간 차·거리, 그리고 from 구간이 통째로 옮겨졌는지
  - 섞임: 구간 안에서 가장 긴 공백과 가장 먼 이동 — 어디서 잘랐어야 했는지 후보
"""
import json
import sys
from pathlib import Path

from time_events import km, source, split_place, taken


def fmt(sec: float) -> str:
    return f"{sec / 60:.0f}분" if sec < 3600 else f"{sec / 3600:.1f}시간"


def main() -> None:
    P = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["photos"]
    review = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    shot = sorted(({**p, "t": t} for p in P if source(p) in ("카메라", "기타 EXIF") and (t := taken(p))),
                  key=lambda p: p["t"])
    events = split_place(shot, 3, 1.0)
    where = {p["id"]: i for i, e in enumerate(events) for p in e}

    print("== 옮긴 사진 (from → to)")
    pairs = {}
    for m in review["moved"]:
        assert where[m["id"]] == m["from"], m
        pairs.setdefault((m["from"], m["to"]), []).append(m["id"])
    for (f, to), ids in sorted(pairs.items()):
        a, b = (events[to], events[f]) if to < f else (events[f], events[to])
        gap = (b[0]["t"] - a[-1]["t"]).total_seconds()
        la = next((p for p in reversed(a) if "lat" in p), None)
        lb = next((p for p in b if "lat" in p), None)
        dist = f"{km(la, lb):.1f}km" if la and lb else "GPS 없음"
        src = events[f]
        pos = sorted(i for i, p in enumerate(src) if p["id"] in set(ids))
        edge = "앞쪽" if pos[0] == 0 else "뒤쪽" if pos[-1] == len(src) - 1 else "가운데"
        print(f"  {f}→{to}: {len(ids)}장 옮김 / from {len(src)}장 · 경계 공백 {fmt(gap)} · 거리 {dist}"
              f" · from 구간의 {edge} · {src[0]['t']:%Y-%m-%d %H:%M}–{src[-1]['t']:%H:%M}")

    print("== 섞임 구간: 안쪽 공백·이동 상위 3개")
    for i in review["mixed"]:
        e = events[i]
        gaps = sorted(((b["t"] - a["t"]).total_seconds(), a["t"]) for a, b in zip(e, e[1:]))[::-1][:3]
        g = [p for p in e if "lat" in p]
        far = max((km(a, b) for a in g for b in g), default=0)
        print(f"  {i}: {len(e)}장 · {e[0]['t']:%Y-%m-%d %H:%M}–{e[-1]['t']:%H:%M} · GPS {len(g)}장 · 최대 거리 {far:.1f}km"
              f" · 공백 " + ", ".join(f"{fmt(s)}({t:%H:%M} 뒤)" for s, t in gaps))

    # 규칙 후보 채점. 옮김은 "받은 구간과 이어져야 함", 섞임은 "안에서 한 번은 잘려야 함"으로 본다.
    # 표시 안 한 구간·경계는 맞은 것으로 보고, 새로 생긴 경계(안 섞인 구간 안)·사라진 경계(합치라고 안 한 곳)를 비용으로 센다.
    join = {(min(f, to), max(f, to)) for f, to in pairs}
    mixed = set(review["mixed"])
    old_cut = {e[0]["id"] for e in events[1:]}  # 경계 = 구간 첫 사진
    joined_cut = {events[b][0]["id"] for a, b in join if b == a + 1}
    print("== 규칙 후보: 맞춘 옮김/섞임 · 잘못 새로 자름 · 잘못 없앤 경계 · 구간 수")
    for gap_h in (1, 1.5, 2, 3):
        for move in (1.0, 3.0, 10.0, 1e9):
            ev = split_place(shot, gap_h, move)
            cut = {e[0]["id"] for e in ev[1:]}
            ok_join = sum(1 for a, b in join if not any(where[c] > a and where[c] <= b for c in cut))
            ok_mixed = sum(1 for i in mixed if any(where[c] == i and c not in old_cut for c in cut))
            bad_new = sum(1 for c in cut - old_cut if where[c] not in mixed)
            bad_gone = len(old_cut - cut - joined_cut)
            print(f"  {gap_h}시간 · {'이동 무시' if move > 1e8 else f'{move:g}km'}: 옮김 {ok_join}/{len(join)} · "
                  f"섞임 {ok_mixed}/{len(mixed)} · 새로 자름 {bad_new} · 없앤 경계 {bad_gone} · {len(ev)}개")


if __name__ == "__main__":
    main()
