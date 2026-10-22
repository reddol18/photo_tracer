"""폰 속도 측정을 PC에서 조작한다: 설치 → 사진·모델 넣기 → 실행 → 결과 받기 → 정리.

사용:
  uv run phone_bench.py push            # APK 설치, 사진·모델·설정을 폰의 앱 전용 폴더에 복사
  uv run phone_bench.py config --limit 15 --xnnpack --siglip vision_384_w8.onnx   # 설정만 바꾸기(넣은 뒤 폰에서 다시 읽어 확인)
  uv run phone_bench.py run             # 앱을 autorun으로 띄우고 끝날 때까지 기다린 뒤 결과를 받아 정리
  uv run phone_bench.py report FILE     # 받은 결과 JSON만 다시 정리
  uv run phone_bench.py scan            # 갤러리 메타데이터(날짜·출처 폴더·GPS 100m 단위)만 받기 → time_events.py
  uv run phone_bench.py thumbs          # time_events.py가 고른 사진만 160px 썸네일로 받기 → event_review.py
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
    # adb가 만든 폴더는 shell 소유(rwxrws---)라 앱 계정이 목록을 못 읽고 결과도 못 쓴다
    adb("shell", "chmod", "777", REMOTE, f"{REMOTE}/photos", f"{REMOTE}/models")
    push_config(config)


def push_text(name: str, text: str) -> None:
    """작은 텍스트 파일을 bench/에 넣고, 폰에서 다시 읽어 내용·권한을 확인한다. 다르면 멈춘다."""
    local = EVAL / f"phone_{name}"
    local.write_bytes(text.encode("utf-8"))  # write_text는 Windows에서 줄바꿈을 \r\n으로 바꾼다
    # 직접 덮어쓰면 fchown 실패로 기존 파일만 지워진다. 임시 폴더를 거쳐 복사하고, 복사본은 shell 전용이라 권한을 연다
    adb("push", str(local), f"/data/local/tmp/{name}")
    adb("shell", "cp", f"/data/local/tmp/{name}", f"{REMOTE}/{name}")
    adb("shell", "chmod", "666", f"{REMOTE}/{name}")
    got = adb("shell", "cat", f"{REMOTE}/{name}").replace("\r", "").strip()  # adb shell 출력은 \n 앞에 \r을 붙인다
    if got != text.strip():
        sys.exit(f"폰의 {name}이(가) 넣은 것과 다릅니다:\n  넣음 {text[:300]}\n  폰   {got[:300]}")
    line = adb("shell", "ls", "-l", f"{REMOTE}/{name}").strip()
    if not line.startswith("-rw-rw-rw-"):
        sys.exit(f"앱이 못 읽는 권한: {line}")


def push_config(config: dict) -> None:
    """설정만 바꿔 넣는다."""
    push_text("config.json", json.dumps(config, ensure_ascii=False))
    for line in adb("shell", "ls", "-ld", REMOTE, f"{REMOTE}/photos", f"{REMOTE}/models").splitlines():
        if not line.startswith("drwxrwxrwx"):
            sys.exit(f"앱이 못 읽는 권한: {line}")
    print(f"설정 확인됨: {adb('shell', 'cat', f'{REMOTE}/config.json').strip()}")


def thumbs() -> Path:
    """time_events.py가 고른 사진만 폰에서 160px 썸네일로 만들어 eval_data/phone/thumbs/로 가져온다."""
    events = json.loads((EVAL / "time_events.json").read_text(encoding="utf-8"))
    ids = [i for e in events for i in e["ids"]]
    adb("install", "-r", str(APK))
    push_text("thumbs.txt", "\n".join(map(str, ids)))
    print(f"썸네일 {len(ids)}장 요청 (구간 {len(events)}개)")
    done = launch_and_fetch("thumbs", "thumbs_done_")
    made, fail = map(int, done.read_text().split())
    dst = OUT / "thumbs"
    dst.mkdir(parents=True, exist_ok=True)
    adb("pull", f"{REMOTE}/thumbs/.", str(dst))
    got = len(list(dst.glob("*.jpg")))
    print(f"폰: 요청 {made} · 실패 {fail} → PC에 받은 썸네일 {got}장")
    if got < made - fail:
        sys.exit("받은 썸네일이 폰에서 만든 수보다 적습니다")
    return dst


def run() -> Path:
    print(f"폰 설정: {adb('shell', 'cat', f'{REMOTE}/config.json').strip()}")
    return launch_and_fetch("autorun", "result_")


def scan() -> Path:
    """갤러리 메타데이터만 읽는다(사진 픽셀은 읽지 않음). 권한은 화면 대신 pm grant로 주고 확인한다."""
    adb("install", "-r", str(APK))
    perms = ["android.permission.READ_MEDIA_IMAGES", "android.permission.ACCESS_MEDIA_LOCATION"]
    for p in perms:
        adb("shell", "pm", "grant", PKG, p)
    dump = adb("shell", "dumpsys", "package", PKG)
    for p in perms:
        if f"{p}: granted=true" not in dump:
            sys.exit(f"권한이 안 들어갔습니다: {p}")
    return launch_and_fetch("scan", "meta_")


def launch_and_fetch(extra: str, prefix: str) -> Path:
    before = set(adb("shell", "ls", REMOTE).split())
    adb("shell", "am", "force-stop", PKG)
    adb("logcat", "-c")
    adb("shell", "am", "start", "-n", f"{PKG}/.MainActivity", "--ez", extra, "true")
    print("실행 중… (화면을 켜 둔 채로 두세요)")
    start = time.time()
    while True:
        time.sleep(10)
        new = [n for n in adb("shell", "ls", REMOTE).split() if n.startswith(prefix) and n not in before]
        if new:
            break
        # 결과 파일만 기다리면 앱 안의 오류·종료를 놓친다
        err = adb("logcat", "-d", "-s", "Bench:E")
        if "Bench" in err:
            sys.exit(f"앱 측정 실패:\n{err[-3000:]}")
        if not adb("shell", "pidof", PKG, check=False).strip():
            sys.exit("앱이 종료됐습니다 (logcat 확인)")
        print(f"  {int(time.time() - start)}초 경과")
    OUT.mkdir(parents=True, exist_ok=True)
    dst = OUT / new[0]
    adb("pull", f"{REMOTE}/{new[0]}", str(dst))
    if dst.stat().st_size == 0:
        sys.exit(f"받은 결과 파일이 비어 있습니다: {dst}")
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
        res = int(Path(name).stem.split("_")[1])
        cos = []
        for photo, vec in embs.items():
            year, fname = photo.split("__", 1)
            pc_emb = sess.run(None, {"pixel_values": preprocess(PHOTOS / year / fname, res)})[0][0]
            cos.append(float(np.dot(vec, pc_emb) / np.linalg.norm(vec)))
        print(f"  {name:24s} 평균 {np.mean(cos):.4f} · 최소 {np.min(cos):.4f} ({len(cos)}장)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["push", "config", "run", "report", "scan", "thumbs"])
    ap.add_argument("file", nargs="?", type=Path)
    ap.add_argument("--limit", type=int, default=DEFAULT_CONFIG["limit"])
    ap.add_argument("--xnnpack", action="store_true")
    ap.add_argument("--siglip", nargs="+", default=DEFAULT_CONFIG["siglip"])
    ap.add_argument("--dump", type=int, default=DEFAULT_CONFIG["dump"])
    args = ap.parse_args()
    config = {**DEFAULT_CONFIG, "limit": args.limit, "xnnpack": args.xnnpack, "siglip": args.siglip,
              "dump": args.dump}
    if args.cmd == "push":
        push(config)
    elif args.cmd == "config":  # 사진·모델은 그대로 두고 설정만 바꾼다
        push_config(config)
    elif args.cmd == "scan":
        print(f"받음: {scan()}")
    elif args.cmd == "thumbs":
        print(f"받음: {thumbs()}")
    elif args.cmd == "run":
        report(run())
    else:
        report(args.file)


if __name__ == "__main__":
    main()
