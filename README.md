# Photo Tracer

폰 안의 사진을 인터넷 없이 기기에서 분석해, 가족 구성원·일(구간)별로 묶고 "작년 여름 아이랑 바닷가"처럼 한국어로 찾는 Android 앱입니다.

사진과 얼굴 정보는 기기 밖으로 나가지 않습니다.

## 진행 상황

| 단계 | 내용 | 상태 |
|---|---|---|
| 0단계 | 모델·방식 검증 (PC 평가 + 실제 폰 측정) | 완료 |
| 1단계 | Android MVP | 예정 |
| 2단계 | iOS | 예정 |

## 0단계에서 확인한 것

실제 가족 갤러리(사진 자체는 저장소에 없음)와 보급형 폰(Redmi, MediaTek MT6769, Android 14)으로 측정했습니다.

- **구간 나누기**: 촬영 시각·위치로 사진을 "같은 일" 단위로 나눈다(3시간 간격 + 1km). 애매한 경계는 SigLIP 이미지 유사도로 판단하고, 기준선 근처만 사용자에게 묻는다(사람 판정 98개 기준 자동 판단 83% 정확).
- **대표 사진만 분석**: 구간마다 시간상 고르게 몇 장을 고르고 중복·흔들림·노출 불량은 가까운 사진으로 바꾼다. AI 없이 고른 쪽이 정교한 방식과 눈가림 비교에서 동등 이상이었다.
- **한국어 자연어 검색**: [SigLIP 2 한국어 축소판](https://huggingface.co/alphaedge-ai/siglip2-base-patch16-512-kor-32768)을 ONNX로 바꿔 가중치 8비트로 양자화. 사람이 확인한 구간 설명 560개로 검색하면 상위 5 안에 맞는 구간이 68.8%, 같은 달로 좁히면 97.0%.
- **폰 속도**: 384px 입력, 장당 3.4초(원본 디코딩 포함). 512px는 6.6초인데 정확도 차이가 없어 384px로 정했다.
- **긴 작업**: 중간 저장 후 이어 하기, 충전 중 발열(배터리 42℃, 발열 경고 없이 속도 저하)을 실측했다.

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `poc/` | PC 검증 스크립트 (Python, `uv`) — 얼굴 검출·인식 평가, SigLIP 변환·양자화 비교, 구간 나누기, 대표 사진, 검색 평가, 폰 측정 조작 |
| `bench_app/` | 폰 측정 앱 (Flutter + Kotlin, onnxruntime-android, ML Kit) |

평가용 사진·라벨·결과(`eval_data/`)와 모델 가중치(`poc/models/`)는 개인정보와 용량 때문에 저장소에 넣지 않습니다.

## 실행

```powershell
cd poc
uv sync
uv run download_models.py      # 얼굴 검출·인식 모델 (OpenCV Zoo)
uv run export_siglip.py        # SigLIP 2 → ONNX 변환·양자화
uv run phone_bench.py --help   # 폰 측정 (adb 연결 필요)
```

## 쓰는 모델과 라이선스

| 모델 | 용도 | 라이선스 |
|---|---|---|
| [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet) | 얼굴 검출 (PC) | MIT |
| [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) | 얼굴 인식 | Apache 2.0 |
| [SigLIP 2 한국어 축소판](https://huggingface.co/alphaedge-ai/siglip2-base-patch16-512-kor-32768) | 장면 이해·검색 | Apache 2.0 |
| ML Kit 얼굴 검출 | 얼굴 검출 (폰) | Google ML Kit 약관 |

## 라이선스

[Apache License 2.0](LICENSE)
