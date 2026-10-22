"""폰 속도 측정을 PC에서 조작한다: 설치 → 사진·모델 넣기 → 실행 → 결과 받기 → 정리.

사용:
  uv run phone_bench.py push            # APK 설치, 사진·모델·설정을 폰의 앱 전용 폴더에 복사
  uv run phone_bench.py run             # 앱을 autorun으로 띄우고 끝날 때까지 기다린 뒤 결과를 받아 정리
  uv run phone_bench.py report FILE     # 받은 결과 JSON만 다시 정리
결과 정리에는 PC 결과와의 비교가 들어간다:
  - ML Kit 얼굴 수 vs PC YuNet 얼굴 수 (eval_data/photos.csv)
  - 폰 SigLIP 임베딩 vs PC onnxruntime 임베딩 (같은 ONNX, 전처리 차이 확인)
"""
import argparse
import csv
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).parent
PKG = "com.reddol18.phototracer.bench_app"
REMOTE = f"/sdcard/Android/data/{PKG}/files/bench"
APK = ROOT.parent / "bench_app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
MODELS = ROOT / "models"
EVAL = ROOT.parent / "eval_data"
OUT = EVAL / "phone"
PHOTOS = Path(r"E:\claude-dev\test_pictures")
DEFAULT_CONFIG = {
    "limit": 40, "threads": 4, "xnnpack": False, "mlkit": "fast", "dump": 10,
    # PC 품질 비교(compare_quant.py)를 통과한 후보만. 동적 INT8·256px는 품질 미달로 뺐다.
    "siglip": ["vision_384.onnx", "vision_384_w8.onnx", "vision_384_fp16.onnx", "vision_384_w4.onnx",
               "vision_512_w8.onnx"],
}


def adb(*args: str, check: bool = True) -> str:
    exe = Path(os.environ.get("ANDROID_HOME", "")) / "platform-tools" / "adb.exe"
    res = subprocess.run([str(exe if exe.exists() else "adb"), *args], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if check and res.returncode != 0:
        sys.exit(f"adb {' '.join(args)} 실패: {res.stderr.strip()}")
    return res.stdout


def push(config: dict) -> None:
    print("APK 설치…"); adb("install", "-r", str(APK))
    adb("shell", "mkdir", "-p", f"{REMOTE}/photos", f"{REMOTE}/models")
    # 앱이 한 번도 실행되지 않으면 외부 파일 폴더가 없을 수 있어 직접 만든다
    names = ["face_recognition_sface_2021dec.onnx"] + config["siglip"]
    for name in names:
        src = MODELS / name if (MODELS / name).exists() else MODELS / "siglip" / name
        print(f"모델 {name} ({src.stat().st_size / 1e6:.0f}MB)…"); adb("push", str(src), f"{REMOTE}/models/{name}")
    files = sorted(p for p in PHOTOS.rglob("*") if p.is_file())[: config["limit"]]
    print(f"사진 {len(files)}장…")
    for p in files:  # 연도 폴더 이름을 앞에 붙여 이름 충돌을 막고, PC 결과와 맞춰 볼 수 있게 한다
        adb("push", str(p), f"{REMOTE}/photos/{p.parent.name}__{p.name}")
    cfg = EVAL / "phone_config.json"
    cfg.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
    adb("push", str(cfg), f"{REMOTE}/config.json")
    print("완료")


def run() -> Path:
    before = set(adb("shell", "ls", REMOTE).split())
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-n", f"{PKG}/.MainActivity", "--ez", "autorun", "true")
    print("측정 중… (화면을 켜 둔 채로 두세요)")
    start = time.time()
    while True:
        time.sleep(10)
        new = [n for n in adb("shell", "ls", REMOTE).split() if n.startswith("result_") and n not in before]
        if new:
            break
        print(f"  {int(time.time() - start)}초 경과")
    OUT.mkdir(parents=True, exist_ok=True)
    dst = OUT / new[0]
    adb("pull", f"{REMOTE}/{new[0]}", str(dst))
    return dst


def med(values) -> float:
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else float("nan")


def report(path: Path) -> None:
    import onnxruntime as ort  # PC 비교용
    from export_siglip import preprocess

    r = json.loads(path.read_text(encoding="utf-8"))
    rows = [x for x in r["photos"] if "error" not in x]
    d = r["device"]
    print(f"기기 {d['model']} ({d['soc']}, API {d['sdk']}, 코어 {d['cores']}) · 사진 {len(rows)}장"
          f" · 설정 {json.dumps(r['config'], ensure_ascii=False)}")
    print(f"모델 로드 ms: {r['load_ms']}")
    s, e = r["start"], r["end"]
    print(f"발열 상태 {s['thermal']}→{e['thermal']} · 배터리 온도 {s['battery_temp_c']}→{e['battery_temp_c']}℃ · "
          f"배터리 {s['battery_pct']}→{e['battery_pct']}% · 충전 중 {s['charging']} · 경과 {(e['t'] - s['t']) / 1000:.0f}초")

    print("\n단계별 중앙값 (ms/장)")
    print(f"  디코드 {med(x['decode_ms'] for x in rows):.0f} · ML Kit 검출 {med(x['mlkit_ms'] for x in rows):.0f}"
          f" · SFace(얼굴 있는 사진, 얼굴 전부) {med(x.get('sface_ms') for x in rows if x['faces']):.0f}")
    base = med(x["decode_ms"] + x["mlkit_ms"] + x.get("sface_ms", 0) for x in rows)
    for name in r["config"].get("siglip", []):
        m = med(x["siglip_ms"].get(name) for x in rows)
        total = base + m
        print(f"  {name:24s} {m:6.0f}  → 사진 1장 전체 {total:6.0f}ms · 1만 장 {total * 10000 / 3.6e6:5.1f}시간")

    # PC YuNet과 얼굴 수 비교
    pc = {}
    with open(EVAL / "photos.csv", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            pc[row["photo"].replace("/", "__")] = int(row["faces"]) + int(row["small_faces"])
    pairs = [(x["faces"], pc[x["photo"]]) for x in rows if x["photo"] in pc]
    same = sum(a == b for a, b in pairs)
    print(f"\n얼굴 수: ML Kit = PC YuNet 인 사진 {same}/{len(pairs)} · ML Kit 합계 {sum(a for a, _ in pairs)}"
          f" vs YuNet 합계 {sum(b for _, b in pairs)} · 정렬(랜드마크 5점) 성공 "
          f"{sum(x.get('aligned', 0) for x in rows)}/{sum(min(x['faces'], 10) for x in rows)}")

    # 폰 임베딩 vs PC 임베딩 (같은 ONNX)
    print("\nSigLIP 폰 vs PC 코사인 (같은 모델, 디코드·리사이즈 차이만 남음)")
    for name, embs in r.get("embeddings", {}).items():
        sess = ort.InferenceSession(str(MODELS / "siglip" / name), providers=["CPUExecutionProvider"])
        res = int(name.split("_")[1])
        cos = []
        for photo, vec in embs.items():
            year, fname = photo.split("__", 1)
            pc_emb = sess.run(None, {"pixel_values": preprocess(PHOTOS / year / fname, res)})[0][0]
            cos.append(float(np.dot(vec, pc_emb) / np.linalg.norm(vec)))
        print(f"  {name:24s} 평균 {np.mean(cos):.4f} · 최소 {np.min(cos):.4f} ({len(cos)}장)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["push", "run", "report"])
    ap.add_argument("file", nargs="?", type=Path)
    ap.add_argument("--limit", type=int, default=DEFAULT_CONFIG["limit"])
    ap.add_argument("--xnnpack", action="store_true")
    args = ap.parse_args()
    if args.cmd == "push":
        push({**DEFAULT_CONFIG, "limit": args.limit, "xnnpack": args.xnnpack})
    elif args.cmd == "run":
        report(run())
    else:
        report(args.file)


if __name__ == "__main__":
    main()
