"""0단계에서 쓰는 모델 가중치를 poc/models/ 에 받는다 (저장소에는 올리지 않음).

- YuNet: 얼굴 검출 (OpenCV Zoo, MIT)
- SFace: 얼굴 임베딩 128차원 (OpenCV Zoo, Apache 2.0)
"""
import hashlib
import sys
import urllib.request
from pathlib import Path

BASE = "https://github.com/opencv/opencv_zoo/raw/main/models"
MODELS = {
    "face_detection_yunet_2023mar.onnx": f"{BASE}/face_detection_yunet/face_detection_yunet_2023mar.onnx",
    "face_recognition_sface_2021dec.onnx": f"{BASE}/face_recognition_sface/face_recognition_sface_2021dec.onnx",
}
MODEL_DIR = Path(__file__).parent / "models"


def main() -> None:
    MODEL_DIR.mkdir(exist_ok=True)
    for name, url in MODELS.items():
        dst = MODEL_DIR / name
        if dst.exists() and dst.stat().st_size > 0:
            print(f"있음  {name}")
            continue
        print(f"받는 중 {name}")
        tmp = dst.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.replace(dst)
        digest = hashlib.sha256(dst.read_bytes()).hexdigest()[:16]
        print(f"완료  {name} ({dst.stat().st_size / 1e6:.1f}MB, sha256 {digest}…)")


if __name__ == "__main__":
    sys.exit(main())
