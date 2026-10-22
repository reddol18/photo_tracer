"""평가 사진에서 얼굴을 검출(YuNet)하고 임베딩(SFace)을 뽑아 eval_data/ 에 저장한다.

사용: uv run extract_faces.py E:\\claude-dev\\test_pictures
  - 사진 폴더 아래 연도별 하위 폴더(2023/, 2024/ …)를 가정한다. 폴더 이름이 곧 정답 연도다.
  - 결과(얼굴 크롭·임베딩)는 가족 얼굴이므로 저장소 밖으로 내보내지 않는다. eval_data/ 는 .gitignore 대상.
"""
import argparse
import csv
import json
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener

register_heif_opener()

MODEL_DIR = Path(__file__).parent / "models"
DEFAULT_OUT = Path(__file__).parent.parent / "eval_data"
EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp"}
DETECT_LONG_SIDE = 1280  # 폰에서도 원본이 아니라 축소본으로 검출할 예정
MIN_FACE_PX = 32         # 이보다 작은 얼굴은 임베딩 품질이 낮아 '작음'으로만 기록


def sniff_format(path: Path) -> str:
    """확장자가 아니라 파일 앞부분으로 실제 형식을 판별한다 (.jpg 이름의 HEIC가 있음)."""
    head = path.read_bytes()[:16]
    if head[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if head[4:8] == b"ftyp":
        return head[8:12].decode("ascii", "replace").strip()  # heic, mif1 …
    if head[:4] == b"RIFF":
        return "webp"
    return "unknown"


def load_bgr(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("photos", type=Path)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--score", type=float, default=0.8, help="YuNet 검출 점수 하한")
    args = ap.parse_args()

    crops_dir = args.out / "crops"
    crops_dir.mkdir(parents=True, exist_ok=True)
    detector = cv2.FaceDetectorYN.create(
        str(MODEL_DIR / "face_detection_yunet_2023mar.onnx"), "", (320, 320), args.score, 0.3, 5000)
    recognizer = cv2.FaceRecognizerSF.create(
        str(MODEL_DIR / "face_recognition_sface_2021dec.onnx"), "")

    paths = sorted(p for p in args.photos.rglob("*") if p.suffix.lower() in EXTS)
    photo_rows, face_rows, embeddings = [], [], []
    for i, path in enumerate(paths, 1):
        rel = path.relative_to(args.photos).as_posix()
        row = {"photo": rel, "year": path.parent.name, "format": sniff_format(path),
               "faces": 0, "small_faces": 0, "detect_ms": "", "embed_ms": "", "error": ""}
        try:
            img = load_bgr(path)
        except Exception as e:  # 깨진 파일도 앱은 건너뛰고 계속 가야 하므로 기록만 한다
            row["error"] = f"{type(e).__name__}: {e}"
            photo_rows.append(row)
            continue

        scale = min(1.0, DETECT_LONG_SIDE / max(img.shape[:2]))
        small = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else img
        detector.setInputSize((small.shape[1], small.shape[0]))
        t0 = time.perf_counter()
        _, dets = detector.detect(small)
        t1 = time.perf_counter()
        row["detect_ms"] = round((t1 - t0) * 1000, 1)

        embed_time = 0.0
        for det in dets if dets is not None else []:
            det = det.copy()
            det[:14] /= scale  # 원본 좌표로 되돌려 원본에서 정렬·크롭
            w, h = det[2], det[3]
            if min(w, h) < MIN_FACE_PX:
                row["small_faces"] += 1
                continue
            t2 = time.perf_counter()
            aligned = recognizer.alignCrop(img, det)
            feat = recognizer.feature(aligned).flatten()
            embed_time += time.perf_counter() - t2
            face_id = f"f{len(face_rows):05d}"
            cv2.imwrite(str(crops_dir / f"{face_id}.jpg"), aligned)
            embeddings.append(feat / np.linalg.norm(feat))
            face_rows.append({"face_id": face_id, "photo": rel, "year": row["year"],
                              "bbox": [round(float(v)) for v in det[:4]], "score": round(float(det[14]), 3)})
            row["faces"] += 1
        row["embed_ms"] = round(embed_time * 1000, 1)
        photo_rows.append(row)
        if i % 25 == 0 or i == len(paths):
            print(f"{i}/{len(paths)}  얼굴 {len(face_rows)}개")

    np.save(args.out / "embeddings.npy", np.array(embeddings, dtype=np.float32))
    with open(args.out / "faces.json", "w", encoding="utf-8") as f:
        json.dump(face_rows, f, ensure_ascii=False, indent=1)
    with open(args.out / "photos.csv", "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(photo_rows[0]))
        w.writeheader()
        w.writerows(photo_rows)

    ok = [r for r in photo_rows if not r["error"]]
    with_face = sum(1 for r in ok if r["faces"])
    print(f"\n사진 {len(paths)}장 (오류 {len(paths) - len(ok)}) · 얼굴 있는 사진 {with_face}장 · 얼굴 {len(face_rows)}개"
          f" · 작은 얼굴 제외 {sum(r['small_faces'] for r in ok)}개")
    print("실제 형식:", {fmt: sum(1 for r in photo_rows if r["format"] == fmt) for fmt in {r["format"] for r in photo_rows}})
    print(f"PC 기준 평균 검출 {np.mean([r['detect_ms'] for r in ok]):.0f}ms/장, "
          f"임베딩 {sum(r['embed_ms'] for r in ok) / max(1, len(face_rows)):.0f}ms/얼굴")


if __name__ == "__main__":
    main()
