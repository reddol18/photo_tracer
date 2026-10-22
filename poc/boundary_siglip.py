"""경계 정답(boundary_labels.json)으로 경계 판단 지표를 채점한다: 시간 차, 이동 거리, 색 분포, SigLIP 장면 유사도.

사용: uv run boundary_siglip.py ../eval_data/phone/meta_*.json ../eval_data/boundary_labels.json
SigLIP은 폰에 넣을 vision_384_w8.onnx를 PC에서 돌린다. 입력은 160px 썸네일을 384로 키운 것이라
폰(원본에서 축소)보다 불리한 조건이다. 임베딩은 eval_data/thumb_siglip.npz에 저장해 다시 쓴다.
문턱은 98개로 고르고 같은 98개로 채점하면 낙관적이므로, 하나씩 빼고 고르는 교차 검증 정확도도 함께 낸다.
"""
import json
import sys
from pathlib import Path

import numpy as np

from boundary_check import SIDE, THUMBS, candidates, dist, load_shot
from export_siglip import OUT, preprocess, session
from time_events import km

CACHE = Path(__file__).parent.parent / "eval_data" / "thumb_siglip.npz"


def embed(ids: list[int]) -> dict[int, np.ndarray]:
    have = dict(np.load(CACHE)) if CACHE.exists() else {}
    todo = [i for i in ids if str(i) not in have]
    if todo:
        s = session(OUT / "vision_384_w8.onnx")
        name = s.get_inputs()[0].name
        for k, i in enumerate(todo):
            have[str(i)] = s.run(None, {name: preprocess(THUMBS / f"{i}.jpg", 384)})[0][0]
            if (k + 1) % 100 == 0:
                print(f"  SigLIP {k + 1}/{len(todo)}")
        np.savez(CACHE, **have)
    return {i: have[str(i)] for i in ids}


def best_split(xs: np.ndarray, ys: np.ndarray) -> tuple[float, bool, int]:
    """한 지표로 '다른 일'을 가를 문턱과 방향(큰 쪽이 다른 일인지), 맞힌 수."""
    best = (0.0, True, -1)
    for th in np.unique(xs):
        for high in (True, False):
            pred = xs >= th if high else xs < th
            ok = int((pred == ys).sum())
            if ok > best[2]:
                best = (float(th), high, ok)
    return best


def loo(xs: np.ndarray, ys: np.ndarray) -> int:
    ok = 0
    for i in range(len(xs)):
        m = np.arange(len(xs)) != i
        th, high, _ = best_split(xs[m], ys[m])
        ok += int((xs[i] >= th if high else xs[i] < th) == ys[i])
    return ok


def main() -> None:
    shot = load_shot(Path(sys.argv[1]))
    labels = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))["labels"]
    rows = [(a, b) for a, b in candidates(shot) if labels.get(str(b[0]["id"])) in ("same", "diff")]
    ys = np.array([labels[str(b[0]["id"])] == "diff" for _, b in rows])
    E = embed(sorted({p["id"] for a, b in rows for p in a[-SIDE:] + b[:SIDE]}))

    def sim(a, b):
        ea = np.mean([E[p["id"]] for p in a[-SIDE:]], axis=0)
        eb = np.mean([E[p["id"]] for p in b[:SIDE]], axis=0)
        return float(ea @ eb / np.linalg.norm(ea) / np.linalg.norm(eb))

    def far(a, b):
        la = next((p for p in reversed(a) if "lat" in p), None)
        lb = next((p for p in b if "lat" in p), None)
        return km(la, lb) if la and lb else -1.0  # 위치 없음은 -1

    feats = {
        "시간 차(분)": np.array([(b[0]["t"] - a[-1]["t"]).total_seconds() / 60 for a, b in rows]),
        "이동 거리(km)": np.array([far(a, b) for a, b in rows]),
        "색 분포 거리": np.array([dist(a[-SIDE:], b[:SIDE]) for a, b in rows]),
        "SigLIP 유사도": np.array([sim(a, b) for a, b in rows]),
    }
    n = len(ys)
    print(f"정답 {n}개 · 다른 일 {ys.sum()} · 같은 일 {n - ys.sum()} · 전부 '다른 일'로 찍으면 {ys.sum()}/{n}")
    for name, xs in feats.items():
        th, high, ok = best_split(xs, ys)
        print(f"  {name}: 문턱 {th:.3g}({'이상' if high else '미만'}이면 다른 일) {ok}/{n} · 교차 검증 {loo(xs, ys)}/{n}"
              f" · 같은 일 평균 {xs[~ys].mean():.3g} / 다른 일 평균 {xs[ys].mean():.3g}")

    # 문턱 근처만 사용자에게 묻는다면: 확신 구간 밖은 자동, 안은 질문
    xs = feats["SigLIP 유사도"]
    th, _, _ = best_split(xs, ys)
    for band in (0.03, 0.05, 0.08):
        sure = np.abs(xs - th) >= band
        ok = int(((xs[sure] < th) == ys[sure]).sum())
        print(f"  SigLIP 문턱 ±{band}: 자동 {sure.sum()}개 중 {ok}개 맞음({ok / max(1, sure.sum()):.0%}) · 사용자에게 물을 경계 {(~sure).sum()}개")

    # 두 지표 조합: SigLIP 유사도와 시간 차로 그은 직선 하나(로지스틱 회귀, 하나씩 빼고 검증)
    X = np.column_stack([feats["SigLIP 유사도"], np.log1p(feats["시간 차(분)"]), feats["이동 거리(km)"] > 1])
    X = (X - X.mean(0)) / X.std(0)

    def fit(X, y, steps=3000, lr=0.1):
        w = np.zeros(X.shape[1] + 1)
        Xb = np.column_stack([X, np.ones(len(X))])
        for _ in range(steps):
            p = 1 / (1 + np.exp(-Xb @ w))
            w -= lr * Xb.T @ (p - y) / len(y)
        return w

    ok = 0
    for i in range(n):
        m = np.arange(n) != i
        w = fit(X[m], ys[m].astype(float))
        ok += int(((np.append(X[i], 1) @ w) > 0) == ys[i])
    w = fit(X, ys.astype(float))
    print(f"  조합(SigLIP + 시간 차 + 1km 이동): 교차 검증 {ok}/{n} · 가중치 {np.round(w[:3], 2).tolist()}")


if __name__ == "__main__":
    main()
