# Photo Tracer 미니 앱

1단계 MVP 전에 사용자 여정을 그대로 시험하는 앱입니다: 설치 → 권한·배터리 예외 → 밤에 충전하며 정리 → 아침에 검색·인물.

| 파일 (`android/app/src/main/kotlin/…/photo_tracer/`) | 하는 일 |
|---|---|
| `Scanner.kt` | 갤러리를 DB와 맞춤(새 사진만 EXIF), 찍은 날·받은 날, 시간 구간과 대표 사진 |
| `Indexer.kt` | 사진을 한 번 디코드해 얼굴(모든 사진)과 장면 벡터(대표·구간 밖 사진). 한 장마다 저장, 발열·속도 저하 때 쉬기 |
| `IndexWorker.kt` | 충전 중 15분마다 깨어나는 WorkManager 작업, 포그라운드 서비스 알림 |
| `People.kt` | 얼굴 묶기 (묶음 중심과 비교하는 한 번 훑기) |
| `Search.kt` | 검색어 → 토크나이저 → 텍스트 모델 → 구간·사진 순위. 개발용 검색어 벡터 내보내기 |
| `Tokenizer.kt` | Gemma식 BPE를 Kotlin으로 (PC 단위 테스트로 Python과 토큰 id까지 같은지 확인) |
| `Models.kt` | 모델 복사·세션, 전처리 (0단계 측정 앱과 같음) |
| `lib/main.dart` | 화면: 정리 · 검색 · 인물 · 기록 |

만들기는 저장소 첫 `README.md`의 "실행"을 따릅니다(`poc/app_assets.py build`가 먼저).
