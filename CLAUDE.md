# Photo Tracer

설계 문서: https://claude.ai/artifact/38cCqVckN2vRvzRHmQiNqZ (로드맵: 0단계 검증 → 1단계 Android MVP → 2단계 iOS → 3·4단계 동기화/출판)

## 제작 과정 기록 (영상 제작용)

사용자 프롬프트 하나에 대한 작업을 마칠 때마다 mnemento MCP의 `record`로 기록을 하나 남긴다.

- `entity_type`: `dev_log`, `kind`: `created`, `by`: `claude-code`
- 필드: `project`(`photo_tracer`), `seq`(1부터 증가하는 순번 — 기록 전에 `query`로 마지막 seq 확인), `phase`(설계/0단계/1단계…),
  `prompt_summary`, `prompt_text`(원문, 길면 앞부분), `response_summary`, `actions`(수행한 일 목록), `artifacts`(만든 파일·링크),
  `decisions`(이번 턴에 확정된 결정), `video_notes`(영상에서 보여줄 만한 장면·포인트)
- 실패하거나 되돌린 시도도 숨기지 말고 `response_summary`에 적는다.
- mnemento 도구가 없거나 오류가 나면 사용자에게 알리고, 기록할 내용을 `docs/dev-log-pending.md`에 덧붙여 두었다가 다음에 옮긴다.
