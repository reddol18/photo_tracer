"""짧은 검색어 평가: "고양이", "바다"처럼 한두 단어로 찾을 때도 맞는 구간이 위에 오는가.

정답: 사람이 확인한 구간 설명(describe_truth.json)에 그 낱말(또는 비슷한 말)이 들어 있는 구간.
설명은 구간의 중심 장면 한 줄이라 고양이가 배경에 나오는 구간은 정답에서 빠진다 → 정밀도는 실제보다 낮게 나온다.
지표: 상위 5 안에 정답이 하나라도 있나(적중), 상위 10 중 정답 비율(정밀도), 정답 구간 중 상위 20에 든 비율(재현율).
검색어 모양 두 가지를 비교한다: 낱말 그대로, "○○ 사진".
사용: uv run short_query_eval.py ../eval_data/phone/meta_*.json [../eval_data/phone/embed_vision_384_w8_*.json]
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
from transformers import AutoTokenizer

from boundary_siglip import embed
from export_siglip import MODEL_ID, OUT, TEXT_LEN, session
from search_eval import phone_vectors
from segments import EVAL, final_events, photo_features, representatives

# 검색어: 정답을 고를 정규식 (설명에 쓰인 말과 비슷한 말)
QUERIES = {
    "고양이": r"고양이", "강아지": r"강아지", "피자": r"피자", "케이크": r"케이크", "생일": r"생일",
    "바다": r"바다|바닷가|해변", "공원": r"공원", "놀이터": r"놀이터", "키즈카페": r"키즈카페", "카페": r"(?<!키즈)카페",
    "병원": r"병원|입원", "크리스마스": r"크리스마스|트리", "산책": r"산책", "물놀이": r"물놀이|수영",
    "기차": r"기차|지하철", "자동차": r"자동차", "냉면": r"냉면", "치킨": r"치킨", "초밥": r"초밥", "파스타": r"파스타",
    "커피": r"커피", "마트": r"마트|진열대|카트", "유모차": r"유모차", "어린이집": r"어린이집", "자는 아이": r"잠든|자는|잠자",
    "장난감": r"장난감", "그림 그리기": r"그리기|그림을", "블록": r"블록", "뽀로로": r"뽀로로", "헬로키티": r"헬로키티",
    "셀카": r"셀카", "영수증": r"영수증", "화면 캡처": r"캡처", "풍경": r"풍경|전망", "드레스": r"드레스",
    "놀이기구": r"놀이기구", "잔디밭": r"잔디", "침대": r"침대", "간식": r"간식", "꽃": r"꽃",
}


def text_vectors(texts: list[str]) -> np.ndarray:
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    ids = tok(texts, padding="max_length", max_length=TEXT_LEN, truncation=True, return_tensors="np")["input_ids"]
    s = session(OUT / "text_w8.onnx")
    Q = np.array([s.run(None, {"input_ids": r[None].astype(np.int64)})[0][0] for r in ids])
    return Q / np.linalg.norm(Q, axis=1, keepdims=True)


def main() -> None:
    events, _, shot = final_events(Path(sys.argv[1]))
    truth = {e["key"]: e["text"] for e in json.loads((EVAL / "describe_truth.json").read_text(encoding="utf-8"))["events"]}
    texts = [truth[e[0]["id"]] for e in events]
    rel = {q: {i for i, t in enumerate(texts) if re.search(p, t)} for q, p in QUERIES.items()}
    rel = {q: r for q, r in rel.items() if r}
    print(f"구간 {len(events)}개 · 짧은 검색어 {len(rel)}개 · 정답 구간 수 중앙값 {np.median([len(r) for r in rel.values()]):.0f}")

    F = photo_features(shot)
    R = [representatives(e, F) for e in events]
    norm = lambda v: v / np.linalg.norm(v, axis=-1, keepdims=True)
    banks = {}
    E = embed([p["id"] for p in shot])
    banks["썸네일"] = norm(np.array([np.mean([E[x] for x in r], axis=0) for r in R]))
    for path in map(Path, sys.argv[2:]):
        P = phone_vectors(path)
        banks["폰 원본"] = norm(np.array([np.mean([P[x] for x in r if x in P] or [E[r[0]]], axis=0) for r in R]))

    qs = list(rel)
    forms = {"낱말": qs, "○○ 사진": [f"{q} 사진" for q in qs]}
    vec = {f: text_vectors(t) for f, t in forms.items()}
    print("  구간 벡터  검색어 모양   상위5 적중  상위10 정밀도  상위20 재현율")
    per = {}
    for bname, B in banks.items():
        for f, Q in vec.items():
            S = Q @ B.T
            hit, prec, rec = [], [], []
            for k, q in enumerate(qs):
                order = list(np.argsort(-S[k]))
                hit.append(any(i in rel[q] for i in order[:5]))
                prec.append(sum(i in rel[q] for i in order[:10]) / 10)
                rec.append(sum(i in rel[q] for i in order[:20]) / len(rel[q]))
                per[(bname, f, q)] = (order.index(min(rel[q], key=order.index)) + 1, len(rel[q]))
            print(f"  {bname:8s}  {f:8s}  {np.mean(hit):>9.0%}  {np.mean(prec):>12.0%}  {np.mean(rec):>12.0%}")
    b = "폰 원본" if "폰 원본" in banks else "썸네일"
    f = max(vec, key=lambda f: np.mean([per[(b, f, q)][0] <= 5 for q in qs]))
    print(f"\n검색어별 첫 정답 순위 ({b}, {f}): " +
          ", ".join(f"{q} {per[(b, f, q)][0]}위/{per[(b, f, q)][1]}개" for q in sorted(qs, key=lambda q: per[(b, f, q)][0])))


if __name__ == "__main__":
    main()
