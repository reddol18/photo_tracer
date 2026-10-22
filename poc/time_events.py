"""갤러리 메타데이터(phone_bench.py scan 결과)로 시간 구간(이벤트)을 나누고, 대표 사진만 분석할 때의 계산량을 추정한다.

사용: uv run time_events.py ../eval_data/phone/meta_*.json
  1) 날짜 출처 분류: 카메라 EXIF / 기타 EXIF(스크린샷 등) / 날짜 없음
  2) 촬영 시각을 믿을 수 있는 '찍은 사진'만 시간순으로 놓고 경계를 찾는다.
     기본: 3시간 안 + 1km 안이면 같은 구간(split_place). 비교용으로 적응형 간격(PhotoTOC)도 돌린다.
  3) 구간 크기 분포와, 구간마다 대표 사진 k장만 돌릴 때 장면 모델 시간을 비교한다.
결과 CSV(구간 목록)는 eval_data/에만 쓴다 (위치·날짜가 들어 있어 저장소 제외).
"""
import argparse
import collections
import csv
import json
import math
import statistics
from datetime import datetime
from pathlib import Path

EVAL = Path(__file__).parent.parent / "eval_data"
# 폰 측정(장당 SigLIP 시간, XNNPACK 끔)
SIGLIP_S = {"384_w8": 2.89, "512_w8": 5.79}
SCREEN_DIRS = ("DCIM/Screenshots", "DCIM/Videocaptures")


def source(p: dict) -> str:
    """시간 구간에 쓸 수 있는지 판단할 날짜 출처."""
    if not p.get("exif_dt"):
        return "날짜 없음"  # 카톡 내보내기·인스타·다운로드 등: 파일 날짜는 받은/저장한 시각이라 못 씀
    if p["path"].startswith(SCREEN_DIRS) or (not p.get("make") and p["mime"] == "image/png"):
        return "화면 캡처"  # 시각은 맞지만 장소 사진이 아니다
    return "카메라" if p.get("make") else "기타 EXIF"


def taken(p: dict) -> datetime | None:
    try:
        return datetime.strptime(p["exif_dt"].strip()[:19], "%Y:%m:%d %H:%M:%S")
    except (ValueError, KeyError):
        return None


def km(a: dict, b: dict) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a["lat"], a["lon"], b["lat"], b["lon"]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def split(photos: list[dict], k: float, d: int, max_gap_h: float, move_km: float) -> list[list[dict]]:
    gaps = [max(1.0, (b["t"] - a["t"]).total_seconds()) for a, b in zip(photos, photos[1:])]
    logs = [math.log(g) for g in gaps]
    events, cur = [], [photos[0]]
    for i, g in enumerate(gaps):
        window = logs[max(0, i - d): i + d + 1]
        adaptive = logs[i] >= k + sum(window) / len(window)
        a, b = photos[i], photos[i + 1]
        moved = "lat" in a and "lat" in b and km(a, b) > move_km
        if g > max_gap_h * 3600 or (adaptive and g > 300) or moved:  # 5분 안쪽은 연사라 끊지 않는다
            events.append(cur)
            cur = []
        cur.append(b)
    events.append(cur)
    return events


def split_place(photos: list[dict], gap_h: float, move_km: float) -> list[list[dict]]:
    """시간 + 장소 규칙: gap_h 시간 안에 이어 찍었고, 마지막 GPS 위치에서 move_km 안이면 같은 구간.
    이 갤러리는 몇 장씩 짧게 찍고 멈추는 사진이 많아, 적응형 간격은 한 번의 외출을 1~2분 단위로 쪼갰다."""
    events, cur = [], [photos[0]]
    last = photos[0] if "lat" in photos[0] else None
    for a, b in zip(photos, photos[1:]):
        far = last is not None and "lat" in b and km(last, b) > move_km
        if (b["t"] - a["t"]).total_seconds() > gap_h * 3600 or far:
            events.append(cur)
            cur, last = [], None
        cur.append(b)
        if "lat" in b:
            last = b
    events.append(cur)
    return events


def reps(n: int) -> int:
    """구간당 대표 사진 수: 1장, 2~3장 → 1, 4~7 → 2, 8~15 → 3 … 최대 5."""
    return min(5, 1 + int(math.log2(n)) - (1 if n > 1 else 0)) if n > 1 else 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("meta", type=Path)
    ap.add_argument("--gap-h", type=float, default=3)
    ap.add_argument("--place-km", type=float, default=1.0)
    ap.add_argument("--k", type=float, default=math.log(17), help="PhotoTOC 기본값 log(17)")
    ap.add_argument("--d", type=int, default=10)
    ap.add_argument("--max-gap-h", type=float, default=24)
    ap.add_argument("--move-km", type=float, default=2.0)
    args = ap.parse_args()
    P = json.loads(args.meta.read_text(encoding="utf-8"))["photos"]

    by_src = collections.Counter(source(p) for p in P)
    print(f"전체 {len(P)}장 · 날짜 출처: " + ", ".join(f"{k} {v}" for k, v in by_src.most_common()))
    shot = []
    for p in P:
        if source(p) in ("카메라", "기타 EXIF") and (t := taken(p)):
            shot.append({**p, "t": t})
    shot.sort(key=lambda p: p["t"])
    gps = sum("lat" in p for p in shot)
    print(f"구간 대상(촬영 시각 있는 찍은 사진) {len(shot)}장 · GPS 있음 {gps}장")

    events = split_place(shot, args.gap_h, args.place_km)
    print(f"규칙: {args.gap_h}시간 안 + {args.place_km}km 안이면 같은 구간")
    sizes = [len(e) for e in events]
    n_reps = sum(reps(n) for n in sizes)
    print(f"\n구간 {len(events)}개 · 크기 중앙값 {statistics.median(sizes):.0f} · 평균 {statistics.mean(sizes):.1f}"
          f" · 1장짜리 {sum(n == 1 for n in sizes)}개 · 최대 {max(sizes)}")
    hist = collections.Counter(next(b for b in (1, 3, 7, 15, 31, 63, 10**9) if n <= b) for n in sizes)
    print("  크기 분포: " + " · ".join(f"{'≤' + str(b) if b < 10**9 else '64+'}: {hist[b]}"
                                    for b in (1, 3, 7, 15, 31, 63, 10**9)))
    dur = [(e[-1]["t"] - e[0]["t"]).total_seconds() / 60 for e in events if len(e) > 1]
    print(f"  구간 길이(2장 이상) 중앙값 {statistics.median(dur):.0f}분 · 90% {sorted(dur)[int(len(dur) * .9)]:.0f}분")

    print(f"\n장면 모델 계산량 (구간 대상 {len(shot)}장)")
    print(f"  대표 사진만: {n_reps}장 ({n_reps / len(shot):.0%})")
    for name, s in SIGLIP_S.items():
        print(f"  {name}: 전부 {len(shot) * s / 3600:.1f}시간 → 대표만 {n_reps * s / 3600:.1f}시간")
    rest = by_src["날짜 없음"] + by_src["화면 캡처"]
    print(f"  (날짜 없음·화면 캡처 {rest}장은 별도 — 전부 돌리면 384_w8 {rest * SIGLIP_S['384_w8'] / 3600:.1f}시간)")

    print("\n경계 기준 비교 (구간 수 · 대표 사진 수)")
    for h, m in ((3, 3.0), (6, 1.0)):
        ev = split_place(shot, h, m)
        print(f"  {h}시간·{m}km: {len(ev)}개 · {sum(reps(len(e)) for e in ev)}장")
    for k in (math.log(8), math.log(17), math.log(40)):  # 적응형 간격(PhotoTOC): 이 갤러리에선 너무 잘게 쪼갬
        ev = split(shot, k, args.d, args.max_gap_h, args.move_km)
        print(f"  적응형 K=log({math.exp(k):.0f}): {len(ev)}개 · {sum(reps(len(e)) for e in ev)}장")
    for h in (1, 3):  # 비교: 고정 간격
        ev = split(shot, 1e9, args.d, h, 1e9)
        print(f"  고정 {h}시간 간격: {len(ev)}개 · {sum(reps(len(e)) for e in ev)}장")

    out = EVAL / "time_events.csv"
    with open(out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["event", "start", "end", "photos", "reps", "gps", "folders"])
        for i, e in enumerate(events):
            folders = collections.Counter(p["path"].rstrip("/") for p in e)
            w.writerow([i, e[0]["t"], e[-1]["t"], len(e), reps(len(e)), sum("lat" in p for p in e),
                        "; ".join(f"{k}({v})" for k, v in folders.most_common(3))])
    print(f"\n구간 목록: {out}")


if __name__ == "__main__":
    main()
