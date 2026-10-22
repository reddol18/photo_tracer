"""labels.json(사람이 붙인 정답)으로 얼굴 인식 정확도를 잰다.

사용: uv run evaluate.py
앱의 실제 흐름을 흉내 낸다: 사용자가 사람마다 얼굴 몇 개를 '이 사람이 누구'라고 등록하면,
나머지 얼굴은 등록 얼굴과의 최대 코사인 유사도로 배정하고, 기준 미만이면 '모르는 얼굴'로 둔다.

- 등록 대상: 이름(호칭)이 있고 관계가 '딸의친구'가 아닌 사람 = 가족·친척 (앱이 인물로 관리할 사람)
- 미등록 얼굴: '모르는 사람', '딸의친구' 등 → 가족으로 배정되면 오분류(거짓 양성)
- 빈 라벨: 판별 불가 → 제외
결과에는 이름 대신 관계만 출력한다 (로그·영상에 실명이 남지 않게).
"""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

DEFAULT_DATA = Path(__file__).parent.parent / "eval_data"
NOT_ENROLLED = {"모르는 사람", "딸의친구", "얼굴아님"}
RUNS = 30


def load(data: Path):
    faces = json.loads((data / "faces.json").read_text(encoding="utf-8"))
    emb = np.load(data / "embeddings.npy")
    labels = json.loads((data / "labels.json").read_text(encoding="utf-8"))
    # 사람은 이름으로 구분하되 출력용 키는 관계로 만든다. 관계가 겹치면(조카딸 둘) 번호를 붙인다.
    rel_of = {}
    for lab in labels.values():
        name, rel = lab.get("name", "").strip(), lab.get("relation", "").strip()
        if name and rel not in NOT_ENROLLED:
            rel_of.setdefault(name, (rel, lab.get("birth_year") or 0))
    by_rel = defaultdict(list)
    for name, (rel, birth) in rel_of.items():
        by_rel[rel].append((birth, name))
    key_of = {}
    for rel, items in by_rel.items():
        for n, (_, name) in enumerate(sorted(items), 1):  # 나이 많은 순으로 번호
            key_of[name] = rel if len(items) == 1 else f"{rel}{n}"

    rows = []
    for i, f in enumerate(faces):
        lab = labels.get(f["face_id"], {})
        name, rel = lab.get("name", "").strip(), lab.get("relation", "").strip()
        if not name and not rel:
            continue  # 판별 불가
        person = key_of.get(name) if name and rel not in NOT_ENROLLED else None
        rows.append({"i": i, "photo": f["photo"], "year": int(f["year"]), "person": person,
                     "age": int(f["year"]) - lab["birth_year"] if person and lab.get("birth_year") else None})
    return rows, emb


def assign(emb, rows, gallery: dict[str, list[int]], threshold: float, margin: float = 0.0):
    """gallery: 사람 → 등록 얼굴 인덱스. 반환: 행마다 예측 사람(또는 None).
    margin: 1등과 2등 사람의 유사도 차이가 이보다 작으면 애매하므로 배정하지 않는다 (아이들끼리 헷갈림 방지)."""
    people = list(gallery)
    protos = [emb[gallery[p]] for p in people]
    preds = []
    for r in rows:
        sims = np.array([float((P @ emb[r["i"]]).max()) for P in protos])
        order = np.argsort(-sims)
        best, second = sims[order[0]], sims[order[1]] if len(order) > 1 else -1.0
        preds.append(people[order[0]] if best >= threshold and best - second >= margin else None)
    return preds


def score(rows, preds, skip: set[int]):
    """얼굴 단위 지표. skip = 등록에 쓴 얼굴(평가에서 뺌)."""
    tp, fp, fn = Counter(), Counter(), Counter()
    unknown_total = unknown_false = 0
    for r, p in zip(rows, preds):
        if r["i"] in skip:
            continue
        t = r["person"]
        if t is None:
            unknown_total += 1
            if p is not None:
                unknown_false += 1
                fp[p] += 1
            continue
        if p == t:
            tp[t] += 1
        else:
            fn[t] += 1
            if p is not None:
                fp[p] += 1
    return tp, fp, fn, unknown_total, unknown_false


def pick_gallery(rows, k: int, rng, per_year: bool):
    by_person = defaultdict(list)
    for r in rows:
        if r["person"]:
            by_person[(r["person"], r["year"]) if per_year else r["person"]].append(r["i"])
    gallery = defaultdict(list)
    for key, idx in by_person.items():
        person = key[0] if per_year else key
        gallery[person] += list(rng.choice(idx, size=min(k, len(idx)), replace=False))
    return gallery


def experiment(rows, emb, k, threshold, per_year=False, margin=0.0):
    agg = defaultdict(lambda: np.zeros(3))
    unk = np.zeros(2)
    for seed in range(RUNS):
        rng = np.random.default_rng(seed)
        gallery = pick_gallery(rows, k, rng, per_year)
        preds = assign(emb, rows, gallery, threshold, margin)
        tp, fp, fn, ut, uf = score(rows, preds, {i for v in gallery.values() for i in v})
        for p in set(tp) | set(fp) | set(fn):
            agg[p] += [tp[p], fp[p], fn[p]]
        unk += [ut, uf]
    return agg, unk


def summarize(agg, unk):
    t = sum(agg.values())
    prec = t[0] / max(1, t[0] + t[1])
    rec = t[0] / max(1, t[0] + t[2])
    return prec, rec, unk[1] / max(1, unk[0])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    args = ap.parse_args()
    rows, emb = load(args.data)

    counts = Counter(r["person"] or "(미등록)" for r in rows)
    print(f"평가 얼굴 {len(rows)}개 (판별 불가 제외) · 인물별: {dict(counts.most_common())}\n")

    print("■ 기준값별 전체 성능 (사람마다 무작위 등록 k개, 30회 평균)")
    print("  k   기준   정밀도  재현율  미등록→가족 오배정")
    for k in (1, 3, 5):
        for th in (0.30, 0.363, 0.40, 0.45, 0.50):
            p, r, u = summarize(*experiment(rows, emb, k, th))
            print(f"  {k}  {th:.3f}   {p:6.1%}  {r:6.1%}   {u:6.1%}")
    th = 0.363

    print(f"\n■ 인물별 (k=3, 기준 {th})")
    agg, _ = experiment(rows, emb, 3, th)
    for person, (tp, fp, fn) in sorted(agg.items(), key=lambda x: -counts[x[0]]):
        print(f"  {person:8s} 얼굴 {counts[person]:3d}  정밀도 {tp / max(1, tp + fp):6.1%}  재현율 {tp / max(1, tp + fn):6.1%}")

    print(f"\n■ 아이 나이에 따른 변화 (딸, 기준 {th}, 등록 3개)")
    daughter = [r for r in rows if r["person"] == "딸"]
    for label, years, per_year in (("2023년 얼굴로만 등록", {2023}, False),
                                   ("최근(2026) 얼굴로만 등록", {2026}, False),
                                   ("연도마다 3개씩 등록", None, True)):
        hits = Counter(); tot = Counter()
        for seed in range(RUNS):
            rng = np.random.default_rng(seed)
            pool = [r for r in rows if years is None or r["year"] in years or r["person"] != "딸"]
            gallery = pick_gallery(pool, 3, rng, per_year and True)
            used = {i for v in gallery.values() for i in v}
            preds = assign(emb, rows, gallery, th)
            for r, p in zip(rows, preds):
                if r["person"] == "딸" and r["i"] not in used:
                    tot[r["year"]] += 1
                    hits[r["year"]] += p == "딸"
        by_year = "  ".join(f"{y}: {hits[y] / tot[y]:5.1%}" for y in sorted(tot))
        print(f"  {label:18s} 연도별 재현율  {by_year}")

    print(f"\n■ 아이들끼리 헷갈림 (k=3, 기준 {th}): 실제 → 예측 횟수 (30회 합)")
    kids = {p for p in counts if p.startswith(("딸", "조카"))}
    conf = Counter()
    for seed in range(RUNS):
        rng = np.random.default_rng(seed)
        gallery = pick_gallery(rows, 3, rng, False)
        used = {i for v in gallery.values() for i in v}
        for r, p in zip(rows, assign(emb, rows, gallery, th)):
            if r["i"] in used:
                continue
            truth = r["person"] or "(미등록)"
            if (truth in kids or p in kids) and truth != p:
                conf[(truth, p or "(모름)")] += 1
    for (t, p), n in conf.most_common(8):
        print(f"  {t} → {p}: {n}")
    print("\n■ 개선안: 연도마다 3개씩 등록 + 1·2등 차이(margin) 조건")
    print("  기준   margin  정밀도  재현율  미등록→가족 오배정")
    for th, margin in ((0.363, 0.0), (0.363, 0.05), (0.363, 0.10), (0.45, 0.05), (0.45, 0.10)):
        p, r, u = summarize(*experiment(rows, emb, 3, th, per_year=True, margin=margin))
        print(f"  {th:.3f}  {margin:.2f}   {p:6.1%}  {r:6.1%}   {u:6.1%}")
    n_daughter = len(daughter)
    print(f"\n참고: 딸 얼굴 {n_daughter}개 중 연도별 {dict(sorted(Counter(r['year'] for r in daughter).items()))}")


if __name__ == "__main__":
    main()
