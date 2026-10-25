"""날짜 없는 사진의 날짜 단서를 실제 사진으로 잰다 (썸네일: phone_bench.py thumbs --undated).

1) 날짜 있는 사진 중에 거의 똑같은 사진(dHash 해밍 ≤ DUP)이 있으면 그 날짜를 물려받는다. 이 짝이 아래 채점의 정답이 된다.
2) 정답이 있는 사진으로 다른 단서를 채점: 파일 이름의 날짜, 파일 저장 시각(date_modified)과 찍은 날의 차이.
3) 닮은 사진으로 추정(중복 짝은 빼고)할 때 후보를 '저장 시각 이전 N일'로 좁히면 얼마나 맞는지.
   date_guess.py에서 같은 일의 사진이 없으면 다른 날의 비슷한 장면에 속았다 — 기간 제한이 그걸 막는지 본다.
사용: uv run undated_dates.py ../eval_data/phone/meta_*.json
"""
import collections
import json
import re
import sys
from datetime import datetime
from pathlib import Path

import numpy as np

from boundary_check import THUMBS, load_shot
from boundary_siglip import embed
from rep_select import DUP, features
from time_events import source

NAME_PATS = [
    (re.compile(r"((?:19|20)\d{2})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})"), "이름 YYYYMMDD_HHMMSS"),
    (re.compile(r"((?:19|20)\d{2})-(\d{2})-(\d{2})"), "이름 YYYY-MM-DD"),
    (re.compile(r"(?<!\d)(1[3-7]\d{11})(?!\d)"), "이름 ms 시각"),
]


def name_date(name: str) -> tuple[datetime | None, str]:
    for pat, kind in NAME_PATS:
        m = pat.search(name)
        if not m:
            continue
        try:
            if kind == "이름 ms 시각":
                return datetime.fromtimestamp(int(m.group(1)) / 1000), kind
            return datetime(*map(int, m.groups())), kind
        except ValueError:
            continue
    return None, "이름에 날짜 없음"


def saved(p: dict) -> datetime:
    v = p["date_modified"]
    return datetime.fromtimestamp(v / 1000 if v > 1e11 else v)


def bits(ids: list[int]) -> np.ndarray:
    h = np.array([features(i)["dhash"] for i in ids], dtype=np.uint64)
    return np.unpackbits(h.view(np.uint8).reshape(-1, 8), axis=1).astype(np.int16)


def main() -> None:
    meta = Path(sys.argv[1])
    shot = [p for p in load_shot(meta) if (THUMBS / f"{p['id']}.jpg").exists()]
    U = [p for p in json.loads(meta.read_text(encoding="utf-8"))["photos"]
         if source(p) == "날짜 없음" and (THUMBS / f"{p['id']}.jpg").exists()]
    print(f"날짜 있는 사진 {len(shot)}장 · 날짜 없는 사진 {len(U)}장(썸네일 있음)")

    a, b = bits([p["id"] for p in U]), bits([p["id"] for p in shot])
    ham = a @ (1 - b).T + (1 - a) @ b.T  # 해밍 거리 표 (날짜 없음 × 날짜 있음)
    near = ham.min(1)
    pair = ham.argmin(1)
    has = near <= DUP
    days = lambda x, y: abs((x - y).total_seconds()) / 86400
    spread = [max(days(shot[j]["t"], shot[pair[k]]["t"]) for j in np.where(ham[k] <= DUP)[0]) for k in np.where(has)[0]]
    print(f"\n1) 거의 똑같은 날짜 있는 사진이 있음: {has.sum()}장 ({has.mean():.0%})"
          f" · 그중 짝들이 서로 하루 넘게 다른 경우 {sum(s > 1 for s in spread)}장")
    folder = lambda p: next((x for x in ("KakaoTalk", "Pictures", "DCIM", "Download") if x in p["path"]), "기타")
    print("   폴더별", {f: f"{sum(1 for k, p in enumerate(U) if has[k] and folder(p) == f)}/{n}"
                    for f, n in collections.Counter(map(folder, U)).most_common()})

    truth = {k: shot[pair[k]]["t"] for k in np.where(has)[0]}
    print("\n2) 정답이 있는 사진으로 단서 채점 (찍은 날과의 차이)")
    by = collections.defaultdict(list)
    lag = collections.defaultdict(list)
    for k, t in truth.items():
        d, kind = name_date(U[k]["name"])
        if d:
            by[kind].append(days(d, t))
        lag[folder(U[k])].append((saved(U[k]) - t).total_seconds() / 86400)
    for kind, e in by.items():
        e = np.array(e)
        print(f"   {kind}: {len(e)}장 · 하루 안 {np.mean(e <= 1):.0%} · 7일 안 {np.mean(e <= 7):.0%} · 중앙값 {np.median(e):.1f}일")
    for f, e in lag.items():
        e = np.array(e)
        print(f"   저장 시각 − 찍은 날 [{f}] {len(e)}장: 음수(저장이 먼저) {np.mean(e < -1):.0%} · 하루 안 {np.mean(np.abs(e) <= 1):.0%}"
              f" · 7일 안 {np.mean(np.abs(e) <= 7):.0%} · 30일 안 {np.mean(np.abs(e) <= 30):.0%} · 중앙값 {np.median(e):.1f}일")

    ks = sorted(truth)
    V = embed([p["id"] for p in shot])
    W = embed([U[k]["id"] for k in ks])
    D = np.stack([V[p["id"]] for p in shot]).astype(np.float32)
    Q = np.stack([W[U[k]["id"]] for k in ks]).astype(np.float32)
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    Q /= np.linalg.norm(Q, axis=1, keepdims=True)
    S = Q @ D.T
    S[ham[ks] <= DUP] = -1  # 중복 짝은 빼고 '닮은 사진'만으로
    t_shot = np.array([p["t"].timestamp() for p in shot]) / 86400
    t_saved = np.array([saved(U[k]).timestamp() for k in ks]) / 86400
    t_true = np.array([truth[k].timestamp() for k in ks]) / 86400
    print(f"\n3) 닮은 사진으로 추정 (중복 짝을 뺀 {len(ks)}장, 정답 = 중복 짝의 날짜)")
    print("   후보 기간(저장 전)  유사도 문턱  추정한 비율  하루 안  7일 안")
    for win in (1, 3, 7, 30, None):
        for th in (0.0, 0.8, 0.9):
            M = S.copy()
            if win is not None:
                lagd = t_saved[:, None] - t_shot[None, :]
                M[(lagd < -1) | (lagd > win)] = -1
            j = M.argmax(1)
            ok = M[np.arange(len(ks)), j] >= max(th, -0.5)
            e = np.abs(t_shot[j] - t_true)[ok]
            if ok.any():
                print(f"   {('제한 없음' if win is None else f'{win}일'):>14}  {th:>10.1f}  {ok.mean():>10.0%}"
                      f"  {np.mean(e <= 1):>6.0%}  {np.mean(e <= 7):>5.0%}")


if __name__ == "__main__":
    main()
