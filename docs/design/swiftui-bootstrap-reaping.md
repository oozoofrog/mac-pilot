# SwiftUI bootstrap의 직접 자식 회수

2026-11-09. `debugger.py`의 supervisor가 종료한 직접 debugserver 자식을 LLDB Python worker의 종료와 독립적으로 회수한다. watchdog의 식별·예산·신호 정책은 변경하지 않는다. 실제 SwiftUI 수락은 계속 실패 상태다.

## 원인과 변경 범위

기존 supervisor는 worker의 `poll()` 루프와 종료 후 grace를 마친 다음 `finish_children`에서 server를 처음 회수했다. worker의 `finish_engine`이 detach와 close를 마쳐도 Python 프로세스 자체는 아직 실행 중일 수 있다. 이 구간에는 종료한 server가 회수되지 않고 남을 수 있다.

새 `ServerReaper`는 기존 parent/path 소유권 검사를 통과한 직접 `Popen` handle 하나만 보관한다. 별도 Python thread가 해당 handle의 `poll()`을 호출한다. 살아 있으면 `Event.wait(.025)`로 대기한다. 프로세스를 추가하거나 신호를 보내지 않는다. worker 감시와 grace가 진행되는 동안에도 server를 회수할 수 있다.

CPython 3.9의 POSIX `Popen.poll()`은 내부 lock과 `waitpid(pid, WNOHANG)`을 사용한다. 이 작업은 살아 있는 자식을 종료하지 않는다. 무기한 `wait()` thread는 custody 때문에 server를 살려 두어야 할 때 join할 수 없으므로 사용하지 않았다. 표준 Popen의 오류 처리 규칙은 바꾸지 않는다. 새로운 libproc 오류 해석이나 unknown 상태의 종료 분류는 없다.

## 소유권과 종료 순서

supervisor는 두 자식의 소유자다. reaper는 server handle을 관찰하고 회수할 권한만 갖는다. worker는 engine과 JIT caller의 custody를 유지한다. reaper는 target에 접근하지 않는다.

supervisor는 기존 worker grace와 최종 receipt 조회를 유지한다. 그 뒤 stop event를 설정하고 thread를 join한다. receipt 조회나 grace에서 예외가 발생해도 `finally`가 thread를 중지하고 join한다. `poll()`은 비차단 호출이고 event는 대기를 즉시 깨운다. join은 자식의 종료를 기다리지 않는다. 기존 작업·grace·자식 cleanup·recovery timeout 값은 그대로다.

join 이후에만 기존 `finish_children`과 `c.stop_child`가 server handle을 사용한다. reaper와 최종 cleanup이 동시에 `waitpid`를 호출하지 않는다. 이미 회수한 handle의 `returncode`는 Popen에 남으므로 최종 `poll`과 `wait`는 같은 종료 코드를 반환한다. handle을 버리거나 PID에서 신호 권한을 새로 만들지 않는다.

server가 worker 생성 전에 종료해도 같은 handle을 회수한다. worker 생성 실패는 기존 자식 cleanup 경로로 진행한다. 소유권 검사 전에 server가 종료하면 기존 admission 실패와 직접 자식 cleanup을 유지한다. 취소나 worker 실패로 `debuggerClosed`를 확인하지 못하면 기존 custody를 유지한다. 살아 있는 자식을 회수하려고 죽이거나 thread를 계속 남겨 두지 않는다.

thread에서 전파된 예외는 `serverReaper.error`에 기록한다. 최종 cleanup이 나중에 성공해도 이 오류가 있으면 bootstrap 수락을 거절한다. 예외를 종료 증거로 바꾸지 않는다. 원래 `finish_engine`과 `finish_children`의 gating은 그대로다. JIT caller 완료가 불명확하면 detach와 debugger close를 허용하지 않는다.

## 증거의 의미

`bootstrap.json`의 `serverReaper`는 정확한 직접 자식의 `pid`, thread 시작·종료 시각, 관찰한 `returncode`와 회수 시각, join 여부를 기록한다. 회수를 관찰하지 못하면 종료 코드와 회수 시각을 만들지 않는다. 시각은 기존 `protocol.monotonic_ns()`의 `CLOCK_MONOTONIC`을 사용한다. `childrenCleanupStartedNS`와 `childrenCleanupFinishedNS`는 최종 cleanup 호출의 순서를 기록한다.

이 관찰은 detach 성공, JIT caller 완료, target 안전, `debuggerClosed`, 전체 `childrenReaped`, recovery 또는 capture 성공을 뜻하지 않는다. 최종 수락은 기존 receipt와 cleanup·recovery 조건 및 reaper 오류 부재를 모두 요구한다.

## 검증과 한계

원래 코드에서 결정적 회귀 검사가 실패했다. 종료시킨 server fake가 회수되지 않은 동안 worker fake는 살아 있었다. 수정 후에는 worker가 살아 있는 동안 회수가 끝난다. 정상 종료, 최종 cleanup과의 경합, grace 중 회수, 취소, worker 생성 실패, receipt 부재, `debuggerClosed` 부재, reaper 오류, 오류 이후 최종 cleanup 성공, 살아 있는 handle의 thread 종료, 불명확한 JIT custody를 검사한다. fake 검사에는 실제 debugger나 target을 사용하지 않는다.

별도 CLI 검증은 사전 선언한 한 그룹에서 `/bin/cat` 두 개만 실행했다. 6초 마감과 handle별 2초 cleanup 상한을 사용했다. server의 stdin을 닫은 뒤 reaper의 회수와 `waitpid`의 `ChildProcessError`를 확인했다. sibling은 그 시점에 살아 있었다. 마지막에는 두 자식 모두 exit 0, 잔여 자식 0, 잔여 thread 0이었다. 이 검증은 신호를 보내지 않았다. CLI의 `observedNS`는 Python `time.monotonic_ns()` 시각이므로 protocol 시각과 직접 비교하지 않는다. 회수 선후 관계는 같은 호출 흐름의 waitpid 확인과 sibling poll로 입증한다.

`/usr/bin/python3 -B`의 Python 3.9.6으로 전체 SwiftUI probe, watchdog guard, fixture Python 회귀 검사와 distribution validator를 실행했다. 정확한 개수와 전체 로그, 초기 dirty bytes 기준 patch, 원본 증거 불변성 검사 및 SHA-256 manifest는 비공개 handoff에 보존한다. native GUI 검사는 적용하지 않았다.

원본 attempt 6의 실패 syscall과 errno는 계속 불명확하다. 기존 CLI 진단의 libproc ESRCH와 성공한 kill0 조합만으로 원본 debugserver의 실패 원인을 확정할 수 없다. 이번 수정이 실제 SwiftUI graph·PNG 수락을 해결했다고 주장하지 않는다.

전체 준비는 현재 소스에 대해 stale 상태다. live acceptance는 FAILED이며 예산은 6/6, fixture lifetime은 5회로 유지한다. 일곱 번째 시도, 전체 준비 재실행, 제품 통합, 전역 설치·재시작, Git 작업 또는 publication은 수행하지 않았다.
