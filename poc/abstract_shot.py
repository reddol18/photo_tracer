"""폰 화면 캡처 비식별: 사진은 만화풍으로, 얼굴은 그림 얼굴로, 이름은 '인물A…'로, 상태바는 깨끗하게.

확인용으로 찍은 앱 캡처를 README·홍보용으로 남길 때 쓴다. 모든 처리는 이 PC 안에서만 한다
(OCR·얼굴 검출 모두 로컬 모델, 캡처를 어떤 서비스로도 보내지 않는다).

실행 (poc 폴더에서):
    uv sync --group shots                       # 처음 한 번: easyocr(+torchvision) 설치
    uv run --group shots abstract_shot.py ../eval_data/ui/raw_*.png --out ../eval_data/ui_abs
    uv run --group shots abstract_shot.py a.png --out out --debug   # 찾은 영역을 변환본 위에 표시한 그림도 저장

- 얼굴 검출 모델 YuNet: models/face_detection_yunet_2023mar.onnx (없으면 `uv run download_models.py`)
- OCR 모델(easyocr 한국어·영어 검출/인식): 처음 실행 때 ~/.EasyOCR/model 에 한 번 받는다(공개 가중치 다운로드만).

단계
1. 사진 영역: 앱 UI는 몇 가지 평면 색으로 칠해져 있으므로, 화면에서 넓게 쓰인 색(우세 색)이 아닌 화소를
   모아 열기(글자 테두리 제거) → 닫기 → 구멍 메우기 → 연결 요소. 작거나 성기거나 무늬가 없는 것은 버린다.
2. 만화화: 영역을 긴 변 --detail 화소로 줄여 bilateral 여러 번 + k-means 색 10개, 원래 크기로 키워
   팔레트에 다시 맞추고 색 경계에 외곽선. 줄였다 키우므로 얼굴·글자 같은 세부는 남지 않는다.
3. 얼굴: 원본 영역에서 YuNet(낮은 문턱, 두 배율)으로 찾아 만화 위에 그림 얼굴을 덮는다.
   긴 변 < 160px 의 정사각형에 가까운 영역(아바타·작은 썸네일)은 통째로 그림 아바타로 바꾼다.
4. 이름: 사진 영역 밖 글자를 OCR. app/lib/**/*.dart 문자열 리터럴의 낱말 + 숫자·날짜 패턴이 아닌
   두 글자 이상 한글 낱말은 지우고 같은 자리에 '인물A/인물B…'(같은 낱말은 같은 표시)로 다시 쓴다.
   화면 끝(좌우 8px)에 잘린 낱말·자모가 섞인 낱말·아바타 바로 밑 이름 자리는 길이와 관계없이 바꾼다.
   조사는 떼어 같은 이름에 맞추고 원래 조사를 그대로 붙인다. 다시 쓴 글자는 이웃 글자 전까지의 폭에 맞춘다.
   화이트리스트에는 app/android/app/src/main/kotlin/**/*.kt 의 한글도 넣는다.
5. 상태바: 위 68px 을 평면 바 + '9:41' 로 바꾼다(알림 아이콘에 앱·메신저 정보가 보일 수 있다).

로그에는 읽은 글자 내용을 찍지 않는다(개수·크기만).
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

POC = Path(__file__).resolve().parent
REPO = POC.parent
YUNET = POC / "models" / "face_detection_yunet_2023mar.onnx"
FONTS = [Path(r"C:\Windows\Fonts\NotoSansKR-VF.ttf"), Path(r"C:\Windows\Fonts\malgun.ttf")]
STATUS_H = 68          # 상태바 높이(px, 밀도 2.0 기준 34dp)
SMALL_SIDE = 160       # 이보다 작은 정사각형 영역은 통째로 그림 아바타
EDGE = 8               # 화면 좌우 끝에서 이만큼 안에 닿은 글자는 잘린 것으로 본다
PARTICLES = sorted(["은", "는", "이", "가", "을", "를", "의", "에", "와", "과", "도", "로", "으로", "에서",
                    "에게", "만", "께", "님", "이랑", "랑", "하고", "까지", "부터", "처럼", "보다", "야", "아"],
                   key=len, reverse=True)
JAMO = re.compile(r"[ㄱ-ㅣ]")          # 낱자 자모: 잘린 글자를 OCR이 이렇게 읽는다
HANGUL_TOKEN = re.compile(r"[가-힣ㄱ-ㅣ]+")
AVATAR_COLORS = [(186, 168, 230), (160, 200, 236), (170, 222, 190), (246, 200, 160), (240, 170, 190), (210, 210, 160)]
SKIN = (196, 214, 250)  # BGR 살구색
FACE_LINE = (60, 60, 90)


# ---------------------------------------------------------------- 공통

def imread(p: Path) -> np.ndarray:
    img = cv2.imdecode(np.fromfile(str(p), np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit(f"읽을 수 없음: {p}")
    return img


def imwrite(p: Path, img: np.ndarray) -> None:
    ok, buf = cv2.imencode(".png", img)
    if not ok:
        raise SystemExit(f"저장 실패: {p}")
    buf.tofile(str(p))


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for f in FONTS:
        if f.exists():
            font = ImageFont.truetype(str(f), size)
            try:
                font.set_variation_by_name("Medium")
            except Exception:
                pass
            return font
    return ImageFont.load_default()


# ---------------------------------------------------------------- 앱 UI 낱말(화이트리스트)

class UiWords:
    """앱 문자열 리터럴의 한글 낱말과, 리터럴 안에서 각 낱말의 앞뒤 낱말(OCR 오독을 문맥으로 구제할 때)."""

    def __init__(self):
        self.words = {"인물"}
        self.prev: dict[str, set] = {}
        self.next: dict[str, set] = {}
        self.phrases: set[tuple[str, ...]] = set()  # 따옴표 한 덩어리의 한글 낱말 열(칩 하나짜리 문구 맞추기)
        # 문자열 안에 따옴표가 겹치는 보간('${a ? '오후' : '오전'}')이 많아 리터럴을 정확히 자르기보다,
        # 주석을 걷어낸 코드에서 한글을 모두 모은다(Dart·Kotlin 코드에서 한글은 문자열에만 나온다).
        files = list((REPO / "app" / "lib").rglob("*.dart"))
        files += list((REPO / "app" / "android" / "app" / "src" / "main" / "kotlin").rglob("*.kt"))
        for f in files:
            src = f.read_text(encoding="utf-8")
            src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
            src = re.sub(r"(?m)(^|\s)//.*$", r"\1", src)
            for line in src.splitlines():
                # 따옴표·보간으로 끊긴 곳은 이웃으로 치지 않는다
                for part in re.split(r"['\"]|\$\{|\}|\$\w+", line):
                    seq = re.findall(r"[가-힣]+", part)
                    if seq:
                        self.phrases.add(tuple(seq))
                    self.words.update(seq)
                    for a, b in zip(seq, seq[1:]):
                        self.next.setdefault(a, set()).add(b)
                        self.prev.setdefault(b, set()).add(a)

    def __len__(self):
        return len(self.words)

    def exact(self, tok: str, short_ok: bool = True) -> bool:
        """목록에 있거나 목록 낱말+조사. short_ok 면 한 글자 낱말은 UI로 친다(장·살 등).
        낱자 자모가 섞인 낱말(잘린 글자)은 UI가 아니다."""
        if JAMO.search(tok):
            return False
        if (short_ok and len(tok) < 2) or tok in self.words:
            return True
        return any(tok.endswith(p) and len(tok) > len(p) and tok[: -len(p)] in self.words for p in PARTICLES)

    def phrase(self, toks: list[str]) -> bool:
        """줄 전체가 따옴표 한 덩어리 문구와 같거나 한 글자만 다름(칩 하나짜리 예시 문구의 오독)."""
        if not toks or any(JAMO.search(t) for t in toks):
            return False
        for p in self.phrases:
            if len(p) == len(toks) and all(len(a) == len(b) for a, b in zip(p, toks)) and sum(len(a) for a in p) >= 2:
                if sum(x != y for a, b in zip(p, toks) for x, y in zip(a, b)) <= 1:
                    return True
        return False

    def near(self, tok: str) -> list[str]:
        """한 글자만 다른 UI 낱말(OCR 오독 후보)."""
        out = []
        for w in self.words:
            if len(w) == len(tok) and len(w) >= 2 and sum(a != b for a, b in zip(w, tok)) <= 1:
                out.append(w)
            elif abs(len(w) - len(tok)) == 1 and min(len(w), len(tok)) >= 2:
                s, l = (w, tok) if len(w) < len(tok) else (tok, w)
                if any(l[:i] + l[i + 1:] == s for i in range(len(l))):
                    out.append(w)
        return out

    def classify(self, toks: list[str], strict: list[bool] | None = None) -> list[bool]:
        """한 줄의 한글 낱말들이 UI 문구인지. 정확히 맞거나(조사 허용), 한 글자 오독이어도
        긴 낱말(4자+)이거나 바로 앞뒤 낱말이 리터럴 속 이웃과 맞으면 UI로 본다.
        strict[i] 인 낱말(화면 끝에 잘림·아바타 밑 이름 자리)은 길이와 관계없이 목록과 정확히 맞아야 한다."""
        strict = strict or [False] * len(toks)
        if not any(strict) and self.phrase(toks):
            return [True] * len(toks)
        ok = [self.exact(t, short_ok=not s) for t, s in zip(toks, strict)]
        for _ in range(2):
            for i, t in enumerate(toks):
                if ok[i] or strict[i] or JAMO.search(t):
                    continue
                for w in self.near(t):
                    if len(t) >= 4:
                        ok[i] = True
                    elif i > 0 and ok[i - 1] and self._match(toks[i - 1], self.prev.get(w, ())):
                        ok[i] = True
                    elif i + 1 < len(toks) and ok[i + 1] and self._match(toks[i + 1], self.next.get(w, ())):
                        ok[i] = True
                    if ok[i]:
                        break
        return ok

    def _match(self, tok: str, cands) -> bool:
        return any(tok == c or c in self.near(tok) for c in cands)


# ---------------------------------------------------------------- 1. 사진 영역

def find_photo_regions(img: np.ndarray) -> list[dict]:
    h, w = img.shape[:2]
    q = (img // 4).astype(np.int32)
    key = q[..., 0] * 4096 + q[..., 1] * 64 + q[..., 2]
    body = key[STATUS_H:]
    vals, counts = np.unique(body, return_counts=True)
    dom = vals[counts > 0.002 * body.size]
    cand = (~np.isin(key, dom)).astype(np.uint8) * 255
    cand[:STATUS_H] = 0
    cand = cv2.morphologyEx(cand, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    cand = cv2.morphologyEx(cand, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
    # 구멍 메우기: 1px 테두리를 둘러 바깥 전체에서 flood fill 한 뒤 반전
    # (화면 폭을 꽉 채운 사진이 위아래 배경을 갈라도 둘 다 '바깥'으로 잡히게)
    ff = cv2.copyMakeBorder(cand, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    cv2.floodFill(ff, np.zeros((h + 4, w + 4), np.uint8), (0, 0), 255)
    filled = cand | cv2.bitwise_not(ff[1:-1, 1:-1])
    filled_pre = filled.copy()
    # 굵은 글자·가는 다리(사진과 글자가 붙은 곳)를 끊는다. 사진·아바타(52px+)는 남는다
    filled = cv2.morphologyEx(filled, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (11, 11)))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(filled, 8)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    regions = []
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if bw < 36 or bh < 36 or area < 36 * 36 * 0.7:
            continue
        fill = area / (bw * bh)
        if fill < 0.55:
            continue
        comp = lab[y:y + bh, x:x + bw] == i
        patch = img[y:y + bh, x:x + bw][comp]
        colors = len(np.unique((patch // 8).astype(np.int32) @ np.array([1024, 32, 1])))
        if gray[y:y + bh, x:x + bw][comp].std() < 6 or colors < 48:
            continue  # 단색 아이콘·버튼
        # 둥근 모양(원·타원)일 때만 그 모양대로, 나머지는 놓치는 곳이 없게 상자 전체를 바꾼다
        # (사진 속 밝은 면이 UI 색과 겹쳐 연결 요소에서 빠져도 상자 전체가 처리되도록)
        ell = np.zeros((bh, bw), np.uint8)
        cv2.ellipse(ell, (bw // 2, bh // 2), (bw // 2, bh // 2), 0, 0, 360, 1, -1)
        iou = (comp & (ell > 0)).sum() / max(1, (comp | (ell > 0)).sum())
        shape = "round" if iou >= 0.9 and fill < 0.86 else "rect"
        if shape == "rect":
            m = np.full((bh, bw), 255, np.uint8)
        else:
            m = cv2.dilate(((ell > 0) | comp).astype(np.uint8) * 255, np.ones((5, 5), np.uint8))
        compm = cv2.dilate(comp.astype(np.uint8) * 255, np.ones((5, 5), np.uint8))
        regions.append({"box": (int(x), int(y), int(bw), int(bh)), "mask": m, "comp": compm, "shape": shape,
                        "fill": float(fill)})

    # 화면 좌우 끝에 걸친 가는 조각(잘린 아바타·썸네일): 위 11px 열기에서 사라지므로 열기 전 그림에서 따로 찾는다
    n2, lab2, stats2, _ = cv2.connectedComponentsWithStats(filled_pre, 8)
    for i in range(1, n2):
        x, y, bw, bh, area = stats2[i]
        if not (x <= 1 or x + bw >= w - 1) or bh < 30 or bw < 2 or bw >= 36 or area < 0.5 * bw * bh:
            continue
        if any(x >= r["box"][0] - 2 and x + bw <= r["box"][0] + r["box"][2] + 2 and
               y >= r["box"][1] - 2 and y + bh <= r["box"][1] + r["box"][3] + 2 for r in regions):
            continue
        comp = (lab2[y:y + bh, x:x + bw] == i).astype(np.uint8) * 255
        if gray[y:y + bh, x:x + bw][comp > 0].std() < 6:
            continue  # 단색 막대(스크롤 표시 등)
        compm = cv2.dilate(comp, np.ones((3, 3), np.uint8))
        regions.append({"box": (int(x), int(y), int(bw), int(bh)), "mask": compm, "comp": compm, "shape": "rect",
                        "fill": float(area / (bw * bh))})

    # 격자 맞추기: 같은 줄(세로로 많이 겹치고 높이가 비슷한) 사각 썸네일은 위아래 끝을, 같은 칸 열은
    # 좌우 끝을 맞춘다. 썸네일 아래쪽이 흰 면(캡처 속 캡처 등)이면 그 부분이 빠져 실사로 남기 때문
    rects = [r for r in regions if r["shape"] == "rect" and min(r["box"][2], r["box"][3]) >= 100]
    for axis in (1, 0):  # 1: 줄(y 맞춤), 0: 열(x 맞춤)
        o = 1 - axis
        for r1 in rects:
            for r2 in rects:
                if r1 is r2:
                    continue
                a0, a1 = r1["box"][axis], r1["box"][axis] + r1["box"][axis + 2]
                b0, b1 = r2["box"][axis], r2["box"][axis] + r2["box"][axis + 2]
                p0, p1 = r1["box"][o], r1["box"][o] + r1["box"][o + 2]
                q0, q1 = r2["box"][o], r2["box"][o] + r2["box"][o + 2]
                overlap = min(a1, b1) - max(a0, b0)
                if overlap > 0.5 * min(a1 - a0, b1 - b0) and abs((a1 - a0) - (b1 - b0)) < 0.25 * max(a1 - a0, b1 - b0) \
                        and (p1 <= q0 or q1 <= p0):  # 옆 칸(겹치지 않음)
                    n0, n1 = min(a0, b0), max(a1, b1)
                    box = list(r1["box"])
                    box[axis], box[axis + 2] = n0, n1 - n0
                    r1["box"] = tuple(int(v) for v in box)
    for r in rects:
        _, _, bw, bh = r["box"]
        r["mask"] = np.full((bh, bw), 255, np.uint8)
        r["comp"] = r["mask"]

    def inside(a, b):  # a 상자가 b 상자 안
        return a[0] >= b[0] and a[1] >= b[1] and a[0] + a[2] <= b[0] + b[2] and a[1] + a[3] <= b[1] + b[3]
    # 큰 사진 안쪽 조각(밝은 면이 열기로 떨어져 나온 것)은 큰 사진 처리에 맡긴다
    return [r for r in regions if not any(o is not r and inside(r["box"], o["box"]) for o in regions)]


# ---------------------------------------------------------------- 2. 만화화

def cartoonize(patch: np.ndarray, detail: int, k: int = 10) -> np.ndarray:
    h, w = patch.shape[:2]
    s = min(1.0, detail / max(h, w))
    sw, sh = max(8, round(w * s)), max(8, round(h * s))
    small = cv2.resize(patch, (sw, sh), interpolation=cv2.INTER_AREA)
    for _ in range(4):
        small = cv2.bilateralFilter(small, 7, 45, 7)
    data = small.reshape(-1, 3).astype(np.float32)
    k = min(k, len(np.unique(data, axis=0)))
    _, _, centers = cv2.kmeans(data, k, None, (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0),
                               3, cv2.KMEANS_PP_CENTERS)
    # 작은 그림에서 색 번호를 정하고 최빈값 필터로 자잘한 점(무늬·글자 조각)을 지운다
    d0 = ((data[:, None, :] - centers[None, :, :]) ** 2).sum(-1)
    lab_s = d0.argmin(1).reshape(sh, sw)
    for _ in range(2):
        votes = np.stack([cv2.boxFilter((lab_s == c).astype(np.float32), -1, (3, 3)) for c in range(k)], -1)
        lab_s = votes.argmax(-1)
    small = centers.astype(np.uint8)[lab_s]
    up = cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR).reshape(-1, 3).astype(np.float32)
    d = ((up[:, None, :] - centers[None, :, :]) ** 2).sum(-1)
    labels = d.argmin(1).reshape(h, w).astype(np.uint8)
    labels = cv2.medianBlur(labels, 5)
    out = centers.astype(np.uint8)[labels]
    edge = np.zeros((h, w), bool)
    edge[1:, :] |= labels[1:, :] != labels[:-1, :]
    edge[:, 1:] |= labels[:, 1:] != labels[:, :-1]
    if max(h, w) >= 200:
        edge = cv2.dilate(edge.astype(np.uint8), np.ones((2, 2), np.uint8)).astype(bool)
    out[edge] = (out[edge] * 0.35).astype(np.uint8)
    return out


# ---------------------------------------------------------------- 3. 얼굴

class Faces:
    def __init__(self, sure: float, low: float):
        if not YUNET.exists():
            raise SystemExit(f"YuNet 모델 없음: {YUNET} (poc 에서 `uv run download_models.py`)")
        self.sure, self.low = sure, low
        self.det = cv2.FaceDetectorYN.create(str(YUNET), "", (320, 320), low, 0.3, 5000)

    def detect(self, patch: np.ndarray) -> list[tuple[float, float, float, float]]:
        """놓치지 않는 쪽: 여러 배율 + 가장자리에 잘린 얼굴을 위해 둘레를 늘려 붙인 그림에서도 찾는다."""
        h, w = patch.shape[:2]
        pad = int(0.2 * max(h, w))
        padded = cv2.copyMakeBorder(patch, pad, pad, pad, pad, cv2.BORDER_REPLICATE)
        out = []
        for src, off in ((patch, 0), (padded, pad)):
            sh, sw = src.shape[:2]
            for target in (320, 480, 640, 800, 960, 1280, 1600):
                s = min(4.0, target / max(sh, sw))
                img = cv2.resize(src, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC if s > 1 else cv2.INTER_AREA)
                self.det.setInputSize((img.shape[1], img.shape[0]))
                _, dets = self.det.detect(img)
                if dets is None:
                    continue
                for d in dets:
                    x, y, fw, fh = (float(v) / s for v in d[:4])
                    x, y = x - off, y - off
                    # 패치 밖으로 대부분 나간 것(늘린 둘레에서 생긴 허상)은 버린다
                    ix = max(0.0, min(x + fw, w) - max(x, 0.0))
                    iy = max(0.0, min(y + fh, h) - max(y, 0.0))
                    if ix * iy >= 0.3 * fw * fh:
                        out.append((x, y, fw, fh, float(d[-1])))
        # 한 배율에서 확실하거나(score >= self.sure), 애매해도 여러 배율에서 거듭 나오면 얼굴로 본다
        # 애매한 작은 상자(< 28px)는 버린다: 무늬에서 허상이 많이 나오고, 그만한 얼굴은 만화화로 이미 2~3px 이 된다
        return [(x, y, fw, fh) for x, y, fw, fh, n, best in merge_boxes(out)
                if best >= self.sure or (n >= 2 and best >= self.low and fw >= 28)]


def merge_boxes(boxes: list, thr: float = 0.25) -> list:
    """여러 배율에서 겹쳐 나온 얼굴 상자를 하나로. (x, y, w, h, 나온 횟수, 최고 점수)."""
    groups: list[list[float]] = []
    for x, y, w, h, sc in sorted(boxes, key=lambda b: -b[4]):
        for g in groups:
            ix = max(0.0, min(x + w, g[2]) - max(x, g[0]))
            iy = max(0.0, min(y + h, g[3]) - max(y, g[1]))
            if ix * iy >= thr * min(w * h, (g[2] - g[0]) * (g[3] - g[1])):
                # 상자는 점수 높은 것 기준으로 두고 조금씩만 넓힌다(여러 배율의 합집합이 너무 커지지 않게)
                g[0], g[1] = min(g[0], (g[0] * 3 + x) / 4), min(g[1], (g[1] * 3 + y) / 4)
                g[2], g[3] = max(g[2], (g[2] * 3 + x + w) / 4), max(g[3], (g[3] * 3 + y + h) / 4)
                g[4] += 1
                g[5] = max(g[5], sc)
                break
        else:
            groups.append([x, y, x + w, y + h, 1, sc])
    return [(a, b, c - a, d - b, n, s) for a, b, c, d, n, s in groups]


def draw_face(canvas: np.ndarray, x: float, y: float, fw: float, fh: float, hair) -> None:
    cx, cy = int(x + fw / 2), int(y + fh / 2)
    ax, ay = max(3, int(fw * 0.62)), max(4, int(fh * 0.72))
    lw = max(1, int(fw / 40))
    cv2.ellipse(canvas, (cx, cy - int(fh * 0.12)), (int(ax * 1.08), int(ay * 1.0)), 0, 0, 360, hair, -1, cv2.LINE_AA)
    cv2.ellipse(canvas, (cx, cy + int(fh * 0.06)), (int(ax * 0.88), int(ay * 0.86)), 0, 0, 360, SKIN, -1, cv2.LINE_AA)
    cv2.ellipse(canvas, (cx, cy + int(fh * 0.06)), (int(ax * 0.88), int(ay * 0.86)), 0, 0, 360, FACE_LINE, lw, cv2.LINE_AA)
    er = max(1, int(fw * 0.06))
    for dx in (-0.2, 0.2):
        cv2.circle(canvas, (int(cx + dx * fw), int(cy - 0.02 * fh)), er, FACE_LINE, -1, cv2.LINE_AA)
    cv2.ellipse(canvas, (cx, int(cy + 0.2 * fh)), (max(2, int(fw * 0.18)), max(1, int(fh * 0.1))), 0, 15, 165,
                FACE_LINE, max(1, lw), cv2.LINE_AA)


def avatar(bw: int, bh: int, idx: int) -> np.ndarray:
    rgb = AVATAR_COLORS[idx % len(AVATAR_COLORS)]
    a = np.zeros((bh, bw, 3), np.uint8)
    a[:] = rgb[::-1]
    hair = (70, 80, 110)
    fw, fh = bw * 0.46, bh * 0.5
    draw_face(a, (bw - fw) / 2, bh * 0.28, fw, fh, hair)
    # 어깨
    cv2.ellipse(a, (bw // 2, int(bh * 1.05)), (int(bw * 0.36), int(bh * 0.22)), 0, 180, 360,
                tuple(int(c * 0.75) for c in rgb[::-1]), -1, cv2.LINE_AA)
    return a


# ---------------------------------------------------------------- 4. 이름

class Ocr:
    def __init__(self):
        import easyocr  # 무거운 의존성이라 여기서 부른다
        self.reader = easyocr.Reader(["ko", "en"], gpu=False, verbose=False)

    def read(self, img: np.ndarray) -> list[tuple[tuple[int, int, int, int], str, float]]:
        res = self.reader.readtext(cv2.cvtColor(img, cv2.COLOR_BGR2RGB), mag_ratio=1.5, text_threshold=0.6,
                                   low_text=0.3, width_ths=0.3)
        out = []
        for pts, text, conf in res:
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            out.append(((int(min(xs)), int(min(ys)), int(max(xs)), int(max(ys))), text, float(conf)))
        return out


def char_weight(c: str) -> float:
    if "가" <= c <= "힣":
        return 1.0
    if c.isspace():
        return 0.3
    if c.isalnum():
        return 0.58
    return 0.35


def token_spans(text: str, box) -> list[tuple[str, int, int]]:
    """줄 상자 안 한글 낱말마다 x 범위를 글자 폭 비율로 어림한다."""
    x0, _, x1, _ = box
    weights = [char_weight(c) for c in text]
    total = sum(weights) or 1.0
    cum = np.concatenate([[0.0], np.cumsum(weights)]) / total
    spans = []
    for m in HANGUL_TOKEN.finditer(text):
        # 바로 붙은 로마자는 같은 낱말로 지운다(잘린 한글 조각을 OCR이 'L'·'O' 같은 로마자로 읽는다)
        end = m.end()
        while end < len(text) and text[end].isascii() and text[end].isalpha():
            end += 1
        a = x0 + cum[m.start()] * (x1 - x0)
        b = x0 + cum[end] * (x1 - x0)
        # 앞뒤가 빈칸·줄 끝일 때만 지우는 범위를 잉크 따라 넓힐 수 있다(붙은 괄호 등을 먹지 않게)
        open_l = m.start() == 0 or text[m.start() - 1].isspace()
        open_r = end == len(text) or text[end].isspace()
        # 줄 끝·처음 낱말은 줄 상자 끝까지(잘린 글자 조각이 어림 밖에 남지 않게)
        if m.start() == 0:
            a = x0
        if end == len(text):
            b = x1
        nxt = text[end] if end < len(text) else ""
        spans.append((m.group(), int(a), int(np.ceil(b)), open_l, open_r, nxt))
    return spans


def ring_color(img: np.ndarray, x0, y0, x1, y1, pad=3) -> np.ndarray:
    h, w = img.shape[:2]
    X0, Y0, X1, Y1 = max(0, x0 - pad), max(0, y0 - pad), min(w, x1 + pad), min(h, y1 + pad)
    region = img[Y0:Y1, X0:X1].reshape(-1, 3)
    inner = np.zeros((Y1 - Y0, X1 - X0), bool)
    inner[y0 - Y0:y1 - Y0, x0 - X0:x1 - X0] = True
    ring = region[~inner.reshape(-1)]
    return np.median(ring if len(ring) else region, axis=0)


def name_key(tok: str, names: dict) -> tuple[str, str]:
    """낱말을 (이름 열쇠, 뒤에 붙은 조사)로. 이미 본 이름+조사면 그 이름에 맞추고,
    처음 보는 낱말은 조사를 떼어(남는 것이 2자 이상일 때) 열쇠로 삼는다."""
    if tok in names:
        return tok, ""
    for p in PARTICLES:
        if tok.endswith(p) and tok[: -len(p)] in names:
            return tok[: -len(p)], p
    for p in PARTICLES:
        if tok.endswith(p) and len(tok) - len(p) >= 2:
            return tok[: -len(p)], p
    return tok, ""


def free_span(img: np.ndarray, a: int, b: int, y0: int, y1: int, bg, limit: int = 160) -> tuple[int, int]:
    """[a,b] 낱말 상자 좌우로 글자·그림이 없는 빈 곳까지 넓힌 범위(다시 쓴 글자가 이웃과 겹치지 않게)."""
    w = img.shape[1]
    band = img[y0:y1].astype(np.int32)
    ink = (np.abs(band - np.asarray(bg, np.int32)).sum(2) > 60).any(0)
    L = a
    while L > 0 and a - L < limit and not ink[L - 1]:
        L -= 1
    R = b
    while R < w and R - b < limit and not ink[R]:
        R += 1
    return (L + 4 if L < a else a), (R - 4 if R > b else b)


def label_name(i: int) -> str:
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return "인물" + s


# ---------------------------------------------------------------- 5. 상태바

def clean_status_bar(img: np.ndarray) -> None:
    w = img.shape[1]
    row = img[STATUS_H:STATUS_H + 4].reshape(-1, 3)
    bg = np.median(row, axis=0) if row.std(axis=0).max() < 12 else np.array([240, 240, 240])
    img[:STATUS_H] = bg.astype(np.uint8)
    dark = bg.mean() > 128
    fg = (40, 40, 40) if dark else (235, 235, 235)
    pil = Image.fromarray(cv2.cvtColor(img[:STATUS_H], cv2.COLOR_BGR2RGB))
    d = ImageDraw.Draw(pil)
    font = load_font(26)
    d.text((34, STATUS_H // 2), "9:41", font=font, fill=fg, anchor="lm")
    # 와이파이 막대 + 배터리
    bx = w - 34 - 44
    for i, hh in enumerate((8, 13, 18)):
        d.rectangle((bx - 40 + i * 9, STATUS_H // 2 + 9 - hh, bx - 34 + i * 9, STATUS_H // 2 + 9), fill=fg)
    d.rounded_rectangle((bx, STATUS_H // 2 - 10, bx + 40, STATUS_H // 2 + 10), 4, outline=fg, width=2)
    d.rectangle((bx + 4, STATUS_H // 2 - 6, bx + 30, STATUS_H // 2 + 6), fill=fg)
    d.rectangle((bx + 41, STATUS_H // 2 - 4, bx + 44, STATUS_H // 2 + 4), fill=fg)
    img[:STATUS_H] = cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)


# ---------------------------------------------------------------- 전체

def process(path: Path, out_dir: Path, words: UiWords, ocr: Ocr, faces: Faces, args) -> dict:
    t0 = time.perf_counter()
    img = imread(path)
    h, w = img.shape[:2]
    out = img.copy()
    regions = find_photo_regions(img)
    photo_mask = np.zeros((h, w), np.uint8)
    dbg = []  # (종류, 상자)
    avatar_boxes = []  # 이름이 밑에 붙는 아바타·얼굴 칸

    # 1~3. 사진 영역
    for idx, r in enumerate(regions):
        x, y, bw, bh = r["box"]
        patch = img[y:y + bh, x:x + bw]
        m = r["mask"]
        photo_mask[y:y + bh, x:x + bw] |= m
        if max(bw, bh) < 220:
            avatar_boxes.append(r["box"])
        at_left, at_right = x <= 1, x + bw >= w - 1
        if max(bw, bh) < SMALL_SIDE and bw < 0.8 * bh and not (at_left or at_right):
            # 목록 여백·스크롤 끝에서 잘린 아바타(화면 끝에는 안 닿음): 가까운 화면 끝 쪽이 잘린 것으로 본다
            at_left, at_right = (True, False) if x + bw / 2 < w / 2 else (False, True)
        small = max(bw, bh) < SMALL_SIDE and (0.4 <= bw / bh <= 2.5 or at_left or at_right)
        if small and (at_left or at_right) and bw < bh:
            # 화면 끝에 걸쳐 잘린 아바타: 온전한 원형 아바타를 그려 보이는 쪽만 잘라 붙인다
            full = avatar(bh, bh, idx)
            circ = np.zeros((bh, bh), np.uint8)
            cv2.circle(circ, (bh // 2, bh // 2), bh // 2, 255, -1, cv2.LINE_AA)
            cut = slice(0, bw) if at_right else slice(bh - bw, bh)
            new, cm = full[:, cut], circ[:, cut]
            # 원 밖이지만 사진이었던 곳(연결 요소)은 아바타 바탕색으로 덮는다
            m = cv2.max(cm, m if r["shape"] == "round" else r["comp"])
            r["mask"] = m
            dbg.append(("avatar", r["box"]))
        elif small:
            new = avatar(bw, bh, idx)
            dbg.append(("avatar", r["box"]))
        else:
            new = cartoonize(patch, args.detail)
            for fx, fy, fw, fh in faces.detect(patch):
                top = max(0, int(fy - fh * 0.3))
                hair_src = new[top:max(top + 1, int(fy)), max(0, int(fx)):max(int(fx) + 1, int(fx + fw))]
                hair = tuple(int(c) for c in np.median(hair_src.reshape(-1, 3), axis=0)) if hair_src.size else (60, 60, 60)
                draw_face(new, fx, fy, fw, fh, hair)
                dbg.append(("face", (int(x + fx), int(y + fy), int(fw), int(fh))))
            dbg.append(("photo", r["box"]))
        sel = m > 0
        out[y:y + bh, x:x + bw][sel] = new[sel]

    # 4. 이름. 사진 영역 안 글자는 만화화로 이미 뭉개지지만, 얼굴 상자 이름표처럼 UI가 사진 위에 얹은
    #    글자는 만화 위에도 '인물X' 로 다시 써서 이름표 모양을 살린다(확신도 낮은 것은 버림)
    lines = ocr.read(img)
    base = out.copy()  # 색은 만화화된 그림에서 뽑는다(사진 밖은 원본과 같다)
    names: dict[str, str] = {}
    n_skip = n_rep = 0
    jobs = []
    for (x0, y0, x1, y1), text, conf in sorted(lines, key=lambda t: (t[0][1], t[0][0])):
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        in_photo = photo_mask[min(h - 1, cy), min(w - 1, cx)] > 0
        if y1 <= STATUS_H or (in_photo and (conf < args.photo_text_conf or y1 - y0 < 20)):
            n_skip += 1
            continue
        spans = token_spans(text, (x0, y0, x1, y1))
        # 길이와 관계없이 목록과 정확히 맞아야 하는 낱말: 화면 끝에 잘린 것, 아바타 바로 밑 이름 자리
        strict = []
        for tok, a, b, *_ in spans:
            edge = a <= EDGE or b >= w - EDGE
            under = any(sx - 0.3 * sw <= (a + b) / 2 <= sx + 1.3 * sw and sy + sh - 6 <= y0 <= sy + sh + 30
                        for sx, sy, sw, sh in avatar_boxes)
            strict.append(edge or under)
        for (tok, a, b, open_l, open_r, nxt), ui, st in zip(spans, words.classify([s[0] for s in spans], strict), strict):
            if ui:
                continue
            key, particle = name_key(tok, names)
            if key not in names:
                names[key] = label_name(len(names))
            jobs.append((names[key] + particle, (a, y0, b, y1), open_l, open_r, nxt, st))
    pil = None
    for label, (a, y0, b, y1), open_l, open_r, nxt, cut in jobs:
        y0, y1 = max(0, y0 - 1), min(h, y1 + 1)
        a, b = max(0, a - 2), min(w, b + 2)
        bg = ring_color(base, a, y0, b, y1)
        # 낱말 폭 어림이 모자라 글자 끝이 남지 않게, 상자 끝에 붙은 잉크를 반 글자 폭까지 따라가 지운다
        # (앞뒤가 빈칸·줄 끝일 때만. 바로 붙은 괄호·조사 쪽으로는 넓히지 않는다)
        ink = (np.abs(base[y0:y1].astype(np.int32) - bg.astype(np.int32)).sum(2) > 60).any(0)
        if not nxt and cut:
            # 잘린 이름(화면·목록 끝, 아바타 밑)이 줄 끝일 때: 글자 사이 틈(< 0.2 글자, 낱말 사이 빈칸보다 좁음)을
            # 건너 이어지는 조각까지 지운다. OCR이 줄을 나눠 읽은 경우 뒤 낱말까지 먹지 않게 틈을 좁게 둔다
            hh = y1 - y0
            c, gap = b, 0
            while c < min(w, b + hh) and gap < 0.2 * hh:
                if ink[c]:
                    b, gap = c + 1, 0
                else:
                    gap += 1
                c += 1
        if nxt and nxt in "([{'\"·,.":
            # 바로 붙은 문장부호(괄호 등): 어림 끝 근처의 좁은 잉크 덩어리를 찾아 그 앞에서 멈춘다
            hh = y1 - y0
            lo, hi = max(a, b - hh // 2), min(w, b + hh // 2)
            segs, s0 = [], None
            for c in range(lo, hi + 1):
                on = c < hi and ink[c]
                if on and s0 is None:
                    s0 = c
                elif not on and s0 is not None:
                    segs.append((s0, c))
                    s0 = None
            narrow = [s for s in segs if s[1] - s[0] <= 0.4 * hh and s[0] > a + hh // 2]
            if narrow:
                b = min(narrow, key=lambda s: abs(s[0] - b))[0] - 1
        ext = int(0.4 * (y1 - y0)) if open_l else 0
        while a > 0 and ext > 0 and ink[a - 1]:
            a, ext = a - 1, ext - 1
        ext = int(0.4 * (y1 - y0)) if open_r else 0
        while b < w and ext > 0 and ink[b]:
            b, ext = b + 1, ext - 1
        box = base[y0:y1, a:b].reshape(-1, 3).astype(np.float32)
        dist = np.abs(box - bg).sum(1)
        fg = box[dist >= 0.7 * dist.max()].mean(0) if dist.max() > 30 else (bg * 0 + (40 if bg.mean() > 128 else 230))
        L, R = free_span(base, a, b, y0, y1, bg)
        out[y0:y1, a:b] = bg.astype(np.uint8)
        if pil is None:
            pil = Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))
        else:
            pil.paste(Image.fromarray(cv2.cvtColor(out[y0:y1, a:b], cv2.COLOR_BGR2RGB)), (a, y0))
        d = ImageDraw.Draw(pil)
        # 글자 크기: 원래 높이에서 시작해 빈 곳(이웃 글자 전까지) 폭에 들어갈 때까지 줄인다
        size = max(10, int((y1 - y0) * 0.72))
        font = load_font(size)
        while size > 9 and d.textlength(label, font=font) > R - L:
            size -= 1
            font = load_font(size)
        tw = d.textlength(label, font=font)
        cx = min(max((a + b) / 2, L + tw / 2), R - tw / 2)
        rgb = tuple(int(c) for c in fg[::-1])
        d.text((cx, (y0 + y1) / 2), label, font=font, fill=rgb, anchor="mm")
        n_rep += 1
        dbg.append(("name", (a, y0, b - a, y1 - y0)))
    if pil is not None:
        out = cv2.cvtColor(np.array(pil), cv2.COLOR_RGB2BGR)

    # 5. 상태바
    clean_status_bar(out)

    # 자체 점검: 변환본에서 다시 사진 영역을 찾아, 색이 아주 많은(실사가 남은 듯한) 곳을 센다
    leftovers = []
    for r in find_photo_regions(out):
        x, y, bw, bh = r["box"]
        u = len(np.unique(out[y:y + bh, x:x + bw][r["mask"] > 0].reshape(-1, 3), axis=0))
        if u > 600:
            leftovers.append((r["box"], u))

    stem = path.stem
    imwrite(out_dir / f"{stem}_abs.png", out)
    if args.debug:
        colors = {"photo": (0, 200, 0), "avatar": (255, 120, 0), "face": (0, 0, 255), "name": (0, 200, 255)}
        dimg = out.copy()
        for kind, (x, y, bw, bh) in dbg:
            cv2.rectangle(dimg, (x, y), (x + bw, y + bh), colors[kind], 2)
        imwrite(out_dir / f"{stem}_abs_regions.png", dimg)
    sec = time.perf_counter() - t0
    stat = {"file": path.name, "sec": round(sec, 2), "photos": sum(k == "photo" for k, _ in dbg),
            "avatars": sum(k == "avatar" for k, _ in dbg), "faces": sum(k == "face" for k, _ in dbg),
            "ocr_lines": len(lines), "ocr_in_photo_or_bar": n_skip, "names": len(names), "replaced": n_rep, "photo_like_leftovers": leftovers}
    return stat


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("inputs", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--detail", type=int, default=112, help="만화화 때 줄이는 긴 변(px). 작을수록 더 단순")
    ap.add_argument("--face-score", type=float, default=0.6, help="한 배율만으로 얼굴로 볼 YuNet 점수")
    ap.add_argument("--face-low", type=float, default=0.25,
                    help="두 배율 이상에서 거듭 나오면 얼굴로 볼 낮은 점수(낮을수록 보수적)")
    ap.add_argument("--photo-text-conf", type=float, default=0.3,
                    help="사진 영역 안 글자(이름표 등)를 '인물X'로 다시 쓸 최소 OCR 확신도")
    ap.add_argument("--debug", action="store_true", help="찾은 영역을 변환본 위에 표시한 그림도 저장")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    words = UiWords()
    t = time.perf_counter()
    ocr = Ocr()
    faces = Faces(args.face_score, args.face_low)
    print(f"준비 {time.perf_counter() - t:.1f}s (UI 낱말 {len(words)}개)")
    for p in args.inputs:
        print(process(p, args.out, words, ocr, faces, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
