---
name: simulator-pilot
description: Use for iOS Simulator app launch, logs, screen interaction, test data and change verification. Use mac-computer-use for screen controls; follow the project build instructions for compilation. Excludes Mac desktop/browser/web view tasks and account signup.
---

# Simulator Pilot

iOS 시뮬레이터 작업의 입구다. CLI는 Xcode의 Swift로 빌드하고 화면 조작에는 별도 mac-computer-use Plugin을 쓴다.

| 도구 | 맡는 일 |
|---|---|
| mac-cu `simulator` 도구 (`mac-computer-use` 플러그인) | 화면 요소 읽기(`describe`, `wait`), 탭·스와이프·최대 세 손가락 제스처(`gesture`)·입력·키·버튼·붙여넣기, 스크린샷 |
| `sim-pilot` CLI (이 스킬의 `tool/sim-pilot.swift`) | 스킴 상태, 빌드·설치·실행, os_log·콘솔 로그, 테스트 사진 넣기, 이 기기에서 되는 기기 동작 표(`caps`) |
| `xcrun simctl` | 부팅, 위치, 권한, 푸시, 화면 모드, 상태 막대 |
| `xcrun devicectl` (Xcode 27 이상) | Face ID 등록·인증, 위치 경로 이동, 회전, 화면 녹화, 메모리 경고, 손쉬운 사용·VoiceOver |

`<SKILL_DIR>`는 이 SKILL.md가 있는 폴더다.

## 1. 준비 확인

처음 한 번, 아래를 한 번에 확인하고 빠진 것만 알린다.

```sh
xcrun simctl list devices booted                 # 부팅된 기기
xcodebuild -version | head -1                    # mac-cu simulator 도구는 Xcode 27 이상
~/.local/bin/sim-pilot --version 2>/dev/null     # 없거나 tool/sim-pilot.swift의 version보다 낮으면 설치
```

- **sim-pilot 설치**: `mkdir -p ~/.local/bin && swiftc -O "<SKILL_DIR>/tool/sim-pilot.swift" -o ~/.local/bin/sim-pilot`
- **mac-cu**: `simulator` 도구(Claude Code `mcp__mac-cu__simulator`, Codex `mcp__mac_cu__simulator`)가 없으면 mac-computer-use 스킬의 설치 절차를 따른다. 설치 후 에이전트를 다시 시작해야 도구가 보인다.
- Xcode 27 미만이거나 mac-cu를 쓸 수 없으면 [fallbacks.md](references/fallbacks.md)를 읽는다.

## 2. 기기 고르기

- **런타임·기기 준비:** mac-cu 메뉴바 또는 앱 메뉴의 **시뮬레이터 관리…**에서 설치된 전체 기기를 조회하고, 런타임 다운로드·DMG 가져오기, 호환 기기 생성, 선택 UDID 실행과 네이티브 LCD 열기를 할 수 있다. 런타임은 시뮬레이터 OS이며 테스트 앱 설치와 다르다. 다운로드·가져오기는 해당 화면에서 사용자가 명시적으로 선택한다. 생성한 기기는 자동 부팅하지 않으며, 사용 기록이 있는 기기는 관리 화면에서 실행/LCD 열기를 차단한다. 앱 빌드·설치·실행은 계속 아래 CLI와 프로젝트 절차를 따른다.
- **기기 상태를 사용자에게 알린다.** 시뮬레이터 작업을 시작할 때 한 번, 지금 켜진 기기와 각 기기를 누가 쓰는지(`sim-pilot status`)를 짧게 보여 주고, Mac 메뉴 막대의 mac-cu 아이콘 > "시뮬레이터 상태 창 열기…"에서 언제든 볼 수 있다고 알린다(5초마다 새로 읽는다). 기기를 켜거나 끄거나, 접거나 돌리거나, 설정을 바꾸면 무엇을 바꿨고 끝나면 어떻게 되돌리는지 그때 말한다.
- **다른 세션과 기기를 함께 쓴다.** `sim-pilot devices`의 `claimed_by`(에이전트 · 프로젝트 · 하는 일)·`mine`, 또는 `sim-pilot claims`로 누가 쓰는지 본다. `sim-pilot sessions`는 mac-cu·sim-pilot을 쓰는 에이전트 세션 전부와 각자 쓰는 기기를 보여 준다. 고른 기기(또는 내가 켠 기기)는 `sim-pilot claim --udid <UDID> --note "<할 일>"`로 기록한다. 기록 없이 mac-cu `simulator`로 입력을 보내면 mac-cu가 그 기기를 이 세션 것으로 대신 기록하지만(`auto`), 30분 동안 입력이 없으면 지워지므로 오래 쓸 기기는 직접 기록한다. 일이 끝나면 `sim-pilot release --udid <UDID>`. 꺼진 기기와 끝난 세션의 기록은 저절로 지워진다.
- **다른 세션이 쓰는 기기(`mine: false`)는 바꾸지 않고 요청한다.** 끄기·다시 부팅·접기·회전·설정 변경·입력을 하지 않는다. 그 기기가 필요하면 `sim-pilot request --udid <UDID> --note "<이유>"`로 요청을 남기거나, 놓을 때까지 `sim-pilot acquire --udid <UDID> --wait <초> --note "<할 일>"`로 기다린다(기다리는 동안 요청이 남고, 거절당하면 종료 코드 4와 답을 돌려준다). 답은 `sim-pilot requests`의 `outgoing`에서 본다. 급하면 사용자에게 묻고, 함께 써도 된다고 하면 `claim --force`를 쓴다.
- **내 기기에 온 요청에 답한다.** 다른 세션이 내 기기를 기다리면 `sim-pilot` 명령의 stderr와 mac-cu `simulator` 결과에 `요청:`/`Notice:` 줄이 붙는다(`sim-pilot requests`의 `incoming`). 다 썼으면 `sim-pilot release --udid <UDID>`, 바로 넘기려면 `--to <세션>`을 붙인다. 계속 써야 하면 `sim-pilot decline --udid <UDID> --note "<언제까지>"`로 답한다. 요청은 30분 뒤 사라진다.
- **켜 둘 수 있는 대수에 제한이 있다.** 기기를 켜는 일(`simctl boot`, `xcodebuild test`, 기기 패널 열기, Xcode 실행·프리뷰) 전에 `sim-pilot budget`을 본다. `canBoot.default`가 false면 새로 켜지 않는다: `owned`가 false인 켜진 기기를 그대로 쓰거나, 쓰는 세션이 끝나기를 기다리거나, 어느 세션이 쓰는지 사용자에게 알린다. 직접 켤 때는 `sim-pilot acquire --udid <UDID> --note "<할 일>"`을 쓴다(자리가 있을 때만 켜고 사용 기록까지 남긴다; 꽉 찼으면 종료 코드 3). 한 세션은 한 대만 켠다. 일이 끝나면 내가 켠 기기는 `xcrun simctl shutdown <UDID>`로 끄고 `sim-pilot release`한다. 제한은 사용자가 mac-cu 메뉴 막대의 **시뮬레이터 동시 실행 제한**에서 바꾼다. 쓰는 곳 없이 오래 켜져 있는 기기는 mac-cu가 끌 수 있으므로, 쓰는 기기는 꼭 기록한다.
- 부팅된 기기가 하나면 그 기기를 쓴다. 여럿이면 이름·OS를 보여 주고 한 번 묻는다. 고른 UDID를 이번 작업 내내 쓰고, mac-cu `simulator` 호출에는 `device`로 넘긴다.
- 부팅된 기기가 없으면 `xcrun simctl list devices available`에서 고를 기기를 묻고 `sim-pilot acquire --udid <UDID> --note "<할 일>"`로 부팅한다. 화면 창이 필요하면 설치된 쪽을 연다(Xcode 27은 Device Hub, 그 이전은 Simulator). 조작·스크린샷에는 창이 없어도 된다.
  ```sh
  X="$(xcode-select -p)"; if [ -d "$X/../Applications/DeviceHub.app" ]; then open "$X/../Applications/DeviceHub.app"; else open "$X/Applications/Simulator.app"; fi
  ```
- 사용자가 화면을 직접 보고 싶어 하면 mac-cu `simulator {"action":"window","device":"<UDID>"}`로 네이티브 LCD를 연다. 관리 화면은 사용 기록이 있으면 열기를 차단하므로, 에이전트가 claim한 기기는 이 도구 경로를 사용한다. Device Hub가 필요하면 [references/device-hub.md](references/device-hub.md)를 따른다. Claude 앱의 시뮬레이터 패널에 기대지 않는다. Device Hub의 버튼(접기·펴기·회전·홈·녹화)과 설정(모양·손쉬운 사용·위치·소리)도 mac-cu로 백그라운드에서 누를 수 있다.

## 3. 요청 → 읽을 문서

요청에 맞는 문서 하나만 읽고 따른다.

| 요청 예 | 문서 |
|---|---|
| "카톡 실행해 줘", "로그 보여 줘", "AccountList 로그만", "어떤 스킴 깔려 있어?" | [launch-and-log.md](references/launch-and-log.md) |
| "설정 들어가서 다크 모드 켜 줘", "이 버튼 눌러 봐", "스크린샷" | [drive.md](references/drive.md) |
| "사진 50장 넣어 줘", "위치를 판교로", "알림 권한 허용해 둬", "푸시 보내 봐" | [test-data.md](references/test-data.md) |
| "Face ID 성공시켜 줘", "가로로 돌려 줘", "화면 녹화해 줘", "메모리 경고 보내 봐", "흔들어 봐", "경로 따라 이동" | [test-data.md](references/test-data.md)의 "기기 동작 흉내" |
| "고친 거 앱에서 되는지 봐 줘", "이 수정 실제로 확인해 줘" | [verify.md](references/verify.md) |
| "샌드박스 계정 가입해 줘", "테스트 번호로 로그인" | 프로젝트의 계정 가입·로그인 절차를 확인한다 (이 Plugin에는 포함되지 않음) |
| 로컬 빌드 에러·워닝, 유닛 테스트 | 프로젝트의 빌드·테스트 지침 |

## 4. 공통 규칙

- **Real 스킴(`com.kakao.talk`)** 은 실서비스 앱이다. 실행·로그 전에 사용자에게 확인하고, 확인을 받으면 `sim-pilot`에 `--allow-real`을 붙인다.
- 앱 데이터를 지우는 명령(`simctl erase`, `simctl privacy ... reset`, `simctl uninstall`)은 실행 전에 확인한다.
- 조작 도구는 이벤트를 보내기만 한다. 결과는 `describe`나 `screenshot`으로 확인한 뒤 보고한다.
- 파일로 남기는 것(스크린샷 저장본, 로그 저장본)은 `~/Documents/claude-outputs/simulator-pilot/`에 둔다. 사용자가 위치를 정하면 그 위치를 따른다.
- 로그·화면에 개인정보·토큰이 보이면 그대로 옮겨 적지 않는다.
- 시뮬레이터가 갑자기 꺼지거나, 부팅 뒤 SpringBoard가 죽거나, 부팅이 `Invalid argument`로 실패하면 [references/known-issues.md](references/known-issues.md)부터 본다. 여러 기기는 한 대씩 부팅한다. 이미 켜져 있는 기기는 다른 세션이 쓰고 있을 수 있으니, 끄거나 다시 부팅하기 전에 묻는다.
