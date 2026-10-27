"""검색 순위 방식 비교: 아이 사진이 대부분인 앨범에서 "바다에서 노는 아이"가 바다보다 '아이'에 끌리는 문제.

정답·검색어는 short_query_eval.py와 같다(사람이 확인한 구간 설명에 그 낱말이 든 구간).
검색어 모양: 낱말 / "○○ 사진" / "아이와 ○○"(앨범 대부분에 있는 '아이'가 섞인 검색어).
구간 점수:
  평균     대표 사진 벡터 평균과의 코사인 (0단계 방식)
  최고     대표 사진 중 가장 닮은 사진의 코사인 (앱 9633471)
  +중심빼기  사진 벡터에서 앨범 평균 벡터를 빼고(모두에게 공통인 '아이 사진다움'을 지움) 최고
  +검색어중심 검색어 벡터에서 흔한 검색어들의 평균을 빼고 같은 방식
사용: uv run search_rank_eval.py ../eval_data/phone/meta_*.json ../eval_data/phone/embed_vision_*.json
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

from search_eval import phone_vectors
from segments import EVAL, final_events, photo_features, representatives
from short_query_eval import QUERIES, text_vectors

SCALE, BIAS = 112.54814, -16.77151
# 흔한 검색어 방향: 평가 검색어와 겹치지 않게 따로 쓴 일상 문구 (앱에도 이 평균 벡터를 넣는다)
GENERIC = ["사진", "아이 사진", "가족 사진", "아기", "아이", "우리 아이", "엄마와 아이", "아빠와 아이", "웃는 아이",
           "아이 얼굴", "집에서 찍은 사진", "밖에서 찍은 사진", "놀고 있는 아이", "앉아 있는 아이", "서 있는 아이",
           "가족", "사람들", "여자아이", "아이의 모습", "일상", "주말", "나들이", "외출", "추억", "여행 사진",
           "휴대폰으로 찍은 사진", "어린이", "아이와 엄마", "아이와 아빠", "우리 가족"]


def norm(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def main() -> None:
    events, _, shot = final_events(Path(sys.argv[1]))
    truth = {e["key"]: e["text"] for e in json.loads((EVAL / "describe_truth.json").read_text(encoding="utf-8"))["events"]}
    texts = [truth[e[0]["id"]] for e in events]
    rel = {q: {i for i, t in enumerate(texts) if re.search(p, t)} for q, p in QUERIES.items()}
    rel = {q: r for q, r in rel.items() if r}
    qs = list(rel)
    F = photo_features(shot)
    R = [representatives(e, F) for e in events]
    P = phone_vectors(Path(sys.argv[2]))
    ids = sorted({x for r in R for x in r if x in P})
    col = {x: k for k, x in enumerate(ids)}
    V = norm(np.array([P[x] for x in ids]))
    reps = [[col[x] for x in r if x in col] for r in R]
    keep = [i for i, r in enumerate(reps) if r]
    print(f"구간 {len(keep)}개 · 대표 사진 {len(ids)}장 · 검색어 {len(qs)}개")

    forms = {"낱말": qs, "○○ 사진": [f"{q} 사진" for q in qs], "아이와 ○○": [f"아이와 {q}" for q in qs]}
    Qs = {f: text_vectors(t) for f, t in forms.items()}
    common = norm(text_vectors(GENERIC).mean(0))  # 흔한 검색어 방향
    mu = V.mean(0)
    deq = lambda Q: norm(Q - common * (Q @ common)[:, None])

    def seg_scores(Q, Vm, how):
        S = Q @ Vm.T
        return np.array([[S[k, r].mean() if how == "mean" else S[k, r].max() for r in (reps[i] for i in keep)]
                         for k in range(len(Q))])

    def evaluate(S):
        hit, prec, first, top1p = [], [], [], []
        for k, q in enumerate(qs):
            order = [keep[j] for j in np.argsort(-S[k])]
            hit.append(any(i in rel[q] for i in order[:5]))
            prec.append(sum(i in rel[q] for i in order[:10]) / 10)
            first.append(next(n for n, i in enumerate(order, 1) if i in rel[q]) if rel[q] & set(order) else 999)
        return np.mean(hit), np.mean(prec), np.median(first)

    print("  검색어 모양  방식          상위5 적중  상위10 정밀도  첫 정답 순위(중앙)")
    for f, Q in Qs.items():
        Vmean = norm(np.array([V[r].mean(0) for r in reps if r]))
        rows = {
            "평균": (Q @ Vmean.T),
            "최고": seg_scores(Q, V, "max"),
            "+중심빼기": seg_scores(Q, norm(V - mu), "max"),
            "검색어중심만": seg_scores(deq(Q), V, "max"),
            "+검색어중심": seg_scores(deq(Q), norm(V - mu), "max"),
        }
        for name, S in rows.items():
            h, p, fr = evaluate(S)
            print(f"  {f:9s}  {name:10s}  {h:9.0%}  {p:12.0%}  {fr:10.0f}")
    # 확률 크기: 낱말 검색어의 1위 사진 확률
    S = Qs["낱말"] @ V.T
    print(f"\n낱말 검색어 1위 사진 확률 중앙값 {np.median(1 / (1 + np.exp(-(SCALE * S.max(1) + BIAS)))):.3f}")


if __name__ == "__main__":
    main()
