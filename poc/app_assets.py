"""미니 앱(app/)에 넣을 파일을 만들고, 폰에서 만든 검색어 벡터를 PC 결과와 비교한다.

사용:
  uv run app_assets.py build
    - 토크나이저: tokenizer.json → app assets 의 vocab.txt(토큰마다 UTF-8 hex 한 줄)·merges.txt("왼쪽 오른쪽 결과" id 한 줄, 줄 번호 = 우선순위).
      앱은 JSON 파서 없이 읽고, PC JVM 단위 테스트(org.json 없음)에서도 같은 코드가 돈다.
    - 모델: vision_384_w8 · text_w8 · SFace 를 app assets/models 로 복사 (저장소 제외, *.onnx).
    - 정답: 같은 검색어를 Python 토크나이저에 넣은 id. 공개 검색어(짧은 검색어·태그 문장·특수 경우)는
      app/android/app/src/test/resources 에(저장소 포함), 가족 사진 설명 문장은 eval_data/app 에(저장소 제외).
    - 폰 확인용 검색어 목록: 공개분은 assets/debug/queries.txt, 설명 문장은 eval_data/app/queries_private.txt
      (adb로 앱 폴더에 넣는다 — APK에는 넣지 않는다).
    - 흔한 검색어 방향: assets/search/common.bin (아래 common)
  uv run app_assets.py common
    - 흔한 검색어 방향만 다시 만든다.
  uv run app_assets.py fake
    - 실사 아닌 이미지(화면 캡처·AI 그림·연예인 사진) 판정 문구 벡터만 다시 만든다.
  uv run app_assets.py compare <query_vectors_*.json>
    - 폰이 쓴 토큰 id와 벡터를 PC(Python 토크나이저 + text_w8.onnx)와 비교한다.
"""
import base64
import json
import shutil
import sys
from pathlib import Path

import numpy as np
from huggingface_hub import hf_hub_download
from transformers import AutoTokenizer

from export_siglip import MODEL_ID, OUT, TAGS, TEXT_LEN, session
from short_query_eval import QUERIES

ROOT = Path(__file__).parent.parent
ANDROID = ROOT / "app" / "android" / "app" / "src"
ASSETS = ANDROID / "main" / "assets"
TEST_RES = ANDROID / "test" / "resources"
PRIVATE = ROOT / "eval_data" / "app"
MODELS = {"vision_384_w8.onnx": OUT / "vision_384_w8.onnx", "text_w8.onnx": OUT / "text_w8.onnx",
          "face_recognition_sface_2021dec.onnx": OUT.parent / "face_recognition_sface_2021dec.onnx"}

# 토크나이저가 틀리기 쉬운 경우: 앞뒤·연속 공백, 영어 대소문자, 숫자, 이모지(바이트 대체), 자모, 64토큰 넘는 문장
EDGE = [" 앞 공백", "뒤 공백 ", "두  칸 띄움", "Hello World", "hello world", "2024년 5월 생일", "아이 3명",
        "😀 웃는 얼굴", "🎂🎉", "ㅋㅋㅋ", "ㅎㅎ 귀여워", "e스포츠", "제주도.", "바다, 모래, 하늘!", "\"따옴표\"",
        "줄\n바꿈", "탭\t문자", "아" * 80, "가나다라마바사 " * 12, "Ünïcödé çafé", "日本 旅行", "", " "]


def public_queries() -> list[str]:
    qs = list(QUERIES) + [f"{q} 사진" for q in QUERIES] + list(TAGS.values()) + EDGE
    return list(dict.fromkeys(qs))


def private_queries() -> list[str]:
    truth = ROOT / "eval_data" / "describe_truth.json"
    if not truth.exists():
        return []
    return list(dict.fromkeys(e["text"] for e in json.loads(truth.read_text(encoding="utf-8"))["events"]))


def encode(tok, texts: list[str]) -> np.ndarray:
    return tok(texts, padding="max_length", max_length=TEXT_LEN, truncation=True, return_tensors="np")["input_ids"]


def write_golden(tok, texts: list[str], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ids = encode(tok, texts)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for t, row in zip(texts, ids):
            f.write(f"{t.encode('utf-8').hex()}\t{' '.join(map(str, row))}\n")
    print(f"정답 {len(texts)}개 → {path}")


def write_queries(texts: list[str], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(t.encode("utf-8").hex() + "\n" for t in texts), encoding="ascii", newline="\n")
    print(f"폰 확인용 검색어 {len(texts)}개 → {path}")


def tokenizer_json() -> Path:
    """내려받아 둔 tokenizer.json 원본 (HF 캐시)."""
    return Path(hf_hub_download(MODEL_ID, "tokenizer.json", local_files_only=True))


def build() -> None:
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    spec = json.loads(tokenizer_json().read_text(encoding="utf-8"))
    m = spec["model"]
    assert m["type"] == "BPE" and m["byte_fallback"] and spec["normalizer"]["content"] == "▁", "토크나이저 형식이 바뀌었다"
    vocab = sorted(m["vocab"].items(), key=lambda kv: kv[1])
    assert [i for _, i in vocab] == list(range(len(vocab)))
    for a in spec["added_tokens"]:
        assert vocab[a["id"]][0] == a["content"]
    out = ASSETS / "tokenizer"
    out.mkdir(parents=True, exist_ok=True)
    (out / "vocab.txt").write_text("".join(s.encode("utf-8").hex() + "\n" for s, _ in vocab), encoding="ascii", newline="\n")
    index = dict(vocab)
    lines = []
    for a, b in (mg.split(" ", 1) if isinstance(mg, str) else mg for mg in m["merges"]):
        lines.append(f"{index[a]} {index[b]} {index[a + b]}\n")
    (out / "merges.txt").write_text("".join(lines), encoding="ascii", newline="\n")
    print(f"토크나이저: 어휘 {len(vocab)}개 · 병합 규칙 {len(lines)}개 → {out}")

    (ASSETS / "models").mkdir(parents=True, exist_ok=True)
    for name, src in MODELS.items():
        dst = ASSETS / "models" / name
        if not dst.exists() or dst.stat().st_size != src.stat().st_size:
            shutil.copyfile(src, dst)
        print(f"모델 {name} {src.stat().st_size / 1e6:.0f}MB → {dst}")

    pub = public_queries()
    write_golden(tok, pub, TEST_RES / "tokenizer_golden.tsv")
    write_queries(pub, ASSETS / "debug" / "queries.txt")
    priv = private_queries()
    if priv:
        write_golden(tok, priv, PRIVATE / "tokenizer_golden_private.tsv")
        write_queries(priv, PRIVATE / "queries_private.txt")


def write_common() -> None:
    """흔한 검색어 방향(search_rank_eval.GENERIC 평균, 768 float32 LE) → assets/search/common.bin.
    앱은 검색어 벡터에서 이 방향을 빼고 순위를 매긴다('아이와 ○○' 상위10 정밀도 28→42%)."""
    from search_rank_eval import GENERIC
    from short_query_eval import text_vectors
    v = text_vectors(GENERIC).mean(0)
    v = (v / np.linalg.norm(v)).astype("<f4")
    out = ASSETS / "search" / "common.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(v.tobytes())
    print(f"흔한 검색어 방향 ({len(GENERIC)}개 평균) → {out}")


def write_fake() -> None:
    """실사 아닌 이미지 판정 문구 벡터 → assets/search/fake.bin (float32 LE, 768씩: 실사 6 · 캡처 3 · 인물 2 순서).
    앱(Fake.kt)은 사진 벡터와 (캡처 문구 최대 - 실사 문구 최대), (인물 문구 최대 - 실사 문구 최대)를 본다.
    문구·문턱은 artificial_rule.py 로 고른 것: 썸네일 9354장에서 캡처 점수 상위는 모두 화면 캡처,
    카메라 정보 없는 사진의 인물 점수 상위는 AI 아바타·연예인 사진."""
    from artificial_eval import REAL
    from artificial_rule import PROMPTS
    from short_query_eval import text_vectors
    T = np.concatenate([text_vectors(REAL), text_vectors(PROMPTS["capture"]), text_vectors(PROMPTS["person"])]).astype("<f4")
    assert T.shape == (11, 768), T.shape
    out = ASSETS / "search" / "fake.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(T.tobytes())
    print(f"실사 아닌 이미지 판정 문구 {len(T)}개 → {out}")


def compare(path: Path) -> None:
    r = json.loads(path.read_text(encoding="utf-8"))
    texts = [bytes.fromhex(h).decode("utf-8") for h in r["queries"]]
    phone_ids = np.array(r["ids"], dtype=np.int64)
    V = np.frombuffer(base64.b64decode(r["vectors"]), dtype="<f4").reshape(len(texts), r["dim"])
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    pc_ids = encode(tok, texts)
    bad = [t for t, a, b in zip(texts, phone_ids, pc_ids) if not np.array_equal(a, b)]
    s = session(OUT / "text_w8.onnx")
    P = np.concatenate([s.run(None, {"input_ids": row[None]})[0] for row in pc_ids])
    cos = (V * P).sum(1)
    print(f"검색어 {len(texts)}개 · 토큰이 다른 검색어 {len(bad)}개 · 벡터 코사인 최소 {cos.min():.5f} · 평균 {cos.mean():.5f}"
          f" · 0.999 미만 {int((cos < 0.999).sum())}개")
    for t in bad[:10]:
        print(f"  토큰 다름: {t[:30]!r}")
    print(f"폰: 검색어 하나 {r['median_ms']:.0f}ms(중앙값) · 모델 올리기 {r['load_ms']:.0f}ms"
          f" · 메모리 {r['pss_mb_before']:.0f}→{r['pss_mb_after']:.0f}MB")


if __name__ == "__main__":
    if sys.argv[1:2] == ["build"]:
        build()
        write_common()
        write_fake()
    elif sys.argv[1:2] == ["common"]:
        write_common()
    elif sys.argv[1:2] == ["fake"]:
        write_fake()
    elif sys.argv[1:2] == ["compare"]:
        compare(Path(sys.argv[2]))
    else:
        print(__doc__)
