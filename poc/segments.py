"""최종 구간과 대표 사진. 지금까지 사용자가 남긴 판정을 모두 반영하는 단 한 곳이다 — 다른 스크립트는 이것만 쓴다.

반영 순서:
  1) 기본 규칙(3시간 공백·1km 이동) + 경계 판정(boundary_labels.json): 후보 경계는 같은 일이면 잇고 다른 일이면 자른다
  2) 구간 확인(event_review.json): '앞 구간과 같은 일'은 합치고, 옮긴 사진은 옮긴 구간으로 보낸다
     (옛 구간 번호는 기본 규칙 구간 기준이라 사진 ID로 다시 찾는다)
  3) '여러 일이 섞임' 구간이 아직 한 덩어리로 남아 있으면 unresolved로 표시한다(1시간 안쪽 경계는 아직 못 자름)
대표 사진(rep_labels.json 결과 반영): 시간상 고르게 k장, 중복·흐림·노출 불량이면 시간상 가장 가까운 괜찮은 사진으로 바꾼다.
"""
import json
from pathlib import Path

from boundary_check import corrected_events, load_shot
from rep_select import DUP, bad_exposure, features
from time_events import reps, split_place

EVAL = Path(__file__).parent.parent / "eval_data"


def final_events(meta: Path, verbose: bool = True) -> tuple[list[list[dict]], set[int], list[dict]]:
    """(구간 목록, 섞임이 남은 구간 번호, 찍은 사진 전체). 구간은 시작 시각 순."""
    shot = load_shot(meta)
    labels = json.loads((EVAL / "boundary_labels.json").read_text(encoding="utf-8"))["labels"]
    review = json.loads((EVAL / "event_review.json").read_text(encoding="utf-8"))
    events = corrected_events(shot, labels)
    old = split_place(shot, 3, 1.0)  # event_review.json 의 구간 번호 기준
    home = {p["id"]: i for i, e in enumerate(events) for p in e}

    for ev in review["merge_with_prev"]:
        a, b = home[old[ev - 1][-1]["id"]], home[old[ev][0]["id"]]
        if a != b:
            for p in events[b]:
                home[p["id"]] = a
    already = moved = 0
    for m in review["moved"]:
        t = next(p["t"] for p in old[m["from"]] if p["id"] == m["id"])
        anchor = min(old[m["to"]], key=lambda p: abs((p["t"] - t).total_seconds()))  # 옮긴 곳에서 시각이 가장 가까운 사진
        if home[m["id"]] == home[anchor["id"]]:
            already += 1  # 경계 판정이 이미 같은 구간으로 이었음
        else:
            home[m["id"]] = home[anchor["id"]]
            moved += 1
    by = {}
    for p in shot:
        by.setdefault(home[p["id"]], []).append(p)
    events = sorted(by.values(), key=lambda e: e[0]["t"])

    where = {p["id"]: i for i, e in enumerate(events) for p in e}
    unresolved = {where[old[i][0]["id"]] for i in review["mixed"]
                  if len({where[p["id"]] for p in old[i]}) == 1}
    if verbose:
        print(f"구간 {len(events)}개 · 경계 판정 {len(labels)}개 반영 · 구간 확인: 합치기 {len(review['merge_with_prev'])}건,"
              f" 옮긴 사진 {len(review['moved'])}장 중 경계 판정으로 이미 이어진 {already}장 + 새로 옮김 {moved}장"
              f" · 섞임 표시 {len(review['mixed'])}개 중 아직 한 덩어리 {len(unresolved)}개")
    return events, unresolved, shot


def representatives(event: list[dict], F: dict[int, dict]) -> list[int]:
    ids = [p["id"] for p in event]
    k = reps(len(ids))
    med = sorted(F[i]["sharp"] for i in ids)[len(ids) // 2]
    ok = lambda i: not bad_exposure(F[i]) and F[i]["sharp"] >= 0.35 * med
    chosen: list[int] = []
    for j in range(k):
        want = int((j + 0.5) * len(ids) / k)
        # 원하는 위치에서 가까운 순서로, 괜찮고 이미 고른 것과 중복이 아닌 첫 사진
        for d in sorted(range(len(ids)), key=lambda x: abs(x - want)):
            i = ids[d]
            if i in chosen or not ok(i):
                continue
            if any(bin(F[i]["dhash"] ^ F[c]["dhash"]).count("1") <= DUP for c in chosen):
                continue
            chosen.append(i)
            break
        else:
            chosen.append(next(i for i in ids if i not in chosen) if len(chosen) < len(ids) else ids[want])
    return sorted(set(chosen), key=ids.index)


def photo_features(shot: list[dict]) -> dict[int, dict]:
    return {p["id"]: features(p["id"]) for p in shot}
