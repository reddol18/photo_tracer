"""SigLIP ONNX 양자화 방식 비교. export_siglip.py가 만든 FP32 ONNX를 여러 방식으로 줄여 품질·크기·속도를 잰다.

사용: uv run compare_quant.py [--res 384 512]
기준은 같은 해상도의 FP32 ONNX 출력이다. 동적 INT8(활성값까지 양자화)이 코사인 0.75로 무너져서 대안을 찾는다.
"""
import argparse
import time
from pathlib import Path

import numpy as np
import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic
from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer
from onnxruntime.transformers.float16 import convert_float_to_float16

from export_siglip import OUT, TAGS, mb, preprocess, session

PHOTOS = Path(r"E:\claude-dev\test_pictures")


def dyn_per_channel(src: Path, dst: Path) -> None:
    quantize_dynamic(str(src), str(dst), weight_type=QuantType.QInt8, per_channel=True)


def weight_only(bits: int):
    def run(src: Path, dst: Path) -> None:
        q = MatMulNBitsQuantizer(onnx.load(str(src)), bits=bits, block_size=32, is_symmetric=True,
                                 accuracy_level=4)  # 4 = 활성값 int8 계산(ARM에서 빠름)
        q.process()
        q.model.save_model_to_file(str(dst), use_external_data_format=False)
    return run


def fp16(src: Path, dst: Path) -> None:
    onnx.save(convert_float_to_float16(onnx.load(str(src)), keep_io_types=True), str(dst))


METHODS = {"dyn_pc": dyn_per_channel, "w8": weight_only(8), "w4": weight_only(4), "fp16": fp16}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--res", type=int, nargs="+", default=[384, 512])
    ap.add_argument("--samples", type=int, default=40)
    args = ap.parse_args()
    photos = sorted(p for p in PHOTOS.rglob("*") if p.is_file())
    sample = photos[:: max(1, len(photos) // args.samples)][: args.samples]
    tag_emb = np.load(OUT / "tags.npy")

    for res in args.res:
        src = OUT / f"vision_{res}.onnx"
        xs = [preprocess(p, res) for p in sample]
        ref = np.concatenate([session(src).run(None, {"pixel_values": x})[0] for x in xs])
        ref_top = np.argsort(-(ref @ tag_emb.T), axis=1)[:, :3]
        print(f"\n{res}px (기준 = 같은 해상도 FP32, 표본 {len(sample)}장)")
        print("  방식      크기    코사인 평균/최소   상위3 태그 일치   PC 4스레드 ms/장")
        for name, fn in METHODS.items():
            dst = OUT / f"vision_{res}_{name}.onnx"
            if not dst.exists():
                try:
                    fn(src, dst)
                except Exception as e:
                    print(f"  {name:8s} 변환 실패: {type(e).__name__}: {str(e)[:120]}")
                    continue
            sess = session(dst)
            sess.run(None, {"pixel_values": xs[0]})
            t0 = time.perf_counter()
            emb = np.concatenate([sess.run(None, {"pixel_values": x})[0] for x in xs])
            ms = (time.perf_counter() - t0) / len(xs) * 1000
            cos = (emb * ref).sum(1) / np.linalg.norm(emb, axis=1)
            top = np.argsort(-(emb @ tag_emb.T), axis=1)[:, :3]
            agree = np.mean([len(set(a) & set(b)) / 3 for a, b in zip(top, ref_top)])
            print(f"  {name:8s} {mb(dst):>6s}   {cos.mean():.4f} / {cos.min():.4f}      {agree:6.1%}         {ms:5.0f}")


if __name__ == "__main__":
    main()
