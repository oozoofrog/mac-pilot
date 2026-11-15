# SwiftUI 시도 6 프로세스 식별 실패 진단

2026-11-09. 이 작업은 headless 진단이다. **guard 동작은 변경하지 않았다.** 실제 종료한 CLI에서도 libproc 조회 실패와 성공한 `kill(pid, 0)`이 함께 나타났다. 그러나 이 결과만으로 시도 6의 정확한 실패 syscall이나 errno를 결정할 수 없다. 식별할 수 없는 프로세스를 종료 상태로 간주하는 수정은 정당화되지 않았다.

## 원본에서 확인한 사실

시도 6 parent는 PID 44896의 `(debugserver)` 표본을 `unknown`으로 분류했다. 이전 관찰은 같은 PID, start `[1794233153, 30488]`, parent 44658과 선택한 Xcode의 debugserver 경로를 기록했다. 마지막 실패는 `cannot verify resident executable PID 44896`이다. 실패한 libproc 호출과 errno는 기록하지 않았다.

`process_identity`는 status → path → status 순서로 읽고 start 변경을 거절한다. 일반 조회 예외가 발생하면 `identify_live_server`가 새 `gone_or_zombie` 조회를 한다. 이 조회는 status 5를 확인하거나, status 조회 실패 뒤 `kill0`의 ESRCH를 확인해야 종료로 분류한다. 나머지는 `UNVERIFIED`다. runner는 이 결과를 무시하지 않고 협조 중단을 요청한다. 이전 경로나 짧은 ps 이름은 signal 권한이 아니다.

LLDB는 제출·detach를 마쳤고 두 debugger 자식은 exit 0으로 회수됐다. 이후 별도 channel의 `cancelledBeforeEntry`는 capture에 진입하지 않은 callback을 기록했다. 원본 실패 기록과 후속 cleanup 성공은 별개다. graph와 PNG 수락은 계속 실패다.

## 유한 CLI 진단

실행 전에 `/bin/cat` 자식 최대 16개, 직렬 실행, 자식마다 최대 200개 종료 후 표본, 전체 20초 마감을 선언했다. stdin을 닫아 종료를 유도했다. 각 자식의 정확한 Popen handle을 회수한 뒤 다음 자식을 시작했다. GUI·Simulator·fixture·debugger는 실행하지 않았다.

각 표본은 `proc_pidinfo` → `proc_pidpath` → `proc_pidinfo` → `kill0` 순서다. libproc 호출 전에 errno를 0으로 초기화했다. 반환값, errno, monotonic 시작·종료 시각, PID, parent, start, state와 경로를 원본 trace에 저장했다. 실패한 pidinfo의 0 필드는 읽기에 실패한 buffer 값이며 실제 process state가 아니다.

총 16개 자식에서 3,232개 표본을 수집했다.

| 관찰 | 표본 수 |
| --- | ---: |
| path 성공, 이후 status 성공(state 2), kill0 성공 | 1,571 |
| path 성공, 이후 status ESRCH, kill0 성공 | 5 |
| path ESRCH, 이후 status ESRCH, kill0 성공 | 1,640 |
| reap 후 path·status·kill0 모두 ESRCH | 16 |

path 실패 뒤 정상 크기의 non-zombie status를 읽은 사례는 0개다. 반면 libproc가 PID를 조회하지 못하는 동안 kill0가 성공하는 종료 구간은 확인했다. 이는 현재 guard가 `UNVERIFIED`를 반환하는 조건이다. 성공한 kill0만으로 live와 zombie를 구분할 수 없다. 이 진단의 자식은 모두 exit 0으로 회수됐고 최종 kill0는 16개 모두 ESRCH였다.

CLI에서 확인한 syscall 조합은 원본의 가능한 원인이다. debugserver에서 같은 조합이 발생했다고 단정할 수 없다. 짧은 동기식 재조회가 실제 worker의 reap 시점보다 늦게 끝난다는 근거도 없다. 임의의 재시도 횟수나 대기 시간을 넣지 않았다. guard 수정 후보는 0개이며 진단 실행은 1회다.

## 변경과 검증

`test_watchdog_guard.py`에 5개, `test_probe.py`에 6개 계약 검사를 추가했다. libproc ESRCH와 성공한 kill0의 조합, path 실패 뒤 fresh live/zombie, denied read와 absent, start 변경, parent/path 불일치, unknown 거절, 종료 항목 제외 및 두 active server의 예산 초과를 검사한다. 관찰 결과를 signaling 권한으로 바꾸지 않는지도 검사한다.

새 검사는 기존 guard에서 통과한다. 따라서 pre-fix 실패 후 correction 성공을 주장하지 않는다. runner와 watchdog 구현은 변경하지 않았다.

- watchdog: 최종 23/23 통과.
- SwiftUI probe: 32/32 통과.
- fixture session: 26/26 통과.
- fixture 전체: 53개 중 45개 통과, failure 3개와 error 5개. 변경하지 않은 edit/failure qualification의 첫 capture가 `status=failed`를 반환했다. 이 원인은 이번 범위에서 수정하거나 확정하지 않았다. 전체 통과로 보고하지 않는다.
- distribution validator 및 `git diff --check`: 통과.
- native safety 구현은 영향받지 않았다. 기존 준비의 7/7 근거를 재사용하며 새 native 실행을 주장하지 않는다.

전체 log, syscall trace, 소유 CLI cleanup readback, 이번 변경 diff와 source/artifact SHA-256 manifest는 비공개 handoff에 보존했다. 원본 시도 6 증거는 hash로 불변성을 확인했다. 관련 없는 dirty 파일은 변경하지 않았다.

전체 준비와 runtime 수락을 새로 수행하지 않았다. runner/watchdog 구현 hash는 이전과 같다. 변경한 테스트를 포함하는 준비 입력은 다시 동결해야 하므로 현재 전체 준비를 새 소스의 수락 증거로 사용하지 않는다. 시도 6/6과 누적 fixture 실행 5회는 그대로다. 일곱 번째 시도는 없다. 전역 1.31 앱과 사용자 상태를 변경하지 않았다.

## Lead의 fixture 테스트 후속 확인

전체 fixture 테스트의 8개 실패는 첫 capture의 `notDispatched`에서 시작했다. 실제 오류는 개발 소스에 생성하지 않는 `resident-build.json`을 찾는 호출이었다. `FakeRuntime`은 legacy fake engine을 사용하지만, schema 2의 기본 resident transport를 호출하고 있었다. 기존 `test_view_edit_backend.py`와 같은 방식으로 이 테스트 fixture 안에서만 legacy supervisor를 명시했다. 제품의 resident 경로나 admission 검사는 변경하지 않았다.

수정 후 fixture 전체 53/53, distribution validator와 `git diff --check`가 통과했다. 이 결과는 schema·ledger·sequence 및 fake transport 계약의 headless 근거다. 실제 resident bootstrap, SwiftUI graph 또는 PNG 수락 근거는 아니다. 이전 45/53 로그는 보존했다.
