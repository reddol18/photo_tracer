"""애매한 경계(3시간 안의 공백, 1km 넘는 이동)를 사진 색 분포로 가를 수 있는지 본다. 비AI 지표만 쓴다.

사용: uv run boundary_check.py ../eval_data/phone/meta_*.json ../eval_data/event_review.json
후보 경계 = 1시간 공백 또는 1km 이동으로 자른 곳 중 3시간보다 짧은 것. 정답은 구간 확인 결과에서 가져온다:
  - 합치라고(옮기라고) 한 경계 → 같은 일,  표시 없이 남은 이동 경계 → 다른 일
  - 섞임 표시 없는 구간 안에 새로 생긴 1시간 경계 → 같은 일,  섞임 구간 안의 경계 → 어느 것이 맞는지 모름(따로 출력)
경계 양쪽 끝 사진 3장씩의 HSV 색 히스토그램 평균을 Bhattacharyya 거리로 비교한다(0 같음 ~ 1 다름).
"""
import json
import statistics
import sys
from pathlib import Path

import cv2
import numpy as np

from time_events import source, split_place, taken

THUMBS = Path(__file__).parent.parent / "eval_data" / "phone" / "thumbs"
SIDE = 3


def hist(pid: int) -> np.ndarray:
    img = cv2.imread(str(THUMBS / f"{pid}.jpg"))
    h = cv2.calcHist([cv2.cvtColor(img, cv2.COLOR_BGR2HSV)], [0, 1, 2], None, [16, 4, 4], [0, 180, 0, 256, 0, 256])
    return cv2.normalize(h, None).flatten()


def dist(a: list[dict], b: list[dict]) -> float:
    ha = np.mean([hist(p["id"]) for p in a], axis=0).astype(np.float32)
    hb = np.mean([hist(p["id"]) for p in b], axis=0).astype(np.float32)
    return cv2.compareHist(ha, hb, cv2.HISTCMP_BHATTACHARYYA)


def load_shot(meta: Path) -> list[dict]:
    P = json.loads(meta.read_text(encoding="utf-8"))["photos"]
    return sorted(({**p, "t": t} for p in P if source(p) in ("카메라", "기타 EXIF") and (t := taken(p))),
                  key=lambda p: p["t"])


def candidates(shot: list[dict]) -> list[tuple[list[dict], list[dict]]]:
    """애매한 경계 후보: 1시간 공백·1km 이동으로 자른 곳 중 3시간 넘는 공백이 아닌 곳. (앞 조각, 뒤 조각) 목록."""
    segs = split_place(shot, 1, 1.0)
    return [(a, b) for a, b in zip(segs, segs[1:]) if (b[0]["t"] - a[-1]["t"]).total_seconds() <= 3 * 3600]


def main() -> None:
    shot = load_shot(Path(sys.argv[1]))
    review = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    # 셋째 인자: boundary_review.py 페이지에서 경계마다 직접 고른 정답(있으면 이것을 쓴다)
    marked = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))["labels"] if len(sys.argv) > 3 else None
    pos = {p["id"]: i for i, p in enumerate(shot)}
    events = split_place(shot, 3, 1.0)
    where = {p["id"]: i for i, e in enumerate(events) for p in e}
    old_cut = {e[0]["id"] for e in events[1:]}
    joined = {events[max(m["from"], m["to"])][0]["id"] for m in review["moved"]}
    mixed = set(review["mixed"])

    rows = []
    for _, b in candidates(shot):
        c = b[0]["id"]
        i = pos[c]
        if marked is not None:
            label = {"same": "같은 일", "diff": "다른 일"}.get(marked.get(str(c)), "모름")
        elif c in old_cut:
            label = "같은 일" if c in joined else "다른 일"
        else:
            label = "섞임 안" if where[c] in mixed else "같은 일"
        rows.append((label, dist(shot[max(0, i - SIDE):i], shot[i:i + SIDE]), c))

    by = {}
    for label, d, _ in rows:
        by.setdefault(label, []).append(d)
    for label, ds in by.items():
        q = statistics.quantiles(ds, n=4) if len(ds) > 1 else ds * 3
        print(f"{label}: {len(ds)}개 · 거리 중앙값 {statistics.median(ds):.2f} · 사분위 {q[0]:.2f}–{q[2]:.2f}")
    known = [(lab == "다른 일", d) for lab, d, _ in rows if lab in ("같은 일", "다른 일")]
    print("문턱별: 거리 ≥ 문턱이면 자름 → 맞힌 수 / 전체")
    for th in np.arange(0.3, 0.75, 0.05):
        ok = sum((d >= th) == cut for cut, d in known)
        tp = sum(d >= th and cut for cut, d in known)
        print(f"  {th:.2f}: {ok}/{len(known)} · 다른 일 잡음 {tp}/{sum(c for c, _ in known)}"
              f" · 같은 일 잘못 자름 {sum(d >= th and not cut for cut, d in known)}")
    print("섞임 구간별 가장 먼 후보 경계 거리:")
    for i in sorted(mixed):
        ds = [d for lab, d, c in rows if lab == "섞임 안" and where[c] == i]
        print(f"  {i}: " + (f"{max(ds):.2f} (후보 {len(ds)}개)" if ds else "후보 경계 없음(1시간 안쪽 공백만)"))


if __name__ == "__main__":
    main()
