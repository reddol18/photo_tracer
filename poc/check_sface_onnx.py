"""폰(onnxruntime)에서 SFace를 OpenCV와 같은 방식으로 돌리고 있는지 확인한다.

OpenCV FaceRecognizerSF.feature()와 onnxruntime 직접 실행(RGB/BGR 두 가지)의 임베딩을 비교해,
벤치마크 앱(Benchmark.kt embedFace)의 입력 형식 가정(112x112, RGB, 0~255, NCHW)이 맞는지 본다.
"""
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

MODEL = Path(__file__).parent / "models" / "face_recognition_sface_2021dec.onnx"
CROPS = Path(__file__).parent.parent / "eval_data" / "crops"


def main() -> None:
    rec = cv2.FaceRecognizerSF.create(str(MODEL), "")
    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    print(f"입력 이름 {inp.name}, 모양 {inp.shape}, 형식 {inp.type}")
    sims = {"RGB": [], "BGR": []}
    for path in sorted(CROPS.glob("*.jpg"))[:50]:
        bgr = cv2.imread(str(path))  # extract_faces.py가 저장한 정렬된 112x112 얼굴
        ref = rec.feature(bgr).flatten()
        ref /= np.linalg.norm(ref)
        for order, img in (("RGB", bgr[:, :, ::-1]), ("BGR", bgr)):
            x = img.astype(np.float32).transpose(2, 0, 1)[None]
            out = sess.run(None, {inp.name: x})[0].flatten()
            sims[order].append(float(out @ ref / np.linalg.norm(out)))
    for order, s in sims.items():
        print(f"{order}: OpenCV 대비 코사인 평균 {np.mean(s):.4f}, 최소 {np.min(s):.4f}")


if __name__ == "__main__":
    main()
