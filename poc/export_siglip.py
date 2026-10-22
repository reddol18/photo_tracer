"""SigLIP 2 한국어 모델을 폰에서 돌릴 ONNX로 변환하고 PC에서 결과를 검증한다.

사용: uv run export_siglip.py [--res 512 384 256]
  - 이미지 인코더: 해상도별로 따로 내보낸다 (폰은 고정 크기 입력이 빠름). 위치 임베딩은 보간.
  - 텍스트 인코더: 검색어용. 태그 목록의 텍스트 임베딩은 미리 계산해 표로 싣는다(tags.npy).
  - 각 모델을 가중치 8비트(w8)로도 만들어, 원본(PyTorch)과의 코사인 유사도를 잰다.
    FP16·4비트 등 다른 방식 비교는 compare_quant.py.
결과물은 poc/models/siglip/ (저장소 제외).
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnxruntime.quantization.matmul_nbits_quantizer import MatMulNBitsQuantizer
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener
from transformers import AutoModel, AutoTokenizer

register_heif_opener()

MODEL_ID = "alphaedge-ai/siglip2-base-patch16-512-kor-32768"
OUT = Path(__file__).parent / "models" / "siglip"
TEXT_LEN = 64
# SigLIP 이미지 전처리: 정사각형으로 늘려 리사이즈, [-1, 1] 정규화
MEAN, STD = 0.5, 0.5

# 장소·장면 태그 (설계 문서 4번 요구사항). 앱은 이 표의 임베딩만 있으면 텍스트 인코더 없이 태깅한다.
TAGS = {
    "실내": "실내에서 찍은 사진", "실외": "야외에서 찍은 사진",
    "나무": "나무가 있는 풍경", "숲": "숲속", "잔디밭": "잔디밭", "꽃": "꽃이 핀 곳",
    "강가": "강가", "바닷가": "바닷가 해변", "산": "산", "공원": "공원", "놀이터": "놀이터",
    "거실": "집 거실", "침실": "침실", "부엌": "부엌", "식당": "식당에서 식사", "카페": "카페",
    "키즈카페": "실내 키즈카페", "차 안": "자동차 안", "수영장": "수영장", "눈": "눈이 쌓인 겨울",
    "도시": "도시의 거리", "밤": "밤에 찍은 사진", "생일": "생일 케이크와 파티",
    "동물원": "동물원", "놀이공원": "놀이공원", "물놀이": "물놀이", "캠핑": "캠핑장 텐트",
}


class Vision(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        out = self.model.vision_model(pixel_values=pixel_values, interpolate_pos_encoding=True)
        emb = out.pooler_output
        return emb / emb.norm(dim=-1, keepdim=True)


class Text(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids):
        emb = self.model.text_model(input_ids=input_ids).pooler_output
        return emb / emb.norm(dim=-1, keepdim=True)


def preprocess(path: Path, res: int) -> np.ndarray:
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB").resize((res, res), Image.BICUBIC)
    x = (np.asarray(im, dtype=np.float32) / 255.0 - MEAN) / STD
    return x.transpose(2, 0, 1)[None]


def export(module, example, path: Path, input_name: str) -> None:
    # 출력 이름이 'embedding'이면 SigLIP 내부 노드 이름과 겹쳐 ORT가 모델을 거부한다
    torch.onnx.export(module, (example,), str(path), input_names=[input_name], output_names=["normalized_embeds"],
                      opset_version=18, dynamo=True, external_data=False)


def quantize(src: Path) -> Path:
    """가중치만 8비트로 줄인다(MatMulNBits). 동적 INT8(활성값까지 양자화)은 코사인 0.75로 품질이 무너졌다
    — compare_quant.py 참고."""
    dst = src.with_name(src.stem + "_w8.onnx")
    q = MatMulNBitsQuantizer(onnx.load(str(src)), bits=8, block_size=32, is_symmetric=True, accuracy_level=4)
    q.process()
    q.model.save_model_to_file(str(dst), use_external_data_format=False)
    return dst


def session(path: Path) -> ort.InferenceSession:
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 4  # 폰의 빅코어 수와 비슷하게
    return ort.InferenceSession(str(path), opts, providers=["CPUExecutionProvider"])


def mb(path: Path) -> str:
    return f"{path.stat().st_size / 1e6:.0f}MB"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--res", type=int, nargs="+", default=[512, 384, 256])
    ap.add_argument("--photos", type=Path, default=Path(r"E:\claude-dev\test_pictures"))
    ap.add_argument("--samples", type=int, default=40)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    model = AutoModel.from_pretrained(MODEL_ID, torch_dtype=torch.float32).eval()
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    scale = float(model.logit_scale.exp())
    bias = float(model.logit_bias)

    # 텍스트 인코더 + 태그 표
    text, tag_names = Text(model).eval(), list(TAGS)
    ids = tok(list(TAGS.values()), padding="max_length", max_length=TEXT_LEN, truncation=True,
              return_tensors="pt")["input_ids"]
    with torch.no_grad():
        tag_emb = text(ids).numpy()
    np.save(OUT / "tags.npy", tag_emb.astype(np.float32))
    (OUT / "tags.json").write_text(json.dumps({"tags": tag_names, "prompts": list(TAGS.values()),
                                               "logit_scale": scale, "logit_bias": bias,
                                               "text_len": TEXT_LEN, "model": MODEL_ID},
                                              ensure_ascii=False, indent=1), encoding="utf-8")
    text_path = OUT / "text.onnx"
    if not text_path.exists():
        export(text, ids[:1], text_path, "input_ids")
    text_q = text_path.with_name("text_w8.onnx")
    if not text_q.exists():
        quantize(text_path)
    for p in (text_path, text_q):
        sess = session(p)  # 폰은 검색어를 하나씩 넣으므로 배치 1 고정으로 내보냈다
        got = np.concatenate([sess.run(None, {"input_ids": row[None].astype(np.int64)})[0] for row in ids.numpy()])
        cos = (got * tag_emb).sum(1)
        print(f"텍스트 {p.name:16s} {mb(p):>6s}  원본 대비 코사인 최소 {cos.min():.4f}")

    # 이미지 인코더: 해상도별
    photos = sorted(p for p in args.photos.rglob("*") if p.is_file())
    sample = photos[:: max(1, len(photos) // args.samples)][: args.samples]
    vision = Vision(model).eval()
    with torch.no_grad():
        ref512 = np.concatenate([vision(torch.from_numpy(preprocess(p, 512))).numpy() for p in sample])

    def top_tags(emb: np.ndarray) -> np.ndarray:
        return np.argsort(-(emb @ tag_emb.T), axis=1)[:, :3]

    ref_top = top_tags(ref512)
    print(f"\n이미지 (표본 {len(sample)}장, 기준 = PyTorch 512px)")
    print("  모델                     크기    기준 대비 코사인(평균/최소)  상위3 태그 일치  PC 4스레드 ms/장")
    for res in args.res:
        path = OUT / f"vision_{res}.onnx"
        if not path.exists():
            export(vision, torch.from_numpy(preprocess(sample[0], res)), path, "pixel_values")
        qpath = path.with_name(f"vision_{res}_w8.onnx")
        if not qpath.exists():
            quantize(path)
        for p in (path, qpath):
            sess = session(p)
            sess.run(None, {"pixel_values": preprocess(sample[0], res)})  # 예열
            embs, t0 = [], time.perf_counter()
            for ph in sample:
                embs.append(sess.run(None, {"pixel_values": preprocess(ph, res)})[0])
            ms = (time.perf_counter() - t0) / len(sample) * 1000
            emb = np.concatenate(embs)
            cos = (emb * ref512).sum(1)
            agree = np.mean([len(set(a) & set(b)) / 3 for a, b in zip(top_tags(emb), ref_top)])
            print(f"  {p.name:24s} {mb(p):>6s}   {cos.mean():.4f} / {cos.min():.4f}            {agree:6.1%}        {ms:6.0f}")


if __name__ == "__main__":
    main()
