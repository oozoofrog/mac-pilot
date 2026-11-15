# 격리된 읽기 전용 probe의 프로세스 관찰

> Current status (2026-11-10): attempt 3/3 produced a candidate correction. Acceptance is incomplete. The latest appendix below supersedes the earlier topology claim; the earlier failure records remain historical evidence.

`session.probe()`는 고정된 CLI 실행 파일을 `start_new_session=True`로 시작한다. 기존 관찰자는 worker의 모든 자손을 수집한 뒤 worker group 밖의 자손을 무조건 거절했다. SwiftUI와 resident callback은 worker group만 계산했다. 따라서 이미 소유한 격리 probe가 상위 관찰에서 거절되거나 하위 예산에서 누락됐다.

수정 전 두 제어 테스트가 실제 `session.observe_processes()`와 SwiftUI callback을 통해 이 모순을 재현했다. 이 결과는 Attempt9의 거절 PID를 식별하지 않는다. Attempt9에 해당 행이 없으며, 별도로 기록된 ESRCH PID 67015를 원인으로 단정할 수 없다.

관찰자는 준비된 `session-probe`의 정확한 경로를 명시적으로 받는다. 별도 group은 worker의 직접 자식인 단일 probe만 허용한다. probe의 group은 probe PID와 같아야 한다. 그 group의 utility는 고정된 경로를 사용하며 probe의 직접 자식이어야 한다. 모든 관련 group의 probe와 utility 개수를 합산한다. SwiftUI, resident lifetime/product와 일반 fixture가 같은 관찰 계약을 사용한다. 기존 callback의 경로와 부모 관계 제한은 계속 적용된다.

새 group의 첫 관찰과 이미 관찰한 identity의 변경은 다르다. 이미 관찰한 PID의 start, parent, group 또는 path가 바뀌면 계속 거절한다. 짧은 `ps` 이름은 실행 파일 권한이 아니다. 부분 관찰에서 부모의 역할을 확정할 수 없으면 관계 판단만 보류한다. 최종 수락에는 새 완전한 identity가 필요하다. unknown, 종료, 관찰된 불일치를 구분한다.

불일치 진단은 거절 PID, 이전·현재 start/parent/group/path, 관찰 문맥과 cutoff를 예외 전에 보존한다. 이전 값이 없으면 null이다. 환경과 인자는 기록하지 않는다. 이 진단은 과거 실패 파일을 복구하지 않는다. 관찰은 신호, attach 또는 debugger 권한을 부여하지 않는다. 기존 직접 Popen 핸들 정리와 group readback을 유지하며 group kill fallback을 추가하지 않았다.

실제 Swift/AppKit 또는 Simulator 실행 파일 대신 유한한 plain C CLI stand-in을 한 번 실행했다. 기존 probe 경로와 실제 SwiftUI callback으로 별도 group과 직접 부모 관계를 확인했다. parent deadline은 25초이며 worker 1개, probe 1개, 직렬 ps utility 최대 1개를 선언했다. 약 2.63초에 정상 종료했다. probe의 group readback은 비었고 parent는 worker를 회수했다. 별도 utility 자식의 토폴로지와 여러 group의 합산 예산은 제어 identity 테스트로 검사했다.

최종 headless 검증에서 SwiftUI 64개, watchdog 28개, resident lifetime 23개, resident product 17개가 통과했다. 마지막 fixture 55개 중 기존 CLI guard 테스트 하나가 10초 timeout으로 오류를 반환했고 다른 하나는 exit 1을 반환했다. 의존 검사를 중단했으며 재시도하거나 timeout을 늘리지 않았다. 직전 소스에서는 fixture 55개가 통과했지만 이 결과로 마지막 실패를 대체하지 않는다. 마지막 수정은 진단의 없는 값을 null로 보존하고 이미 관찰한 group의 변경 회귀를 추가했다. 실패한 guard의 후손 전체 정리는 확인하지 못했다. timeout의 운영체제 원인도 확정하지 않았다.

이번 결과는 headless 소스 수정이다. 준비된 source pin은 변경한 파일에 대해 stale이다. 새 preparation, 실제 session-probe, SwiftUI 캡처, GUI, Simulator 조작, 제품 통합 또는 설치를 수행하지 않았다. 런타임은 FAILED9/9, 새 fixture lifetime은 0, 누적 lifetime은 6으로 유지한다. runner-time restoration만 기존 증거로 확인됐으며 현재 desktop equality는 증명하지 않는다. 제품 recording workflow 질문은 리드의 후속 작업으로 남는다.

## 리드 검증과 종료한 부모의 자손 보존 — 2026-11-10

리드는 실패했던 두 guard 검사만 같은 소스와 기존 10초 제한으로 계측했다. 임시 파일과 직접 자식 identity를 보존한 두 검사는 통과했다. 변경은 0건이었고 worker group은 비었으며 직접 자식을 회수했다. 이전 실패 원인과 그 당시 후손 전체의 종료는 이 결과로 증명하지 않는다.

독립 리뷰는 utility를 먼저 식별한 뒤 probe의 종료를 관찰하면, 최종 snapshot에서 부모가 제거되면서 살아 있는 utility까지 검사 대상에서 빠지는 결함을 재현했다. 리드는 최종 검사가 같은 관찰에서 이미 발견한 자손을 유지하도록 수정했다. 부모가 없는 별도 group의 utility는 이제 거절한다. 과거 부모 행이나 경로를 새 identity로 재사용하지 않으며, 신호 권한을 추가하지 않는다.

해당 회귀는 수정 전 실패하고 수정 후 통과했다. 독립 리뷰의 원본 재현에서도 정상 부모는 수락하고, 종료한 부모 아래의 살아 있는 utility·재부모화된 자식·깊이가 잘못된 자손은 거절했다. 현재 소스로 SwiftUI 65개, watchdog 28개, resident lifetime 23개, resident product 17개, fixture 55개가 모두 통과했다. fixture 검사는 실패 시 증거가 사라지지 않도록 임시 파일을 보존하고 직접 CLI 자식의 identity를 기록했다. 검사 조건과 시간 제한은 유지했다. 이 결과는 headless 검증이며, 이전 실패 기록과 런타임 FAILED9/9 상태는 유지한다.


## Complete read-only family correction, attempt 3/3 — 2026-11-10

This is a source/headless candidate, not a completed process-family qualification.
The last full integration run passed 207 of 208 tests. The canonical native binary
compiled and its dispatch guards passed, but the real observer expired before the
CLI entry was released to call `simulatorViewCaptureTarget`. No successful canonical
Foundation identity call, helper topology, or host-sentinel identity result was
observed. No unchanged failure was rerun and no deadline was extended.

### Source trace and bounded roles

`session.probe()` starts the exact prepared `session-probe --native-check` as a
direct child in a new session. It removes `MAC_CU_`, `DYLD_`, `PYTHON`, and
`FIXTURE_` environment variables, then sets `FIXTURE_DEVICE` and optionally
`FIXTURE_CAPTURE_RESULT`. In particular, it does not propagate the product
operation entry selector. The regular route is:

1. `bootedDevice` → `simulatorDevices` → Foundation `shell` → `xcode-select -p`.
2. `simulatorFrontPid` → the existing AX translation path; no source-level child launch.
3. `simulatorViewCaptureTarget` → unchanged private Foundation helper →
   `/usr/bin/xcrun python3 -I <prepared>/view-capture/capture.py --identity PID DEVICE`.
4. `displays` → Foundation `shell` → `xcrun devicectl device info displays …`.
5. Local bundle/display/window reads and JSON output. These include NSWorkspace and
   CoreSimulator/AX access in the real probe; the CLI proof deliberately bypasses them.

The Python `--identity` branch uses `ProcessProbe` kernel state/path/environment
reads. It does not invoke `tools_for_xcode`, create an LLDB worker, start a
supervisor/debugserver, or attach. The optional conversion route reads its supplied
capture result; it is not the regular Simulator/NSWorkspace route.

Let `W` be the worker, `P` its isolated probe, and `H` one serial helper root. The
following table describes the **candidate admission model**, not newly proven
Foundation runtime relationships:

| Role | Exact executable or bounded transition | Parent / group | Budget |
| --- | --- | --- | --- |
| Probe | `<prepared>/session-probe` | `W / P` | 1 |
| Identity launcher/helper | `/usr/bin/xcrun` → selected Xcode framework `bin/python3.x` → that framework's `Resources/Python.app/Contents/MacOS/Python` | `P / H`, where `H` is this child's PID | One serial helper root |
| Developer selection | `/usr/bin/xcode-select` | Direct probe child; own group admitted, inherited probe-group compatibility retained for fixed utilities | Same serial helper slot |
| Display wrapper/helper | `/usr/bin/xcrun` → `/bin/zsh` running the selected `Developer/usr/bin/devicectl` script → `/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl` | `P / H` | Same serial helper slot |
| Display version read | `/usr/libexec/PlistBuddy` with the fixed CoreDevice Info.plist version read | Display shell / `H` | At most 1 auxiliary child |
| Probe monitor | `/bin/ps -axo pid=,ppid=,pgid=,stat=,comm=` | `W / W` while the probe is observed | At most 1; may overlap the helper |

The selected Xcode currently resolves Python through `Python3.framework/Versions/3.9`.
Both its launcher and Python.app executable are named explicitly; another Python
path is not a read helper. Python and shell helpers require kernel-read arguments,
not `ps` names. The display shell requires the exact selected wrapper, command,
device UUID and output-name form. Its one auxiliary child requires the fixed
`PlistBuddy` version-read arguments. Extra helper roots, extra monitor/version
readers, unknown parents, wrong groups and deeper descendants are rejected.
Descendants cannot escape validation by appearing in the worker group.

The selected `devicectl` script expects CoreDevice `651.31`; the installed plist
also reports `651.31`. Its different-version branch invokes
`xcodebuild -runFirstLaunch`. That branch is not an admitted read-only descendant,
and observation does not promise to prevent a child from executing before it is
observed. The wrapper's actual shell/subshell/exec behavior remains unqualified.

There is no `/usr/bin/env` stage in the fixed native identity launch. The existing
worker's inventory/launch code may use `env`/`xcrun` and fixed utilities. Those
utilities retain their owning callback constraints and count against the shared
serial helper-root budget. This change does not grant arbitrary environment,
shell, or exec-transition authority. In particular, the selected `simctl` script
contains a separate bash/version-comparison pipeline; this patch does not newly
qualify that worker inventory subfamily or admit arbitrary bash/sort/head children.

### Observer and cleanup correction

The observer retains one complete acceptance cutoff. An identity/display helper must have fresh
full identity and exact role arguments, or a fresh terminal fact must resolve it.
Known parent constraints and the lead's discovered-descendant retention remain.
Unknown/expired reads do not become accepted cached identities. Start, parent and
group changes remain mismatches. Only a forward identity/display exec with an
already verified role and unchanged complete lifetime/parent/group can be
reconciled. A `ps` path change alone is only a candidate and cannot complete
acceptance. These transition cases have controlled headless evidence; the canonical
Foundation route did not produce runtime evidence in this attempt.

All three owning callbacks separate validated read helpers from debugger Python.
The aggregate helper count includes every admitted group. A read-identity Python
cannot consume or increase an LLDB worker or capture-supervisor allowance. Existing
product capture topology is not expanded by this read-only correction.

Probe-group readback alone was insufficient custody evidence for an own-group
Foundation child. `ProbeFamilyReadback` now retains discovered PIDs and groups,
records full identities or unknown/terminal observations, and reconciles the
retained family after the direct probe is reaped. Normal completion requires empty
observed groups and fresh ESRCH for every recorded PID. Abnormal probe completion
remains `ProbeCleanupUnknown`, even if sampled groups are empty: an unsampled
out-of-group child cannot be ruled out. It never grants descendant signal/reap or
PGID-kill authority. Direct Popen cleanup remains the only signalable handle.
The complete probe budget remains 25 seconds; work admission now reserves an
additional three seconds for family readback. Input/focus checks are unchanged.

### Evidence and limits of this attempt

The old finite C stand-in only slept/printed IDs. It did **not** execute Foundation
`Process`, selected Xcode Python, or the canonical `capture.py --identity` route.
It therefore did not prove the process family above. The earlier documentation's
stand-in success must not be used as that proof.

Attempt10's record rejects a Python.app PID with its own group, but does not pin
that row's start identity or its parent's executable/creator. It does not prove
that historical parent PID was the native probe. The new controlled regressions
reproduce the modeled gap through actual `session.observe_processes()` and all
three owning callbacks without retroactively identifying that historical process.

The new CLI proof compiles all current canonical Swift/Objective-C sources with a
generated guarded CLI entry and stages byte-identical current Python resources.
Its intended one call uses an owned, finite plain C sentinel with a test-authored
`SIMULATOR_UDID`; this would test host kernel environment reading, not actual guest
identity qualification. The production sources remain unchanged. Native binary,
source and staged-resource hashes are checked before proof execution. The Python
controller is pinned separately from the compiled native inputs.

The first guard execution stopped on an unknown read of the already identified
direct native child. Its cleanup was empty, but its exit code was not recorded.
That failure remains. The guard controller was corrected and controlled tests
proved that only fresh direct-child wait status can resolve such a read; unknown
descendants and expired acceptance still fail. With that changed controller, all
12 native dispatch cases, two sentinel guards, two Python worker guards and one
selected-Xcode query passed under their original five-second deadlines.

The subsequent proof expired the real shared observer's three-second cutoff before
writing the start marker. The native CLI entry then exited its five-second guarded
wait with code 65. `simulatorViewCaptureTarget` was never invoked, the identity
output was empty, and no Foundation identity-helper relationship was observed.
The real callback acceptance path was not reached in that proof. This is an
observation/pre-entry failure, not a successful call whose short helper escaped
sampling. Feasibility of the complete canonical call therefore remains unverified.

The worker reaped the native probe, then exited 1. The parent reaped that worker and
its one C sentinel. All recorded PIDs received fresh ESRCH and all recorded groups
were empty in the proof's cleanup and a subsequent independent reconciliation.
This does not change the failed proof or the worker's conservative cleanup-unknown
record. No further native execution followed.

| Last full affected run | Result |
| --- | --- |
| SwiftUI | 65 passed |
| Watchdog | 28 passed |
| Resident lifetime | 23 passed |
| Resident product | 17 passed |
| Fixture, including 20 new regressions | 74 passed, 1 existing CLI guard timeout (10 seconds) |

The failed fixture case is
`test_real_edit_guard_route_finite_deadline_and_no_mutation`. Its worker reported
zero mutations, but the owning CLI did not finish within the unchanged test limit.
The test was not rerun. Full raw logs, retained test directories, direct identities,
source hashes and later empty-group/ESRCH reconciliation are in the private handoff.
An earlier 205-test pass on the preceding candidate does not replace this failure.
Earlier intermittent `ps`/guard timeout causes remain unknown.

Final review then reproduced and corrected one deterministic comparison bug: a
scheduling-state change between identity reads was incorrectly compared as part of
an exec lifetime. The transition now compares only PID/start/parent/group/path and
the verified role. The 21 focused family/cleanup/guard regressions and the four
pure integration suites (65/28/23/17) passed on that final source. The failing fixture
CLI and the native proof were not rerun; their failures remain. These targeted
counts overlap the full-suite counts and must not be added as independent tests.

The last unit remains incomplete at attempt 3/3. The lead must review the candidate
and its unresolved observation/CLI failures before deciding on any fresh preparation.
This work provides source/headless evidence only. SwiftUI runtime remains
**FAILED10/10**; new Simulator fixture lifetimes are **0**, cumulative fixture
lifetimes remain **6**. There is no SwiftUI graph/pixel acceptance, no Simulator
capture, no LLDB attach, no GUI/input action, and no product installation or publication.


## 리드의 제한 시간·입력 확인 회귀 수정 — 2026-11-10

읽기 전용 검토에서 두 코드 결함을 확인했다. `probe()`는 사전 executable 검사 뒤에 12초 작업 제한을 다시 확인하지 않아, 이미 시간이 지난 뒤에도 자식을 시작할 수 있었다. 자식 시작 직전에 같은 제한을 확인하도록 수정했다. `rows()`는 전체 프로세스의 경로를 정규화하는 동안 입력과 관찰 cutoff를 확인하지 않았다. 각 항목 전후에 기존 checkpoint를 호출하도록 수정했다. 시간 제한이나 허용 프로세스 범위는 늘리지 않았다.

지연된 사전 검사와 경로 정규화 중 시간 만료·입력 발생을 재현한 세 제어 검사는 수정 전 실패하고 수정 후 통과했다. 현재 소스로 watchdog 30개, session 순수 검사 21개, probe family 21개, SwiftUI 65개, resident lifetime 23개와 product 17개가 통과했다. 이 177개 검사는 실제 native probe나 Simulator를 실행하지 않는다. 이전 fixture CLI timeout과 실제 Foundation 경로 미실행은 해결된 것으로 기록하지 않는다. 두 결함이 과거 지연의 원인이었다는 증거도 없다. 런타임 FAILED10/10과 관찰 규칙 수정 3/3 미완료 상태를 유지한다.


## Replanned advisory selector proof, attempt 4/4 — 2026-11-10

The lead explicitly reopened the same unit for one host CLI proof with a changed
advisory mechanism. Earlier failures remain unchanged. The advisory sampler now
uses typed `proc_listpids(PROC_PPID_ONLY/PROC_PGRP_ONLY)` selectors, retained PIDs
and groups, and fixed member/depth/query/time limits. It does not scan global PIDs
at 2 ms intervals. Unknown reads fail the proof; advisory data grants no role,
acceptance or signal authority. The authoritative global ps observer, callbacks,
role counts, executable inventory and original deadlines remain unchanged.

Exact native build inputs, binaries and staged Python resources matched. The
controller was separately pinned. Matching 12 native, 2 sentinel, 2 worker and
selected-Xcode guard receipts were reused after checking unchanged guard logic
and identity dependencies. No native build or guard launch was repeated.

The single proof failed after 0.862144 seconds. The advisory sampler retained an
EPERM status read for PID 73289, later ESRCH reads, and an IdentityChanged exception.
It did not establish that PID's executable or role. The real observer accepted
native root PID 73312 (parent 73288, group 73312, start [1794249072,10]) through
all three callbacks. Each callback ran four times. No identity-helper role was
accepted. The controller wrote the go marker; canonical output remained empty.
Actual Foundation/helper invocation therefore remains unresolved, not proven absent.

The parent reaped worker 73288 with exit 1 and sentinel 73287 with exit -15. The
worker reaped its direct native root with exit -15 and recorded an empty root
group. Parent terminal reads recorded ESRCH for 73287, 73288 and 73289. The worker
preserved unobservedDescendantsPossible=true. Independent post-run reconciliation
was not run after the original deadline. These receipts do not prove complete
unsampled-descendant custody or turn this failure into acceptance.

Compact controller trace: 368 events, 54062 bytes, no truncation/storage failure.
The authoritative ps read returned 2062 rows in 0.205716 seconds. No per-row
normalization or checkpoint trace was enabled. This does not explain the prior
latency failure. Raw failure, executed controller, source pins and trace are retained
privately in the attempt-4 handoff.

After the failed invocation, source-only tightening stops advisory sampling on its
first unknown, retains discovered PID/group sets even when a sample raises, caps
iterations at 7500, and checks advisory failure again before releasing go. These
changes were not run natively. No second proof is authorized or performed.
FAILED10/10 and six Simulator fixture lifetimes remain unchanged. No SwiftUI
capture, Simulator operation, GUI, LLDB, installation or production integration.

## 2026-11-10: 직접 자식의 종료 중 identity 조회

native identity 경로로 준비한 일반 읽기 전용 probe는 조회 JSON을 출력하고
종료 코드 0을 반환했다. 그러나 종료 직전의 프로세스 표본에서 실행 경로를
확인할 수 없어 `ProbeFamilyReadback.sample()`이 검사를 중단했다. 이후 직접
자식 reap과 빈 그룹을 확인했지만, 원래 실행의 전체 결과는 실패로 보존한다.

`sample()`은 identity 조회 직전에 아직 reap하지 않은 직접 자식인지 기록한다.
그 직접 자식의 identity가 불명확하면 `Popen.poll()`을 한 번 호출한다. 종료
코드 0을 얻은 경우만 `directReaped`로 기록한다. 이는 해당 직접 자식의 종료
증거다. 실행 중 identity 확인, 후손의 종료 또는 signal 권한을 대신하지 않는다.
이미 reap한 PID, 실행 중인 직접 자식, 비정상 종료 및 후손의 불명확한 identity는
계속 거절한다. 기존 cutoff와 최종 빈 그룹·발견한 PID의 ESRCH 검사를 유지한다.

수정 전 재현 실패와 수정 후 모의 회귀 통과를 확인했다. 현재 fixture 86개,
SwiftUI 65개, resident lifetime 23개, resident product 17개 및 watchdog 30개가
통과했다. 배포 구조 검사와 whitespace 검사도 통과했다. 이 소스 수정 후 실제
probe는 다시 실행하지 않았다. SwiftUI graph/Text/Shape 캡처와 제품 통합은 아직
검증되지 않았다. 이전 실패 횟수와 Simulator fixture lifetime 수는 변경하지 않았다.
