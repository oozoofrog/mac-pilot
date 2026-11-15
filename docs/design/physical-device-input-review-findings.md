# Physical device input 독립 리뷰

2026-11-14, 공유 `main` 작업 트리의 미커밋 변경 기준. 이 문서만 작성했다. 실기기 입력·조회·연결, GUI 실행, 설치 앱 변경, 커밋·푸시는 하지 않았다. 실행한 PhysicalDeviceLink selfcheck는 `--missing-runtime` 분기뿐이다.

아래 `S`는 `mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src`, `T`는 `mac-computer-use/tests`다. 줄 번호는 검토 당시 기준이다. **확인된 결함 5건(blocker 1, major 4), 실제 backend에서의 발생이 확인되지 않은 항목 1건**이다.

## 확인됨 (confirmed)

### 1. blocker — 잠금 확인 후 상태가 바뀌어도 숫자 키와 터치를 계속 보낸다

- 위치: `S/Device.swift:45`, `S/Device.swift:72`, `S/Device.swift:79`.
- 문제: lockState를 한 번 읽고 나서 최대 20초의 HID 연결 대기와 전체 입력을 진행한다. 연결 후나 긴 입력 도중에는 잠금을 다시 확인하지 않는다. `mac-cu never enters a passcode`라는 schema/오류 문구의 보장을 이 가드로는 지킬 수 없다. 화면 방향도 display 조회 이후 고정된 것으로 취급한다.
- 실패 시나리오: 허용된 폰이 잠금 해제 상태 → `type("123456")`의 lockState 검사 통과 → 연결 대기 중 사용자가 폰을 잠그고 암호 화면을 연다 → 동일 키 시퀀스가 암호 화면으로 전송된다. 긴 입력 중 자동 잠금도 같은 틈을 만든다.
- 확인: **모의 backend로 실제 DeviceTool을 컴파일·실행**했다. `locked`는 처음 false를 반환하고 `open`에서 true로 바꿨다. 전송기는 XPC 사전을 메모리에 기록할 뿐 기기에 연결하지 않았다. 아래 공통 빌드 명령의 `policy-probe.swift` 실행 결과:

  ```text
  lock race: checked=1 sends=12 whileLocked=12
  result: Submitted type to the device connection; delivery is not confirmed. Check the device screen for the result.
  ```

  잠긴 실제 iPhone에서 숫자가 암호 칸에 들어가는지는 실행하지 않았다. 확인된 것은 **잠금 전이 뒤에도 호스트 코드가 입력 전송을 허용한다**는 점이다.
- 수정: 연결 이후와 입력 도중에도 상태·취소를 검사하고 실패하면 중단해야 한다. 다만 호스트의 재조회만으로 원자적 보장은 불가능하므로, 암호 입력 금지를 엄격히 보장하려면 기기 쪽 잠금 상태에 묶인 입력 거부 기능을 사용하거나 그런 기능이 없는 경로의 입력을 제공하지 않아야 한다.

### 2. major — Swift existential 반환값의 소유권을 잃어 peer가 누수된다

- 위치: `S/PhysicalDeviceLink.swift:33`, `S/PhysicalDeviceLink.swift:38`, `S/PhysicalDeviceLink.swift:109`.
- 문제: 실제 async 함수의 소유권 있는 class-bound existential 반환값을 `UInt` 두 개로 받는다. `unsafeBitCast(result.object, to: AnyObject.self)`는 그 반환값의 +1 소유권을 소비하지 않는다. `PhysicalHIDLink`와 송신 closure가 정상 해제되어도 원래 반환 소유권이 남는다. 실패해서 `Mirror` 탐색 뒤 throw하는 경로도 동일하다.
- 실패 시나리오: 각 tap/swipe/key마다 새 peer 획득 → 요청 종료 및 500ms grace period 종료 → peer의 해제가 한 번 부족함 → 요청 수에 따라 peer와 peer가 보유한 연결·자원이 누적된다. 실제 Mercury 연결의 부수 자원이 얼마나 남는지는 측정하지 않았다.
- 확인: **기기와 무관한 Swift ABI 모형을 컴파일·실행**했다. 별도 `PeerABI` 모듈의 `Device.connection(_:) async throws -> any Peer`가 매번 새 객체를 반환하고, `Peer: AnyObject`, `deinit`은 출력한다. consumer는 제품과 같은 두 UInt struct 및 `@_silgen_name` 메서드 선언을 사용했다. 기본 빌드와 `-O` 모두 다음 출력이었다:

  ```text
  typed begin
  peer init
  typed peer held
  peer deinit
  typed end
  raw begin
  peer init
  raw peer held
  raw end
  ```

  소비 코드는 `let result = try await device.connection("fake"); let peer = unsafeBitCast(result.object, to: AnyObject.self); withExtendedLifetime(peer) { print("raw peer held") }`였다. throwaway consumer만 `Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(bitPattern: result.object)!).takeRetainedValue()`로 바꾸면 `raw peer held` 뒤 `peer deinit`이 나타났다. 원본 소스는 변경하지 않았다.
- 수정: 지원 ABI의 owned 반환 규약을 확인한 shim에서 소유권을 정확히 한 번 인수하고, 성공·추출 실패·timeout 뒤 완료 경로 모두 해제되게 한다. 객체 생성/해제 횟수를 비교하는 모의 ABI 회귀 검사를 추가한다.

### 3. major — devicectl timeout이 서버의 무한 대기를 막지 못한다

- 위치: `S/Device.swift:90`, `S/Device.swift:104`, `S/Device.swift:140`; 직접 사용하는 기존 helper는 `S/Simulator.swift:684`.
- 문제: 새 backend는 모든 devicectl 호출의 상한을 `shell(..., timeout: 18)`에 의존한다. 이 helper는 기한에 SIGTERM 한 번만 보내며, 그 뒤에도 stdout EOF와 `waitUntilExit()`를 무한 대기한다. SIGTERM을 처리하지 못하는 프로세스나 stdout을 가진 자손이 남으면 18초를 넘어선다. helper 자체는 기존 코드지만 새 장치 오류 처리에서도 그대로 발생한다.
- 실패 시나리오: devicectl이 장치 오류로 멈추고 SIGTERM에 종료되지 않음 → `device list`/screenshot/input의 사전 조회가 복귀하지 않음 → 직렬 `handleQueue`의 뒤에 있는 모든 MCP 요청도 대기한다.
- 확인: **실제 shell 선언을 추출·컴파일**하고 SIGTERM을 무시하는 Python 자식을 실행했다. `shell(..., timeout: 0.2)`에 바깥 2초 watchdog을 적용했다. 결과:

  ```text
  FAIL: shell(timeout=0.2) still blocked after 2.0s
  cleanup:  exit -9
  ```

  부모 watchdog이 이 프로브 전용 프로세스 그룹을 SIGKILL로 정리했다. 실제 devicectl 장애를 유발한 검사는 아니다.
- 수정: 기한 후 짧은 종료 유예와 SIGKILL, 소유 자손 정리, 파이프 읽기 종료까지 포함하는 bounded subprocess runner를 사용한다. 단순 `--timeout 15` 옵션이나 SIGTERM만으로 서버 가용성을 보장하지 않는다.

### 4. major — 제한 없는 type이 전체 서버를 장시간 점유하고 취소·release도 처리하지 않는다

- 위치: `S/Device.swift:61`, `S/Device.swift:66`, `S/Device.swift:79`; 호출 맥락은 `S/Daemon.swift:194`, 키당 지연은 `S/Simulator.swift:67`, `S/Simulator.swift:161`.
- 문제: text 길이나 총 작업 시간 제한이 없으며 모든 chord를 동기 루프에서 전송한다. `currentSession.requestCancelled`도 확인하지 않는다. 요청 실행은 공용 직렬 큐이고 `release`도 같은 큐를 거치므로 진행 중 입력을 중단할 수 없다.
- 실패 시나리오: 허용된 폰에 소문자 ASCII 10,000자를 type → 문자당 최소 key-down/up 각 15ms, 합계 약 300초 동안 전체 도구 큐 점유 → 클라이언트 취소·연결 종료·release 요청 후에도 나머지 문자를 계속 시도한다. 중간에 폰을 분리해도 루프의 종료 조건은 바뀌지 않는다.
- 확인: **읽기 전용 추적**. `sed -n '53,85p' "$S/Device.swift"`, `sed -n '67,73p;161,164p' "$S/Simulator.swift"`, `sed -n '185,213p' "$S/Daemon.swift"`에서 무제한 `for chord in chords`, 두 번의 `usleep(15_000)`, `handleQueue.async` 실행 및 별도 취소 수신을 확인했다. 5분 입력이나 실제 장치 전송은 실행하지 않았다.
- 수정: 입력 길이·전체 deadline을 제한하고 chord 사이에 세션 취소, 연결 오류와 정책 상태를 검사한다. 중단 시 누른 키의 해제를 시도하고 미전송·부분 전송을 구분해 반환한다.

### 5. major — selfcheck의 실기기 연결 옵션은 이름만으로 다른 폰을 선택할 수 있다

- 위치: `T/physical-device-link-selfcheck.swift:23`.
- 문제: `--open-<기기 이름>`은 UUID를 인자로 받지 않고 `name == "<기기 이름>" && connectionState == "Connected"`인 첫 항목의 HID 연결을 연다. 연결 매체 확인과 UUID allow가 없다. dictionary에서 나온 목록의 first 순서도 안정적 선택 기준이 아니다.
- 실패 시나리오: 로컬 네트워크에 같은 이름의 다른 폰이 Connected로 보이거나 원래 USB 폰이 분리됨 → selfcheck 옵션 실행 → 다른 폰의 HID 서비스를 연다. 이 분기 자체는 입력 메시지를 보내지는 않는다.
- 확인: **읽기 전용**, `nl -ba "$T/physical-device-link-selfcheck.swift"`의 23–24행에서 이름 기반 first 선택과 즉시 `openHID(identifier:)` 호출을 확인했다. 이 옵션은 실행하지 않았다.
- 수정: 연결 검사는 명시한 UUID만 허용하고, 이름은 표시용으로만 사용한다. 승인한 전송 매체 등의 조건도 별도로 확인하며, 일반 headless selfcheck와 실기기 연결 검사를 분리한다.

## 의심되지만 실제 backend에서 미확인 (suspected, not confirmed)

### 6. minor — 송신기가 false를 반환해도 제출 성공 문구를 돌려주는 경로

- 위치: `S/Device.swift:74`, `S/Device.swift:85`; `S/Simulator.swift:67`, `S/Simulator.swift:93`.
- 문제·시나리오: HIDLink.transmit이 실제로 두 메시지를 거부해도 key/touch/button이 Bool을 버려 DeviceTool은 `Submitted tap`을 반환한다. 이는 delivery 확인 여부와 다른, 로컬 전송 시도 실패다.
- 확인: **모의 전송기로 컴파일·실행**한 policy probe에서 `send`가 false를 반환하도록 했다. 출력은 `send failure: rejected=2`, 결과 문구는 `Submitted tap to the device connection; delivery is not confirmed. Check the device screen for the result.`였다.
- 미확인 이유: 현재 실제 PhysicalHIDLink.send의 false는 dlsym 실패뿐이고, open 단계에서 같은 기호를 미리 검사한다. 따라서 일반적인 실제 backend에서 이 false 경로가 도달 가능한지는 입증하지 못했다. 기기 분리 시 RemoteXPC의 void send가 어떤 오류를 내는지도 실측하지 않았다. 이 모의 결과를 실제 unplug 재현으로 해석해서는 안 된다.
- 수정: 전송 실패를 상위로 전달해 미제출/부분 제출 오류로 보고하고, 실제 연결 종료 통지를 안전하게 관찰할 수 있는지 별도로 검증한다.

## 실행 근거와 재현 구성

모든 생성 소스·바이너리는 `eyebuild dir physical-input-review`로 만든 빌드 디렉터리에만 두고 검토 후 `eyebuild rm physical-input-review`로 제거했다. 아래는 실행 명령의 변수와 핵심 부분이다. throwaway probe 소스는 보존하지 않았으므로 재실행하려면 위에서 설명한 모형을 먼저 생성해야 한다.

```sh
D=/Volumes/eyedisk/build/mac-pilot/physical-input-review
S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
T=mac-computer-use/tests
export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache" PYTHONDONTWRITEBYTECODE=1
```

- **기존 DeviceTool selfcheck**: `T/device-tool-selfcheck.swift` 헤더의 stubs 추출·컴파일 명령을 위 D로 실행. 출력: `device selfcheck passed: allow, pinning, lock, validation, HID recorder, missing CoreDevice`.
- **정책 프로브**: 같은 빌드에서 마지막 selfcheck 소스만 `"$D/policy-probe.swift"`로 교체하고 `-o "$D/policy-probe"`로 컴파일 후 실행. backend.list는 무작위 UUID 하나의 Connected 항목, display는 200×400, screenshot은 빈 문자열, open은 XPC dictionary를 쓰는 외부 HIDLink를 반환한다. allow 이후 숫자 type의 lock 전이와 false 송신 tap을 실행했다. 결과는 발견 사항 1·6에 기록했다.
- **HID transport selfcheck**: Simulator.swift의 HIDLink 선언을 추출하고 AppKit/XPC/IOKit import를 붙인 `hid-check-source.swift`를 생성했다. `swiftc -parse-as-library "$D/hid-check-source.swift" "$S/SimulatorGestureHID.swift" "$T/hid-transport-selfcheck.swift" -o "$D/hid-selfcheck"` 후 실행. 출력: `HID transport golden and external message checks passed.`
- **ABI 모형**:

  ```sh
  swiftc -parse-as-library -emit-library -emit-module -module-name PeerABI "$D/abi-provider.swift" -emit-module-path "$D/PeerABI.swiftmodule" -o "$D/libPeerABI.dylib"
  swiftc -parse-as-library "$D/abi-consumer.swift" -I "$D" -L "$D" -lPeerABI -Xlinker -rpath -Xlinker "$D" -o "$D/abi-consumer"
  "$D/abi-consumer"
  ```

  consumer shim 기호는 `$s7PeerABI6DeviceC10connectionyAA0A0_pSSYaKF`였다. typed 비교 호출은 provider 안의 별도 함수로 분리했다. consumer에 `-O`를 추가한 실행 및 소유권을 인수한 throwaway 변형도 비교했다.
- **subprocess 모형**: 실제 `struct ShellResult`부터 `struct SimulatorScreen` 직전까지 추출하고 Foundation import와 `@main` 진입을 붙였다. `swiftc -parse-as-library "$D/shell-probe.swift" -o "$D/shell-probe"`. 진입은 `shell(CommandLine.arguments[1], [CommandLine.arguments[2]], timeout: 0.2)`를 호출했다. 자식은 `signal.signal(signal.SIGTERM, signal.SIG_IGN); print('child ready', flush=True); time.sleep(60)`이고, Python 부모는 `Popen(..., start_new_session=True)`, `communicate(timeout=2)`, finally의 `os.killpg(pid, SIGKILL)` 및 `communicate()`로 정리했다.
- **framework 부재**: PhysicalDeviceLink.swift와 physical-device-link-selfcheck.swift를 native_build.py와 같은 CoreDevice weak framework/rpath 플래그로 컴파일했다. `physical-selfcheck --missing-runtime`은 명시적 missing-runtime 오류를 반환했다. `nm -m`에서 shared/devices/description/connection/async Tu 모두 `weak external`, `otool -L`에서 CoreDevice `(weak)`를 확인했다. 실행 파일 사본의 CoreDevice load command를 `install_name_tool -change`로 `/nonexistent/CoreDevice.framework/CoreDevice`로 바꾸고 사본만 ad-hoc 재서명한 뒤 `--missing-runtime`을 실행해도 정상 오류를 반환했다. 출력: `missing runtime: CoreDevice unavailable: /Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice`. 실제 Xcode 미설치 Mac이나 전체 daemon 실행 검사는 아니다.
- **배포 검사**: `PYTHONDONTWRITEBYTECODE=1 python3 scripts/validate_distribution.py`는 exit 1. 범위 밖 `docs/design/simulator-debugger-lifetime-decision.md`의 기존 임시 HANDOFF 파일 링크에 대해 `AssertionError: ('Broken local link', ...)`가 발생했다. 이 리뷰에서 고치지 않았다.

## 검토했으며 별도 결함을 확인하지 못한 부분

- production의 UUID 선택/allow/pin/release 순서와 실기기 iPhone 필터: 이름은 선택에 쓰이지 않는다. allow는 문구대로 서버 프로세스 전체에 적용되며 세션별 권한은 아니다.
- simulator 경로는 CoreSimulator에서 연결을 얻고, 물리 경로는 별도 전송 closure를 사용한다. 기존 기본 HIDLink 전송의 메시지/barrier/closed 검사와 GestureHIDLink의 simulator 분기는 변경 전과 같은 흐름이다. golden 검사는 인코딩 확인에 유효하지만 실제 simulator 연결이나 barrier 동작 검사는 아니다.
- device dispatch는 AX 권한 요청 경로를 우회하고, 외부 HIDLink/GestureHIDLink는 simulator 터치 overlay와 connection 재설정·cancel을 피한다. 검토한 입력 경로에서 Mac 이벤트 게시나 앱 활성화 호출은 찾지 못했다. 외부 라이브러리 내부 동작까지 보장한 결과는 아니다.
- 서버의 `handleQueue`는 직렬이다. 현재 production 호출 맥락에서 allowed의 동시 변경 race 또는 main-thread semaphore deadlock은 찾지 못했다. Task 결과는 성공한 semaphore 대기 뒤 읽는다.
- Weak-link 및 누락 기호 사전 검사, 지원 ABI의 class-bound descriptor 확인, 유한·범위 내 좌표와 duration, 정상 devicectl 실패의 JSON/error 분기, UUID 임시 캡처 파일의 defer 제거에는 위 항목 외 확정 결함이 없다.
- live harness와 Python driver는 명시 UUID를 고정하고 이름·모델·유선 연결 조건을 추가 확인한다. 문서의 HID 결과 문구는 전달 확인을 주장하지 않으며, 초기 관찰과 뒤의 입력 follow-up을 구분한다. 기록된 과거 실측의 진위나 재현성은 이번 리뷰에서 확인하지 않았다.

## 평가하지 못한 부분

- 실제 기기의 연결 거부, unplug 중 동작, locked/landscape 전이, 키보드 레이아웃, 버튼 전달, Mac 비간섭, simulator 실동작 회귀. live harness/driver는 실행하지 않았다.
- 다른 Xcode/OS/아키텍처에서의 private Swift ABI, Mercury 저장 프로퍼티 구조와 RemoteXPC C ABI. 모의 async 호출은 현재 컴파일러/아키텍처의 반환·소유권 검증이지 모든 private ABI의 검증이 아니다.
- HID 연결 timeout 뒤에도 Task를 취소하지 않는 코드는 확인했다(`Device.swift:147–148`). 실제 CoreDevice 요청이 끝없이 남는지, 나중에 성공했을 때의 부수 효과는 재현하지 못했다.
- 기존 selfcheck는 잠금 전이, 실제 subprocess 실패·timeout, 실제 RemoteXPC 단절·peer 해제를 검증하지 않는다. 전체 앱을 실행하지 않았으므로 framework 없는 환경의 모든 기존 기능 유지까지 확인한 것은 아니다.

## 처리 결과 (2026-11-14)

| 발견 | 처리 | 확인 |
| --- | --- | --- |
| 1. 잠금 확인 후 전송 | 연결을 연 뒤 전송 직전에 잠금 상태를 다시 읽고, 잠겼으면 아무것도 보내지 않는다. `type`은 호출당 200자로 제한한다. 호스트에서는 원자적으로 막을 수 없어, 재확인 이후 한 호출이 끝날 때까지(최대 약 10초)의 틈은 남는다. | `device-tool-selfcheck`의 late lock 검사: 연결 중 잠기면 전송 0건 |
| 2. peer 소유권 누수 | 반환된 peer의 소유권을 `takeRetainedValue()`로 한 번 인수한다. | 시험용 실기기의 HID 연결을 입력 없이 8회 열고 닫아 중단 없이 종료. 해제 횟수 자체는 측정하지 않았다 |
| 3. devicectl 시간 초과 | `shell`이 SIGTERM 2초 뒤에도 살아 있는 자식을 SIGKILL한다. 자손이 출력 파이프를 붙잡는 경우는 여전히 막지 못한다. | SIGTERM을 무시하는 자식으로 `timeout: 0.5` 호출이 2.7초에 반환 |
| 4. 긴 `type`과 취소 | 200자 제한, 키 사이에 요청 취소를 확인하고 제출한 키 수를 오류로 돌려준다. | `device-tool-selfcheck`의 length cap, cancel 검사 |
| 5. 이름으로 연결하는 selfcheck 옵션 | `--open <UUID> [횟수]`로 바꿨다. 이름으로는 연결하지 않는다. | 위 8회 실행에 사용 |
| 6. 전송 실패 무시(미확인) | 보류. 실제 backend에서 도달하는 경로가 확인되지 않았다. 연결 단절을 관찰할 방법이 생기면 함께 처리한다. | — |

수정 후 전체 타입 검사와 selfcheck 4개(device-tool, physical-device-link, hid-transport, gesture-hid)가 통과했다.
