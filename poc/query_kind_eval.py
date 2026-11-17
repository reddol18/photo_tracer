"""검색어 종류별 강약(#20): 캐릭터·옷·소품(A) / 동작(B) / 배경 시설물(C) / 장소·풍경(D, 기준).

정답: 사람이 확인한 구간 설명(describe_truth.json)에 검색어마다 둔 정규식이 맞는 구간(정답 3개 이상인 검색어만).
설명은 구간의 중심 장면 한 줄이라 배경에만 있는 물체는 정답에서 빠진다 → 정밀도는 실제보다 낮게 나온다(묶음 C가 특히).
앱과 같은 방식(Search.kt): 검색어·"○○ 사진"·"○○ 장면" 벡터 평균 → 흔한 방향(GENERIC 평균) 빼기 → 구간은 대표 사진 중 최고 코사인.
구간 밖 사진(날짜 모름·캡처)은 정답 설명이 없어 빼고 구간끼리만 겨룬다.
지표: 상위10 정밀도, 상위20 재현율, 첫 정답 순위(중앙값), MRR.

원인 후보 확인(#20 본문 번호):
  3 흔한 방향 빼기 켬/끔, GENERIC 평균과 검색어 벡터의 코사인
  4 대표 사진만 vs 구간 모든 사진 — 모든 사진 벡터는 PC 썸네일(160px) 벡터(thumb_siglip.npz)뿐이라 둘 다 썸네일로 비교
  5 w8 vs fp32 비전(·텍스트) — 대표 사진 썸네일로 PC에서 계산
  2 2×2 타일 벡터 최고 점수 — 대표 사진 썸네일로(원본이 PC에 없어 조각이 80px쯤이다, 효과를 낮게 잰다)
  6 한국어 vs 영어(같은 뜻) — 낱말만, 흔한 방향 빼기 켬
  1 동작 — 동작 낱말을 뺀 검색어와 비교, 그리고 묶음 안에서 맞는 검색어가 1위인 비율(구간 → 검색어 고르기)
사진·설명은 출력하지 않는다(숫자·검색어만).
사용: uv run query_kind_eval.py ../eval_data/phone/meta_*.json ../eval_data/phone/embed_vision_384_w8_*.json
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from transformers import AutoTokenizer

from boundary_check import THUMBS
from boundary_siglip import embed
from export_siglip import MEAN, MODEL_ID, OUT, STD, TEXT_LEN, session
from search_eval import phone_vectors
from search_rank_eval import GENERIC
from segments import EVAL, final_events, photo_features, representatives

# 묶음 → (검색어, 같은 뜻 영어, 정답 정규식, 동작·대상 낱말을 뺀 검색어)
GROUPS = {
    "A 캐릭터·옷·소품": [
        ("캐릭터", "cartoon character", r"캐릭터|뽀로로|헬로키티", None),
        ("드레스", "dress", r"드레스|원피스", None),
        ("뽀로로", "Pororo", r"뽀로로", None),
        ("헬로키티", "Hello Kitty", r"헬로키티", None),
        ("장난감", "toys", r"장난감", None),
        ("인형", "stuffed doll", r"인형", None),
        ("가방", "bag", r"가방", None),
        ("블록", "toy blocks", r"블록", None),
        ("공", "ball", r"(?<!항)공(?![원룡주항부간연사장기])", None),
        ("책", "book", r"책(?!상)", None),
    ],
    "B 동작": [
        ("먹는 아이", "child eating", r"먹", "아이"),
        ("자는 아이", "sleeping child", r"잠든|자는|잠자", "아이"),
        ("누워 있는 아이", "child lying down", r"누운|누워", "아이"),
        ("앉아 있는 아이", "child sitting", r"앉은|앉아", "아이"),
        ("타는 아이", "child riding", r"타고|타는|탄 |타기", "아이"),
        ("뛰노는 아이", "child running around", r"뛰", "아이"),
        ("산책하는 아이", "child taking a walk", r"산책", "아이"),
        ("들고 있는 아이", "child holding something", r"들고", "아이"),
        ("그림 그리는 아이", "child drawing a picture", r"그리기|그림을|그리는|그린", "그림"),
        ("구경하는 아이", "child looking around", r"구경|관람", "아이"),
        ("물놀이하는 아이", "child playing in water", r"물놀이|수영|튜브", "물"),
        ("요리하는 모습", "cooking", r"요리|구워", "모습"),
    ],
    "C 배경 시설물": [
        ("놀이기구", "amusement ride", r"놀이기구", None),
        ("놀이터", "playground", r"놀이터", None),
        ("침대", "bed", r"침대", None),
        ("소파", "sofa", r"소파", None),
        ("의자", "chair", r"의자", None),
        ("유모차", "stroller", r"유모차", None),
        ("카트", "shopping cart", r"카트", None),
        ("포토존", "photo zone", r"포토존", None),
        ("화단", "flower bed", r"화단", None),
        ("크리스마스 트리", "Christmas tree", r"트리", None),
        ("에어컨", "air conditioner", r"에어컨", None),
        ("진열대", "store shelves", r"진열대", None),
        ("놀이매트", "play mat", r"매트", None),
        ("계단", "stairs", r"계단", None),
        ("이불", "blanket", r"이불", None),
    ],
    "D 장소·풍경": [
        ("바닷가", "beach", r"바다|바닷가|해변", None),
        ("공원", "park", r"공원", None),
        ("산", "mountain", r"(?<![우해])산(?!책)", None),
        ("잔디밭", "lawn", r"잔디", None),
        ("카페", "cafe", r"(?<!키즈)카페", None),
        ("식당", "restaurant", r"식당", None),
        ("키즈카페", "indoor kids cafe", r"키즈카페", None),
        ("병원", "hospital", r"병원|입원", None),
        ("마트", "supermarket", r"마트|진열대|카트", None),
        ("어린이집", "daycare center", r"어린이집", None),
        ("골목길", "street alley", r"거리|골목", None),
        ("밤", "night", r"밤", None),
        ("꽃", "flowers", r"꽃", None),
        ("숲", "forest", r"숲", None),
        ("풍경", "scenery", r"풍경|전망", None),
    ],
}
CACHE = EVAL / "query_kind_cache.npz"  # fp32 비전·타일 벡터(eval_data는 저장소 제외)


def norm(v):
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


class TextEnc:
    def __init__(self):
        self.tok = AutoTokenizer.from_pretrained(MODEL_ID)
        self.sess, self.memo = {}, {}

    def __call__(self, texts: list[str], model: str = "text_w8") -> np.ndarray:
        s = self.sess.get(model) or self.sess.setdefault(model, session(OUT / f"{model}.onnx"))
        todo = [t for t in texts if (model, t) not in self.memo]
        if todo:
            ids = self.tok(todo, padding="max_length", max_length=TEXT_LEN, truncation=True, return_tensors="np")["input_ids"]
            for t, r in zip(todo, ids):
                self.memo[(model, t)] = s.run(None, {"input_ids": r[None].astype(np.int64)})[0][0]
        return norm(np.array([self.memo[(model, t)] for t in texts]))

    def templated(self, qs: list[str], model: str = "text_w8", forms=("{}", "{} 사진", "{} 장면")) -> np.ndarray:
        """앱 Search.templated: 검색어·'○○ 사진'·'○○ 장면' 벡터 평균"""
        return norm(sum(self([f.format(q) for q in qs], model) for f in forms))

    def pieces(self, q: str) -> int:
        return len(self.tok(q, add_special_tokens=False)["input_ids"])


def thumb_input(im: Image.Image, res: int = 384) -> np.ndarray:
    x = (np.asarray(im.convert("RGB").resize((res, res), Image.BICUBIC), dtype=np.float32) / 255.0 - MEAN) / STD
    return x.transpose(2, 0, 1)[None]


def vision_cache(ids: list[int]) -> dict[str, np.ndarray]:
    """대표 사진 썸네일: fp32 비전('fp:id'), w8 2×2 타일('t0..t3:id'). 한 번 계산해 CACHE에 둔다."""
    have = dict(np.load(CACHE)) if CACHE.exists() else {}
    todo = [i for i in ids if f"fp:{i}" not in have or f"t3:{i}" not in have]
    if todo:
        fp, w8 = session(OUT / "vision_384.onnx"), session(OUT / "vision_384_w8.onnx")
        name = fp.get_inputs()[0].name
        for k, i in enumerate(todo):
            with Image.open(THUMBS / f"{i}.jpg") as im:
                im = ImageOps.exif_transpose(im).convert("RGB")
                have[f"fp:{i}"] = fp.run(None, {name: thumb_input(im)})[0][0]
                w, h = im.size
                for t, (x, y) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
                    tile = im.crop((x * w // 2, y * h // 2, (x + 1) * w // 2, (y + 1) * h // 2))
                    have[f"t{t}:{i}"] = w8.run(None, {name: thumb_input(tile)})[0][0]
            if (k + 1) % 100 == 0:
                print(f"  비전(fp32·타일) {k + 1}/{len(todo)}", flush=True)
                np.savez(CACHE, **have)
        np.savez(CACHE, **have)
    return have


def metrics(S: np.ndarray, rel: list[set[int]]) -> np.ndarray:
    """S[검색어, 구간] → 검색어마다 (상위10 정밀도, 상위20 재현율, 첫 정답 순위, 역순위)"""
    out = []
    for k, r in enumerate(rel):
        order = np.argsort(-S[k])
        hits = np.isin(order, list(r))
        first = int(np.argmax(hits)) + 1
        out.append((hits[:10].mean(), hits[:20].sum() / len(r), first, 1 / first))
    return np.array(out)


def dict_eval(enc, ko, G, rel, Qt, c, scores) -> None:
    """개선 1(#23) 한영 사전: 사전 낱말이 든 검색어에만 영어 뜻 벡터를 비율 a로 섞는다(norm((1-a)·한국어 + a·영어)).
    개선 2(#24) 흔한 방향 빼기: 늘 / 사람 낱말이 든 검색어만 / 안 함. 섞은 뒤에 뺀다(앱 순서).
    사전(search_dict.tsv)은 평가 검색어와 따로 만든 일반 낱말 목록이다. 영어 뜻은 GROUPS의 영어가 아니라 사전의 것."""
    from search_dict import Lexicon, has_person
    lex = Lexicon()
    hits = [lex.match(q) for q in ko]
    person = np.array([has_person(q) for q in ko])
    print(f"\n### 개선 1·2 (사전 {len(lex.rows)}낱말 · 꼴 {len(lex.index)}개)")
    print("| 묶음 | 사전 낱말이 든 검색어 | 사전에 없는 검색어 | 사람 낱말 검색어 |\n|---|---|---|---|")
    for g in GROUPS:
        m = np.where(G == g)[0]
        print(f"| {g} | " + ", ".join(f"{ko[k]}({'·'.join(lex.rows[h][2] for h in hits[k])})" for k in m if hits[k]) +
              " | " + ", ".join(ko[k] for k in m if not hits[k]) + " | " + ", ".join(ko[k] for k in m if person[k]) + " |")
    ens = sorted({h for hs in hits for h in hs})
    en_forms = {"낱말": ("{}",), "문형": ("{}", "a photo of {}")}
    EN = {name: dict(zip(ens, norm(sum(enc([f.format(lex.rows[h][2]) for h in ens]) for f in fs)))) for name, fs in en_forms.items()}

    def build(a: float, sub: str, en: str = "낱말") -> np.ndarray:
        Q = Qt.copy()
        if a > 0:
            for k, hs in enumerate(hits):
                if hs:
                    e = norm(sum(EN[en][h] for h in hs))
                    Q[k] = norm((1 - a) * Qt[k] + a * e)
        on = {"늘": np.ones(len(Q), bool), "사람만": person, "안 함": np.zeros(len(Q), bool)}[sub]
        Q[on] = norm(Q[on] - np.outer(Q[on] @ c, c))
        return Q

    variants = [(0.0, "늘", "낱말")]  # 지금 앱
    variants += [(0.0, s, "낱말") for s in ("사람만", "안 함")]
    variants += [(a, s, "낱말") for s in ("늘", "사람만") for a in (0.2, 0.3, 0.4, 0.5, 0.6, 0.7)]
    variants += [(a, "사람만", "문형") for a in (0.2, 0.3, 0.5, 0.7)]
    groups = list(GROUPS)
    print("\n| 비율 a | 빼기 | 영어 꼴 | " + " | ".join(f"{g[0]} MRR" for g in groups) + " | " + " | ".join(f"{g[0]} 상위10" for g in groups) + " |")
    print("|---:|---|---|" + "---:|" * (2 * len(groups)))
    out = {}
    for a, s, en in variants:
        M = metrics(scores(build(a, s, en)), rel)
        out[(a, s, en)] = M
        cells = []
        for g in groups:
            x = M[G == g, 3]
            cells.append(f"{x.mean():.2f} ±{x.std(ddof=1) / np.sqrt(len(x)):.2f}")
        print(f"| {a} | {s} | {en} | " + " | ".join(cells) + " | " + " | ".join(f"{M[G == g, 0].mean():.0%}" for g in groups) + " |")
    base = out[(0.0, "늘", "낱말")]
    for key in [k for k in out if k != (0.0, "늘", "낱말") and k[0] in (0.0, 0.3) and k[2] == "낱말"]:
        print(f"\n첫 정답 순위 (지금 → a={key[0]} 빼기 {key[1]}): " + ", ".join(
            f"{ko[k]} {base[k, 2]:.0f}→{out[key][k, 2]:.0f}" for k in range(len(ko)) if base[k, 2] != out[key][k, 2]))


def main() -> None:
    events, _, shot = final_events(Path(sys.argv[1]), verbose=False)
    truth = {e["key"]: e["text"] for e in json.loads((EVAL / "describe_truth.json").read_text(encoding="utf-8"))["events"]}
    texts = [truth[e[0]["id"]] for e in events]
    F = photo_features(shot)
    R = [representatives(e, F) for e in events]
    P = phone_vectors(Path(sys.argv[2]))
    keep = [i for i, r in enumerate(R) if any(x in P for x in r)]  # 폰 벡터가 있는 구간만(모든 비교에 같은 구간)
    reps = [[x for x in R[i] if x in P] for i in keep]
    allp = [[p["id"] for p in events[i]] for i in keep]
    T = [texts[i] for i in keep]
    nseg = len(keep)

    rows = [(g, *q) for g, qs in GROUPS.items() for q in qs]
    rel = [{j for j, t in enumerate(T) if re.search(q[3], t)} for q in rows]
    dropped = [q[1] for q, r in zip(rows, rel) if len(r) < 3]
    rows, rel = [q for q, r in zip(rows, rel) if len(r) >= 3], [r for r in rel if len(r) >= 3]
    G = np.array([q[0] for q in rows])
    ko, en, strip = [q[1] for q in rows], [q[2] for q in rows], [q[4] for q in rows]
    print(f"구간 {nseg}개(폰 벡터 있는 것) · 대표 사진 {sum(map(len, reps))}장 · 구간 사진 {sum(map(len, allp))}장 · "
          f"검색어 {len(rows)}개" + (f" · 정답 3개 미만이라 뺀 검색어: {', '.join(dropped)}" if dropped else ""))

    enc = TextEnc()
    c = norm(enc(GENERIC).mean(0))
    deq = lambda Q: norm(Q - np.outer(Q @ c, c))

    def seg_scores(Q, bank: dict, groups: list[list[int]], tiles: dict | None = None):
        ids = sorted({x for g in groups for x in g})
        col = {x: k for k, x in enumerate(ids)}
        S = Q @ norm(np.array([bank[x] for x in ids])).T
        if tiles is not None:  # 사진 점수 = max(전체, 타일 4개)
            for t in range(4):
                S = np.maximum(S, Q @ norm(np.array([tiles[f"t{t}:{x}"] for x in ids])).T)
        return np.stack([S[:, [col[x] for x in g]].max(1) for g in groups], axis=1)

    def table(title: str, variants: dict[str, np.ndarray], note: str = "") -> dict[str, np.ndarray]:
        print(f"\n### {title}" + (f"\n{note}" if note else ""))
        print("| 묶음 | 방식 | 검색어 | 상위10 정밀도 | 상위20 재현율 | 첫 정답 순위(중앙) | MRR (±표준오차) |")
        print("|---|---|---:|---:|---:|---:|---:|")
        res = {name: metrics(S, rel) for name, S in variants.items()}
        for g in GROUPS:
            m = G == g
            if not m.any():
                continue
            for name, M in res.items():
                x = M[m]
                se = x[:, 3].std(ddof=1) / np.sqrt(len(x))
                print(f"| {g} | {name} | {m.sum()} | {x[:, 0].mean():.0%} | {x[:, 1].mean():.0%} | {np.median(x[:, 2]):.0f} | {x[:, 3].mean():.2f} ±{se:.2f} |")
        return res

    # ---- 1. 묶음별 (앱 방식: 폰 원본 w8 벡터, 문형 묶음 + 흔한 방향 빼기, 대표 사진 최고)
    Qt = enc.templated(ko)
    Pb = {x: P[x] for g in reps for x in g}
    app = seg_scores(deq(Qt), Pb, reps)
    if "--dict" in sys.argv:  # 개선 1·2(#23·#24)만 빠르게
        dict_eval(enc, ko, G, rel, Qt, c, lambda Q: seg_scores(Q, Pb, reps))
        return
    res = table("1. 묶음별 결과 (앱 방식)", {"앱": app})
    base = np.array([len(r) / nseg for r in rel])
    print("\n| 묶음 | 정답 구간 수(중앙) | 무작위 상위10 정밀도 |\n|---|---:|---:|")
    for g in GROUPS:
        m = G == g
        print(f"| {g} | {np.median([len(rel[k]) for k in np.where(m)[0]]):.0f} | {base[m].mean():.1%} |")
    print("\n검색어별 (앱 방식): 검색어 | 묶음 | 정답 수 | 상위10 정밀도 | 상위20 재현율 | 첫 정답 순위")
    print("|검색어|묶음|정답 수|상위10|상위20 재현|첫 정답|\n|---|---|---:|---:|---:|---:|")
    for k, q in enumerate(rows):
        M = res["앱"][k]
        print(f"| {q[1]} | {q[0][0]} | {len(rel[k])} | {M[0]:.0%} | {M[1]:.0%} | {M[2]:.0f} |")

    # ---- 3. 흔한 방향 빼기
    table("원인 3. 흔한 방향 빼기 켬/끔", {"빼기 켬(앱)": app, "빼기 끔": seg_scores(Qt, Pb, reps)})
    Qraw = enc(ko)
    cosc = Qraw @ c
    print("\n| 묶음 | GENERIC 평균과 검색어 코사인(평균) | 최소 | 최대 |\n|---|---:|---:|---:|")
    for g in GROUPS:
        x = cosc[G == g]
        print(f"| {g} | {x.mean():.3f} | {x.min():.3f} | {x.max():.3f} |")
    print("검색어별 코사인 상위: " + ", ".join(f"{ko[k]} {cosc[k]:.2f}" for k in np.argsort(-cosc)[:8]))

    # ---- 4. 대표만 vs 구간 모든 사진 (둘 다 PC 썸네일 벡터)
    E = embed(sorted({x for g in allp for x in g}))
    Sr, Sa = seg_scores(deq(Qt), E, reps), seg_scores(deq(Qt), E, allp)
    table("원인 4. 대표 사진만 vs 구간 모든 사진 (PC 썸네일 160px 벡터, 첫 줄은 비교용 폰 원본 벡터)",
          {"대표만(폰 원본)": app, "대표만(썸네일)": Sr, "모든 사진(썸네일)": Sa})
    print("\n| 묶음 | 정답 구간에서 가장 닮은 사진이 대표가 아닌 비율 | 대표만으로 상위20 밖이던 정답 중 모든 사진이면 상위20 안 |\n|---|---:|---:|")
    Qd = deq(Qt)
    for g in GROUPS:
        notrep = tot = miss = rescued = 0
        for k in np.where(G == g)[0]:
            ordr, orda = list(np.argsort(-Sr[k])), list(np.argsort(-Sa[k]))
            for j in rel[k]:
                best = max(allp[j], key=lambda x: float(Qd[k] @ norm(E[x])))
                notrep += best not in reps[j]
                tot += 1
                if ordr.index(j) >= 20:
                    miss += 1
                    rescued += orda.index(j) < 20
        print(f"| {g} | {notrep / tot:.0%} ({notrep}/{tot}) | {rescued}/{miss} |")
    print(f"구간당 사진 수 중앙 {np.median([len(a) for a in allp]):.0f}장, 대표 {np.median([len(r) for r in reps]):.0f}장")

    # ---- 5. w8 vs fp32, 2. 타일 (대표 사진 썸네일)
    V = vision_cache(sorted({x for g in reps for x in g}))
    fpb = {x: V[f"fp:{x}"] for g in reps for x in g}
    Qfp = enc.templated(ko, "text")
    Sfp = seg_scores(deq(Qt), fpb, reps)
    c_fp = norm(enc(GENERIC, "text").mean(0))
    Sfpfp = seg_scores(norm(Qfp - np.outer(Qfp @ c_fp, c_fp)), fpb, reps)
    r5 = table("원인 5. 가중치 8비트(w8) vs fp32 (대표 사진 썸네일)",
               {"비전 w8 + 텍스트 w8": Sr, "비전 fp32 + 텍스트 w8": Sfp, "비전 fp32 + 텍스트 fp32": Sfpfp})
    ov = [len(set(np.argsort(-Sr[k])[:10]) & set(np.argsort(-Sfpfp[k])[:10])) / 10 for k in range(len(rows))]
    vcos = [float(norm(E[x]) @ norm(fpb[x])) for x in fpb]
    print(f"상위10 겹침(w8/w8 vs fp/fp) 평균 {np.mean(ov):.0%} · 사진 벡터 코사인(w8 vs fp32) 평균 {np.mean(vcos):.4f} / 최소 {np.min(vcos):.4f}")

    St = seg_scores(deq(Qt), E, reps, tiles=V)
    r2 = table("원인 2. 2×2 타일 최고 점수 (대표 사진 썸네일, 사진 점수 = max(전체, 타일 4))",
               {"전체만(썸네일)": Sr, "+타일": St})
    print("\n묶음 C 검색어별 첫 정답 순위 (전체만 → +타일): " + ", ".join(
        f"{ko[k]} {r2['전체만(썸네일)'][k, 2]:.0f}→{r2['+타일'][k, 2]:.0f}" for k in np.where(G == "C 배경 시설물")[0]))

    # ---- 6. 한국어 vs 영어 (낱말만, 빼기 켬, 폰 벡터)
    Qen = enc(en)
    r6 = table("원인 6. 한국어 vs 영어 (낱말만, 흔한 방향 빼기 켬, 폰 원본 벡터)",
               {"한국어": seg_scores(deq(Qraw), Pb, reps), "영어": seg_scores(deq(Qen), Pb, reps)})
    for g in GROUPS:
        m = np.where(G == g)[0]
        print(f"{g} 첫 정답 순위 (한국어 → 영어): " + ", ".join(
            f"{ko[k]}/{en[k]} {r6['한국어'][k, 2]:.0f}→{r6['영어'][k, 2]:.0f}" for k in m))
    # 개선 시험: 앱 방식 한국어 벡터에 같은 뜻 영어 벡터를 더해 평균(사전으로 붙인다고 가정)
    table("개선 시험. 앱 방식 + 영어 뜻 벡터 평균 (흔한 방향 빼기 켬, 폰 원본 벡터)",
          {"앱(한국어)": app, "앱 + 영어 평균": seg_scores(deq(norm(Qt + Qen)), Pb, reps)})
    print("\n| 묶음 | 한국어 토큰 수(평균) | 영어 토큰 수(평균) |\n|---|---:|---:|")
    for g in GROUPS:
        m = np.where(G == g)[0]
        print(f"| {g} | {np.mean([enc.pieces(ko[k]) for k in m]):.1f} | {np.mean([enc.pieces(en[k]) for k in m]):.1f} |")

    # ---- 1. 동작: 동작 낱말을 뺀 검색어와 비교, 묶음 안 1위 비율
    mB = np.where(G == "B 동작")[0]
    Qs = enc.templated([strip[k] for k in mB])
    Ss = seg_scores(deq(Qs), Pb, reps)
    Ms = metrics(Ss, [rel[k] for k in mB])
    Ma = res["앱"][mB]
    print("\n### 원인 1. 동작 낱말을 뺀 검색어와 비교 (앱 방식)")
    print("| 검색어 | 뺀 검색어 | 첫 정답 순위 (동작 있음 → 뺌) | MRR (있음 → 뺌) | 상위10 정밀도 (있음 → 뺌) |\n|---|---|---|---|---|")
    for i, k in enumerate(mB):
        print(f"| {ko[k]} | {strip[k]} | {Ma[i, 2]:.0f} → {Ms[i, 2]:.0f} | {Ma[i, 3]:.2f} → {Ms[i, 3]:.2f} | {Ma[i, 0]:.0%} → {Ms[i, 0]:.0%} |")
    print(f"| 평균 | | 중앙 {np.median(Ma[:, 2]):.0f} → {np.median(Ms[:, 2]):.0f} | {Ma[:, 3].mean():.2f} → {Ms[:, 3].mean():.2f} | {Ma[:, 0].mean():.0%} → {Ms[:, 0].mean():.0%} |")

    print("\n묶음 안 고르기: 정답 구간마다 같은 묶음 검색어 중 가장 높은 점수의 검색어가 맞는(정규식이 맞는) 비율")
    print("| 묶음 | 검색어 수 | 정답 구간 | 1위가 맞음 | 무작위 |\n|---|---:|---:|---:|---:|")
    for g in GROUPS:
        m = np.where(G == g)[0]
        segs = sorted(set().union(*[rel[k] for k in m]))
        ok = [any(j in rel[m[a]] for a in [int(np.argmax(app[m, j]))]) for j in segs]
        chance = [np.mean([j in rel[k] for k in m]) for j in segs]
        print(f"| {g} | {len(m)} | {len(segs)} | {np.mean(ok):.0%} | {np.mean(chance):.0%} |")


if __name__ == "__main__":
    main()
