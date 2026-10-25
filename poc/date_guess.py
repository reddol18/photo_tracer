"""날짜 없는 사진의 날짜를 '닮은 사진'의 날짜로 추정할 수 있는지, 날짜가 있는 사진으로 시험한다.

날짜가 있는 사진 하나를 날짜 없는 척 빼고, 나머지 중 SigLIP 유사도가 가장 높은 사진의 날짜를 추정값으로 쓴다.
  - 중복(dHash 해밍 ≤ DUP)은 후보에서 뺀다: 중복이면 dHash만으로 날짜를 바로 물려받으므로 여기선 더 어려운 경우만 본다.
  - 경우 A: 같은 일(구간)의 다른 사진이 남아 있음 — 카톡으로 받은 사진 중 내가 같은 날 찍은 사진도 있는 경우
  - 경우 B: 같은 일의 사진이 하나도 없음 — 남이 찍어 보낸 사진만 있는 경우. 다른 날의 비슷한 장면에 속는지 본다
유사도 문턱을 올리면 추정하는 사진은 줄고 정확도는 오른다. 그 관계를 표로 낸다.
사용: uv run date_guess.py ../eval_data/phone/meta_*.json
"""
import sys
from pathlib import Path

import numpy as np

from boundary_siglip import embed
from rep_select import DUP
from segments import final_events, photo_features


def main() -> None:
    events, _, shot = final_events(Path(sys.argv[1]))
    ids = [p["id"] for p in shot]
    t = np.array([p["t"].timestamp() / 86400 for p in shot])  # 일 단위
    seg = np.zeros(len(ids), int)
    pos = {i: k for k, i in enumerate(ids)}
    for n, e in enumerate(events):
        for p in e:
            seg[pos[p["id"]]] = n
    V = np.stack([embed(ids)[i] for i in ids]).astype(np.float32)
    V /= np.linalg.norm(V, axis=1, keepdims=True)
    F = photo_features(shot)
    h = np.array([F[i]["dhash"] for i in ids], dtype=np.uint64)
    S = V @ V.T
    np.fill_diagonal(S, -1)
    dup = np.zeros_like(S, bool)
    for k in range(len(ids)):
        x = np.bitwise_xor(h, h[k])
        dup[k] = np.array([bin(int(v)).count("1") <= DUP for v in x])
    S[dup] = -1
    print(f"사진 {len(ids)}장 · 구간 {len(events)}개 · 중복 짝이 있는 사진 {int((dup.sum(1) > 1).sum())}장(자기 자신 제외)")

    for name, mask in (("A 같은 일 사진 있음", None), ("B 같은 일 사진 없음", seg[:, None] == seg[None, :])):
        M = S.copy()
        if mask is not None:
            M[mask] = -1
        if name.startswith("A"):
            ok = np.array([(seg == seg[k]).sum() - dup[k, seg == seg[k]].sum() > 1 for k in range(len(ids))])
            M, tt = M[ok], t[ok]  # 같은 구간에 중복 아닌 다른 사진이 있는 사진만
        else:
            tt = t
        j = M.argmax(1)
        sim = M[np.arange(len(M)), j]
        err = np.abs(t[j] - tt)
        print(f"\n{name}: 시험 사진 {len(M)}장")
        print("  유사도 문턱  추정한 비율  ±1일 안  ±7일 안  ±30일 안  오차 중앙값")
        for th in (0.0, 0.6, 0.7, 0.8, 0.85, 0.9):
            m = sim >= th
            if not m.any():
                continue
            e = err[m]
            print(f"  {th:>10.2f}  {m.mean():>10.0%}  {np.mean(e <= 1):>7.0%}  {np.mean(e <= 7):>7.0%}"
                  f"  {np.mean(e <= 30):>8.0%}  {np.median(e):>8.1f}일")


if __name__ == "__main__":
    main()
