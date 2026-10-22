"""검색 평가: 사람이 확인한 구간 설명(describe_truth.json)을 검색어로 넣었을 때 그 구간이 상위에 나오는가.

사용: uv run search_eval.py ../eval_data/phone/meta_*.json
폰에서 할 계산과 같다: 검색어 → 텍스트 인코더(text_w8.onnx) → 구간 임베딩과 코사인 → 순위.
구간 점수 방식 세 가지를 비교한다:
  대표 평균   — 대표 사진 임베딩 평균 하나만 저장 (가장 가벼움)
  대표 최대   — 대표 사진마다 점수, 가장 높은 것
  전체 최대   — 구간의 모든 사진 중 가장 높은 것 (전부 분석해야 함)
설명 문장이 똑같은 구간(예: 같은 병원 식사 여러 번)은 서로 정답으로 본다.
구간·대표 사진은 segments.py(사용자 판정 모두 반영). 이미지 입력은 160px 썸네일(폰 원본보다 불리).
"""
import json
import sys
from pathlib import Path

import numpy as np
from transformers import AutoTokenizer

from boundary_siglip import embed
from export_siglip import MODEL_ID, OUT, TEXT_LEN, session
from segments import EVAL, final_events, photo_features, representatives


def main() -> None:
    events, _, shot = final_events(Path(sys.argv[1]))
    truth = {e["key"]: e for e in json.loads((EVAL / "describe_truth.json").read_text(encoding="utf-8"))["events"]}
    keys = [e[0]["id"] for e in events]
    missing = [k for k in keys if k not in truth]
    if missing:
        raise SystemExit(f"정답 설명이 없는 구간 {len(missing)}개 — 구간이 바뀌었으면 describe_fix.py부터 다시")
    texts = [truth[k]["text"] for k in keys]

    F = photo_features(shot)
    R = [representatives(e, F) for e in events]
    E = embed([p["id"] for p in shot])
    norm = lambda v: v / np.linalg.norm(v, axis=-1, keepdims=True)

    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    ids = tok(texts, padding="max_length", max_length=TEXT_LEN, truncation=True, return_tensors="np")["input_ids"]
    s = session(OUT / "text_w8.onnx")
    Q = []
    for i, r in enumerate(ids):
        Q.append(s.run(None, {"input_ids": r[None].astype(np.int64)})[0][0])
        if (i + 1) % 100 == 0:
            print(f"  검색어 임베딩 {i + 1}/{len(ids)}", flush=True)
    Q = norm(np.array(Q))

    rep_mean = norm(np.array([np.mean([E[x] for x in r], axis=0) for r in R]))
    scores = {
        "대표 평균": Q @ rep_mean.T,
        "대표 최대": np.array([[max(float(q @ norm(E[x])) for x in r) for r in R] for q in Q]),
        "전체 최대": np.array([[max(float(q @ norm(E[p["id"]])) for p in e) for e in events] for q in Q]),
    }
    same = {t: {i for i, u in enumerate(texts) if u == t} for t in set(texts)}
    n = len(events)
    print(f"구간 {n}개 · 검색어 {n}개(설명이 같은 구간 묶음 {sum(len(v) > 1 for v in same.values())}개) · "
          f"무작위로 찍으면 상위 10 안에 들 확률 {10 / n:.1%}")
    print("  방식        상위1   상위5   상위10  평균 순위(중앙값)")
    for name, S in scores.items():
        ranks = []
        for i in range(n):
            order = np.argsort(-S[i])
            ranks.append(min(int(np.where(order == j)[0][0]) for j in same[texts[i]]) + 1)
        ranks = np.array(ranks)
        print(f"  {name}   {np.mean(ranks <= 1):6.1%}  {np.mean(ranks <= 5):6.1%}  {np.mean(ranks <= 10):6.1%}"
              f"   {np.median(ranks):.0f}")
        if name == "대표 평균":
            worst = np.argsort(-ranks)[:8]
            print("    가장 못 찾은 검색어:", [(texts[i], int(ranks[i])) for i in worst])
            # 실제 검색은 "작년 여름 바닷가"처럼 날짜를 함께 말하는 경우가 많다: 같은 해·같은 달 구간 안에서만 순위
            for unit, cut in (("같은 해", 4), ("같은 달", 7)):
                period = [e[0]["t"].isoformat()[:cut] for e in events]
                rk = []
                for i in range(n):
                    pool = [j for j in range(n) if period[j] == period[i]]
                    order = sorted(pool, key=lambda j: -S[i][j])
                    rk.append(min(order.index(j) for j in same[texts[i]] if j in pool) + 1)
                rk = np.array(rk)
                print(f"    {unit}로 좁히면: 상위1 {np.mean(rk <= 1):.1%} · 상위5 {np.mean(rk <= 5):.1%}"
                      f" · 후보 수 중앙값 {np.median([period.count(p) for p in period]):.0f}개")


if __name__ == "__main__":
    main()
