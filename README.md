# Token Meter

macOS 메뉴 막대에서 Codex와 Claude Code의 로컬 세션 로그를 집계하는 앱입니다.

## 표시 항목

- Codex와 Claude 구독의 현재 한도 잔여율 및 리셋까지 남은 시간
- 오늘, 최근 7일, 최근 30일의 총 토큰
- Codex와 Claude별 입력·캐시·출력 토큰 및 응답 횟수
- opencode의 입력·캐시·출력·추론 토큰과 응답 횟수, 기록 비용
- 최근 14일 사용량 추이

메뉴 막대에는 상세 숫자 대신 Codex Spark 전용 버킷을 제외한 Codex와 Claude의 유효한 한도 창 중 가장 높은 사용률에 해당하는 상태 아이콘 하나를 표시합니다.

- 0~30%: sun
- 30% 초과~40%: cloud
- 40% 초과~50%: rain
- 50% 초과~60%: thunder
- 60% 초과~80%: alert
- 80% 초과~100%: xmark
- 측정 가능한 값 없음: questionmark

정확한 공급자·한도 창·사용률·리셋 시간과 토큰 합계는 아이콘 툴팁과 팝오버에서 확인할 수 있습니다.

Codex는 `~/.codex/sessions/**/*.jsonl`의 `last_token_usage`만 합산합니다. 누적값인 `total_token_usage`는 합산하지 않으므로 중복 집계되지 않습니다. Claude Code는 `~/.claude/projects/**/*.jsonl`의 assistant 응답 `message.usage`를 합산합니다. opencode는 `~/.local/share/opencode/opencode.db`(읽기 전용)의 assistant 응답 `tokens`와 `cost`를 합산합니다. opencode는 구독 한도가 없으므로 한도가 아닌 토큰 통계와 기록된 비용만 집계하며, `cost`를 기록하지 않는 공급자는 0으로 표시됩니다.

앱은 로그를 네트워크로 전송하거나 API 키·인증 파일을 읽지 않습니다. Codex 한도 확인 시에만 설치된 Codex CLI에게 그 CLI의 로그인 세션으로 현재 한도를 요청합니다.

## Codex 사용 한도

Codex는 세션 로그에 남은 구독 한도를 기록하지 않으므로, 앱은 설치된 `codex` CLI의 로컬 app-server에 `account/rateLimits/read`를 요청합니다. `rateLimitsByLimitId` 응답은 호환성을 위해 모두 파싱하지만, Codex Spark 전용 버킷은 상태 아이콘 판정과 팝오버에서 제외합니다. 나머지 버킷의 기본·보조 창에 대해 사용률, 남은 비율, 리셋 시각을 표시하며 1분마다 다시 조회합니다.

- 조회에 실패하면 이전 값을 현재 수치처럼 재사용하지 않고 실패 원인에 맞는 안내를 표시합니다.
- Finder에서 실행한 앱도 `fnm` 설치 경로를 찾을 수 있도록 표준 경로와 `~/.local/state/fnm_multishells`를 확인합니다. 선택한 `codex`와 같은 디렉터리를 자식 프로세스의 `PATH` 앞에 추가하므로 `/usr/bin/env node` 기반 CLI도 실행할 수 있습니다. 필요하면 `TOKEN_METER_CODEX_PATH` 환경 변수로 실행 파일 경로를 지정할 수 있습니다.
- 실패 원인은 CLI 미발견, CLI 실행 실패, App Server 초기화 실패, 한도 요청 실패, 응답 형식 오류로 구분합니다.
- 이 기능은 로컬 CLI의 내부 app-server 응답을 이용하므로, Codex CLI 업데이트 뒤에는 호환성 확인이 필요할 수 있습니다.

## Claude 구독 한도 연동

Claude Code는 구독 한도(`rate_limits`)를 세션 로그에 남기지 않습니다. 이 값을 로컬에서 얻을 수 있는 경로는 상태줄 명령의 stdin JSON뿐입니다. 그래서 앱의 **상태줄 연동 켜기** 버튼이 다음을 설정합니다.

- `~/.claude/token-meter/statusline-bridge.sh`를 만들고 `~/.claude/settings.json`의 `statusLine.command`가 이 스크립트를 가리키게 합니다.
- 원래 쓰던 상태줄 명령은 `~/.claude/token-meter/previous-statusline.sh`에 보관하고, 브릿지가 같은 stdin을 그대로 넘겨 이어서 실행합니다. 즉 기존 상태줄은 그대로 유지됩니다.
- 설정을 바꾸기 전 `~/.claude/settings.json.tokenmeter-<시각>.bak`으로 백업합니다.

브릿지는 상태줄이 그려질 때마다 한도 부분만 `~/.claude/token-meter/statusline.json`에 저장하고, 앱이 1분마다 그 파일을 읽습니다. `rate_limits`가 실린 렌더에서만 파일을 갱신하므로, 세션 첫 응답 전의 빈 값이 기존 수치를 지우지 않습니다. 값은 구독 계정에서 세션의 첫 API 응답 이후에만 채워집니다.

한도 수치는 마지막으로 실행된 Claude Code 세션 기준이며, 카드 하단에 갱신 시각이 표시됩니다. 해당 창의 리셋 시각이 지나면 숫자 대신 `리셋됨`으로 표시합니다. 되돌리려면 카드의 **연동 끄기**를 누르면 원래 상태줄 명령이 복원됩니다.

## 한도 표시 제한

Claude Code는 구독 한도를 상태줄에만 전달하며, 상태줄 JSON의 `rate_limits` 필드는 `rate_limits_available` 플래그가 true일 때만 채워집니다. API 키 인증, Bedrock, Vertex, 또는 프로필 스코프가 없는 세션에서는 이 플래그가 false가 되어 `rate_limits`가 null로 전달됩니다. 이 경우 5시간 세션과 7일 한도 모두 "정보 없음"으로 표시됩니다.

또한 5시간 세션 한도(`five_hour`)는 해당 창이 활성 상태일 때만 상태줄에 포함됩니다. 사용량이 낮아 5시간 창이 활성화되지 않은 경우, 7일 한도만 표시되고 5시간 세션은 "정보 없음"으로 표시됩니다. 이는 Claude Code의 동작이며 Token Meter의 한도가 아닙니다.

## 빌드 및 실행

```zsh
zsh scripts/build-app.sh
open dist/TokenMeter.app
```

앱 번들은 `dist/TokenMeter.app`에 생성됩니다. `/Applications`로 옮기면 일반 앱처럼 실행할 수 있습니다.
