# SwiftUI 프로세스 관찰의 종료 전이와 수락 제한

관찰자는 하나의 수락 cutoff 안에서 관련 process group을 다시 읽는다. 일시적인 `UNVERIFIED`는 성공이 아니다. 같은 PID의 새 완전한 identity 또는 새 종료 증거가 있어야 관찰을 완료한다. 미확인 PID가 `ps`에서 사라져도 후속 identity 관찰 대상에서 제외하지 않는다.

이전 문서의 엄격한 **3초 함수 반환 보장**은 사용자의 요구가 아니라 리드가 추가한 조건이었다. 리드는 이 조건을 철회했다. 현재 계약은 수락 시각을 제한한다. 동기 syscall 실행 중 취소나 엄격한 함수 반환 시각은 보장하지 않는다.

## 시간과 읽기 경계

부모는 첫 `ps` 전에 `ProcessObservation`을 만든다. cutoff는 `min(observationStart + PROCESS_READ_TIMEOUT_SECONDS, parentStopMonotonic)`이다. 현재 상수는 3초다. 부모가 전달하는 절대 deadline과 clock은 모두 세션의 명시적 `CLOCK_MONOTONIC`을 사용한다. XcodePython3.9의 `time.monotonic_ns()` epoch와 비교하지 않는다.

모든 후속 `ps`에는 같은 cutoff의 잔여 시간만 전달한다. 초기 snapshot 뒤에 3초를 새로 부여하지 않는다. 입력 확인과 cutoff 검사는 각 `ps` 및 identity syscall 전후, 재관찰 경계, 최종 수락 전에 실행한다. deadline 또는 입력 검사에서 발생한 예외를 unknown으로 바꾸지 않는다. 부모의 기존 신호 예외도 그대로 전파한다.

`libproc` 호출은 동기식이다. CPython3.9의 `subprocess.run` timeout 정리는 kill 뒤 timeout 없는 wait를 호출한다. 따라서 호출이 cutoff 뒤에 반환할 수 있다. 그 경우 성공을 수락하지 않는다. 실제 API를 사용하는 제어된 timeout 테스트는 이 반환 지연 가능성을 계속 검증한다. 이 테스트는 실제 syscall 지연의 빈도나 Attempt8 지연 시간을 측정하지 않는다. 외부 watchdog과 기존 정리 reserve는 변경하지 않았다.

## identity와 전체 group 검증

`proc_pidinfo`, `proc_pidpath`, `kill(pid, 0)`의 결과와 즉시 읽은 errno를 호출 순서대로 기록한다. 성공한 PID, start, parent, group, path는 같은 관찰의 후속 시도까지 유지한다. 실패한 BSDInfo 버퍼나 실패한 path 버퍼는 identity로 사용하지 않는다. path 실패 예외에도 앞서 성공한 부분 identity를 보존한다.

관찰한 start, parent, group, path가 바뀌면 즉시 거절한다. 재관찰로 이 변화를 지울 수 없다. `ps`의 짧은 이름은 실행 파일 권한이 아니다. 성공한 경로도 다음 시도의 경로 조회를 대신하지 않는다. 모든 관련 PID를 새로 조회한다. 정상 종료·zombie 판정은 새 상태 조회 또는 `kill0`의 ESRCH에만 근거한다. 성공한 `kill0`와 권한 거부는 종료 증거가 아니다.

재관찰마다 현재 group과 알려진 PID 및 그 자손을 확인한다. group 밖으로 이동한 자손도 검사한다. 각 부분 결과에 실행 파일 개수와 parent topology 예산을 적용한다. 중복 실행 파일이나 예상하지 않은 경로·parent·group은 재시도하지 않는다. 미확인 PID가 남아 있으면 전체 수락을 보류한다. 관찰 기록은 `residentExecutableObservations`에 저장한다. 기존 단발 `identify_live_server()`의 unknown 의미는 유지한다.

OS 읽기는 원자적이지 않다. 읽기 사이에서 생성되고 종료되어 한 번도 관찰하지 못한 프로세스나 중간 identity 변화의 부재는 증명하지 못한다. 이 구현은 실제로 관찰한 모순을 검출하며 모든 순간의 process graph를 증명하지 않는다.

## 호출과 권한

부모의 `observe_processes()`가 하나의 관찰 안에서 기존 여섯 인자 process-budget callback을 호출한다. SwiftUI runner는 이 경로에서 새 cutoff를 만들지 않는다. 직접 호출되는 runner 경로도 같은 reconciliation을 사용한다. 기존 callback 호출 규약은 유지한다.

관찰은 attach, detach, JIT, capture, claim, 신호 권한을 부여하지 않는다. 관찰자가 자식을 reap하지 않는다. `kill0`는 읽기 전용 존재 확인이다. ServerReaper, debugger custody, 직접 자식 핸들 기반 정리, 부모 finally 및 정리 reserve는 변경하지 않았다.

## 검증과 증거 범위

기존 unknown-then-reaped 계약은 수정 전 red와 수정 후 green으로 확인한다. 추가 제어 테스트는 초기 ps를 포함한 단일 cutoff, ps·identity·최종 수락의 시간 초과, persistent unknown/denied, 입력·부모 중단, 부분 lifetime 이후 재사용, parent/path/group 변화, 중복 예산, 미확인 PID 소멸, 새 자손, syscall 결과와 errno 보존을 검사한다. 기존 직접 관찰 및 정리 회귀도 유지한다.

Attempt8은 FAILED 8/8이며 fixture lifetime은 여섯 번이다. 원래 syscall과 errno는 알 수 없다. 제어된 ESRCH 재현을 Attempt8의 정확한 syscall 순서로 단정하지 않는다. `cancelledBeforeEntry`와 graph/images 부재도 바뀌지 않는다.

이번 후보는 headless source와 회귀 테스트만 검증한다. 아홉 번째 live 시도, 별도 실제 CLI 종료 실험, GUI, Simulator, fixture 실행, 실제 LLDB/debugserver/attach, full preparation, 제품 설치, 백업 또는 게시를 실행하지 않는다. 기존 headless 회귀 suite의 소유 CLI 자식 실행은 별도 진단 실험이 아니다. 변경 후 full preparation은 stale이다. 런타임·제품·설치 성공을 주장하지 않는다.

최종 검증에서 probe 50개와 watchdog 28개는 통과했다. fixture 54개 중 CLI guard 테스트 3개는 timeout으로 실패했다. native-safety 7개 중 helper 경로 1개는 변경하지 않은 `native_check_support.py`의 `ps` timeout으로 실패했다. 원래 계약 스크립트를 그대로 실행한 마지막 검사도 최초 `ps` timeout으로 실패했다. `ps`를 제어된 빈 snapshot으로 대체한 같은 계약은 통과했다. 이 결과를 전체 suite 통과로 보고하지 않는다. 이후 실제 CLI 검사를 반복하지 않았다. 배포 validator와 diff 공백 검사는 통과했다. 정확한 호스트 지연 원인과 최종 프로세스 잔존 여부는 별도 확인하지 못했다.


### 리드 재검증 — 2026-11-10

리드는 같은 후보 소스로 fixture 54개와 native-safety 7개를 직렬 재실행했고 모두 통과했다. 그러나 원래 계약 스크립트는 최초 `ps` timeout으로 다시 실패했다. 제어된 계약 통과와 실제 `ps`를 포함한 계약 실패를 구분한다. 후보 전체 검증은 완료되지 않았다.

별도 읽기 전용 진단에서 `proc_listallpids`와 사용자 프로세스의 상태·경로 조회는 약 0.010초에 끝났다. 알려진 검사 실행 파일 경로와 일치하는 프로세스는 없었다. 권한으로 읽을 수 없는 상태와 관련 없는 경로 조회 실패가 있어 전체 호스트에 대한 무조건적인 잔여 프로세스 부재를 주장하지 않는다. 이어진 숫자 열만의 `ps`는 timeout과 자식 회수까지 약 73.02초가 걸렸다. 다음 원래 열 구성의 조회는 약 0.183초에 성공했다. 두 진단 자식은 모두 회수됐다. 이 차이는 조회 지연의 변동을 보여 주며, 특정 열이나 확정된 운영체제 원인을 증명하지 않는다.

조회가 다시 완료된 근거로 실패한 검사들을 한 번 재검증했으며, 원래 계약의 재실패 뒤 추가 실행은 중단했다. 마지막 계약 실행은 약 20.83초 뒤 실패를 반환했다. timeout 값을 늘리거나 수락 기준을 낮추지 않았다. 원래 실패 로그와 이전 실험 증거는 보존했다. 다음 단계는 실행 없는 코드 리뷰다. 실제 SwiftUI 재시도, full preparation과 제품 설치는 진행하지 않았다.


### 부분 토폴로지 검사의 부모 문맥 수정 — 2026-11-10

읽기 전용 리뷰는 미확인 부모를 snapshot에서 제거한 뒤 전체 관계 검사를 호출하는 결함을 찾았다. 짧은 이름으로 보이는 probe의 정상 `xcrun` 자식과, 자식 PID가 부모 PID보다 작은 경우가 모두 거절됐다. 실제 `session.observe_processes()`와 SwiftUI callback을 사용하는 두 제어 테스트가 수정 전 실패하고 수정 후 통과했다.

부분 검사는 현재 pass의 정확한 `ps` 경로와 성공한 부분 identity를 합쳐 이미 관찰한 부모를 유지한다. 부모나 조상의 식별이 미완료이면 그 부모의 역할에 의존하는 판단만 보류한다. 부모 경로가 이미 확인됐고 허용되는 부모 종류가 아니면 보류하지 않는다. 이 조건은 같은 관찰자를 사용하는 기존 resident lifetime/product callback에도 적용했다. 부분 문맥은 callback 종료 시 제거하며, 최종 수락에서는 완전한 현재 identity로 원래 관계 검사를 수행한다. `ps` 경로와 부분 문맥은 최종 identity나 실행·신호 권한이 아니다.

추가 회귀는 미확인 부모의 후속 완전한 식별, 끝까지 미확인인 부모, 종료했거나 다른 종류인 부모, 잘못된 실행 경로, 중복 utility, 중첩 supervisor/worker 관계를 검사한다. 이미 확인된 금지된 부모 관계가 조상 미확인이나 자식 종료로 사라져서는 안 된다는 테스트도 수정 중 실패를 확인한 뒤 통과했다. 기한, 신호, reaping과 debugger custody는 바꾸지 않았다.

현재 소스에서 SwiftUI probe 56개, watchdog 28개, resident lifetime 22개, resident product 16개, fixture 54개가 통과했다. 제어된 원래 계약과 실제 `ps`를 사용하는 원본 계약 스크립트도 각각 통과했다. 이전 `ps` timeout과 지연 로그는 보존하며, 호스트 지연 원인은 아직 확정하지 않았다. 이 결과는 headless 변경의 검증이다. 새 full preparation, 실제 SwiftUI 캡처와 제품 설치는 별도 단계다.


### Attempt12 target-role prerequisite — headless investigation, 2026-11-10

Attempt12 remains failed. Its final parent observation rejects the known target's separate process group before reading that target's current start identity. The rejected row establishes PID/parent/group/path only. Initial target, request, recovery and independent cleanup identity agreement does not supply the missing fresh identity under that observation's cutoff. The independently reconciled late `cancelledBetweenStages` result releases custody; it does not turn the failed observation into runtime acceptance.

A deterministic fake-kernel reproduction invokes `session.observe_processes()` with each actual SwiftUI, resident-lifetime and resident-product callback. All three paths reject the target at `validate_groups()` before the mocked identity reader runs. This is RED evidence only. No observer correction or target-role exemption was installed in this investigation.

The unresolved contract is the relationship binding supplied to the observer. The published target has exactly PID/start/path/device. The debugger's `worker.json` separately records its server identity and supervisor, but current shared and legacy callback inputs do not consume that operation binding. They also do not carry the original detached parent identity. A current same-path worker child alone does not identify the intended debugger lifetime; an untraced target with an arbitrary changed parent alone does not establish legal detach. A parent/group exception would therefore exceed the demonstrated evidence.

Before implementing an exemption, define how the shared observer and all legacy entry paths obtain the expected debugger lifetime and detached-parent binding. Fresh reads must validate those bindings, the target PID/start/canonical path/device, and the current relationship within the original three-second/parent cutoff. Stored bindings are comparison inputs, never substitutes for fresh identity. Discovery must traverse the target before separating its role, retain every discovered descendant across detach/termination, and preserve global duplicate budgets. The target role grants no helper, Popen, signal or capture authority. No-target/guard calls must retain strict rejection.

This investigation leaves that data-flow contract unresolved and makes no GREEN, implementation-completion, native preparation or runtime claim. No new runner invocation or fixture lifetime was authorized or executed. Preparation remains stale; earlier isolated and native evidence is unchanged.

### Attempt4 continuation — separate target role implemented, headless only (2026-11-10)

The preceding investigation records the incomplete candidate at that time. This continuation implements the lead's later data-flow decision. It does not change Attempt12's failed result, late partial graph, released custody, or runtime budget.

`session.worker` now atomically publishes `target-observation.json` before the closed four-field `target.json`. The separate version-1 schema contains owner UUID, full worker lifetime, unchanged target, original process group and full original-parent lifetime. Publication brackets production device identity with kernel identities, verifies the target is untraced/running, and checks parent/worker continuity, input and the existing admission deadline. The parent reads at most 16 KiB and rejects extra fields, missing data, wrong owner or worker binding. Session output and owner binding supply expected metadata; they do not prove current identity.

Each target-bearing shared or legacy callback enters `ProcessObservation` with that metadata and the production `ProcessProbe.identity(device=True)` reader. The observer brackets both device reads and fresh parent/ancestor identities within its existing cutoff. Detached targets must retain the bound original parent lifetime/path and process group. Attached targets must join the selected debugserver's fresh lifetime and current ancestor chain to the live parent-owned worker. The existing callbacks then enforce their respective direct or probe/supervisor/server topology and original helper counts. No historical operation receipt is required for this current observer role. No attach, signal, termination or custody authority follows from it.

Partial group admission defers only the exact candidate row. Final acceptance requires the complete target proof. Unknown kernel identities remain pending under the original cutoff; known contradictions reject. Snapshot attach/detach ordering can reconcile in the existing loop when the bracketed current relationship is stable. A relationship that changes inside the identity bracket rejects conservatively. Neither deadlines nor retry caps increase. Both detached and attached discovery retain the target subtree and previously discovered descendants. Callbacks omit only the candidate from helper counts, while the full snapshot retains global executable duplicate checks. Unexpected descendants, escaped groups and retained orphans still fail the existing role checks. Same-path exec guarantees are unchanged.

Deterministic mocked-kernel tests cover all three real callbacks and legacy entry, attached/detached states, snapshot ordering, target lifetime/path/device/group, worker and parent reuse, debugger changes within brackets, incoherent traced/parent state, missing metadata, publication ordering/schema/read bounds, descendants/global duplicates, denied reads, input and cutoff expiry. Preserved baseline observer plus the new correct-topology regression produces three `unexpected separate process group` errors. New code passes that regression. Original RED evidence and intermediate test failures remain in the private handoff.

This is source and headless regression evidence only. Full preparation remains stale. Independent review must precede any fresh preparation or authorized runtime attempt. No native, Simulator, GUI, LLDB, attach, capture, build, install or product acceptance was performed by this worker.

### Independent review and lifecycle corrections

Independent review reproduced two blockers in that implementation: publication compared transient running/sleeping state as identity, and the parent still required a live fixture while the worker restored state after terminating it. The lead corrected both before refreshing preparation.

Publication now compares PID/start/path/device/parent/traced fields explicitly. Both device reads must independently report running or sleeping. A stopped, zombie, traced or changed-identity second read still rejects.

At the existing safe cleanup boundary, the worker atomically publishes a separate `target-cleanup.json` containing the complete original observation binding and a fixed cleanup phase. The parent reads it with a 16 KiB bound, exact schema and exact owner/worker/target binding. The observer checks it during the current observation as well as later iterations. Cleanup intent grants no termination authority and cannot replace live target identity checks. The existing independent worker residual check still guards the actual termination and requires final reap before uninstall.

Only fresh target status ESRCH, `kill(pid, 0)` ESRCH, another status ESRCH, and the unchanged live parent-owned worker permit an absent target role. The full snapshot must also omit the target; another instance of its executable rejects. Zombies and denied/unknown reads remain pending within the original cutoff. A newly appearing cleanup phase can reconcile exit between kernel and device reads; a missing phase cannot. Helper counts, target-group orphans, discovered descendants, global duplicates, input checks and deadlines remain active.

The final headless suites pass 100 fixture, 65 SwiftUI, 23 lifetime, 17 product and 30 watchdog tests. New tests run the real parent loop through all three actual callbacks with mocked readers: live target, cleanup publication, confirmed exit while the worker remains alive restoring, and final successful worker receipt. They cover exit during a device read, zombie-to-gone, invalid phase bindings, unknown/denied reads, target/worker reuse, retained children, orphans, duplicate executables, input and cutoff. Intermediate test-fixture mistakes remain recorded separately from product failures. This establishes source/headless readiness only; it does not establish a successful SwiftUI runtime capture.

## Attempt13 뒤 worker 시작 경계 — 2026-11-10

Attempt13의 부모는 `Popen` 직후 launcher 경로를 worker authority로 저장했다. 나중에 worker는 `Python.app` runtime 경로를 게시했다. PID/start/parent/group은 같았지만 정확한 path 비교가 실패했다. 설치된 Xcode launcher의 disassembly는 framework에서 runtime 경로를 구하고 `POSIX_SPAWN_SETEXEC`로 전환하는 경로를 보여 준다. Attempt13의 정확한 exec 시점은 확인하지 못했다.

부모는 자신의 현재 kernel image를 예상 runtime으로 고정한다. 자식이 주장한 경로나 두 경로의 별칭 규칙으로 예상 image를 정하지 않는다. `workerLaunch`는 시작 증거로 남는다. `workerReady`와 `worker`는 별도 runtime binding이다. 시작 경계는 기존 3초 process-read 한도와 원래 admission/stop deadline 안에서만 기다린다. 부모는 소유한 직접 `Popen` 자식의 PID/start/parent/group을 유지하면서 예상 runtime으로의 단방향 전환만 허용한다. readiness metadata와 현재 kernel identity가 모두 일치해야 acknowledgement를 쓴다. worker는 owner/token, 부모 lifetime, 자신의 kernel lifetime과 acknowledgement를 다시 확인한 뒤 claim/install/launch에 진입한다. 이후 부모와 target 관찰은 runtime path까지 정확히 비교한다. 같은 path로의 모든 exec를 검출한다고 주장하지 않는다.

headless 검사는 fixture/session 102개, observer 30개, SwiftUI probe 36개가 통과했다. 세 process-budget callback 회귀를 포함한다. 기존 CLI 실행 테스트 3개는 단일 실제 시작 smoke 한도를 지키기 위해 제외했다. 별도 실제 smoke 한 번은 Xcode launcher에서 canonical 시작 helper를 실행했다. launcher→runtime 전환을 관찰했고 0.084초 뒤 자식 exit 0, reap 및 ESRCH를 확인했다. 이 검사는 prepared manifest, claim, device, AppKit, LLDB와 fixture를 사용하지 않았다. 배포 validator도 통과했다. 이것은 시작 binding 검증이며 SwiftUI hierarchy/Text/Shape capture 성공이 아니다. Preparation6의 과거 bytes는 보존했으며 현재 source admission은 stale이다. Runtime14와 준비 갱신은 실행하지 않았다.

Lead 검토는 정상 종료 경합도 재현했다. `poll()`이 실행 중을 반환한 직후 자식이 종료되면 새 identity 조회가 `ESRCH`를 반환할 수 있다. 이제 kernel `ESRCH`와 직접 소유한 `Popen` 자식의 종료 확인이 모두 있을 때만 관찰 루프를 끝낸다. 권한 거절과 아직 종료되지 않은 자식은 계속 실패한다. 이후 기존 종료 코드, worker receipt와 group cleanup 검사는 유지한다. 개인 임시 경로를 읽던 회귀 검사는 같은 경로 불일치를 만드는 모의 데이터로 교체했다.

최종 fixture/session 검사 106개가 Xcode Python에서 통과했다. 앞서 제외한 CLI 검사 3개도 포함한다. 이 경로는 `--guard`로 실행하며 mutation count 0, 부모·자식의 동일 deadline과 회수 결과를 검증한다. 정상 종료 경합의 RED와 수정 후 GREEN, 전체 로그는 비공개 검증 기록에 보존했다. 이 추가 검증도 Simulator 앱이나 SwiftUI 캡처를 실행하지 않았다.
