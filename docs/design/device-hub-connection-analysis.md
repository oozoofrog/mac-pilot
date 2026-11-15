# Device Hub의 iPhone 연결·화면·입력 경로 분석

2026-11-14, macOS 27.2(26B123) / Xcode 27.2(27B48) / Device Hub 27.2(255.30.5) / CoreDevice 651.31.

Xcode의 Device Hub가 iPhone에 연결하고 화면을 보여 주고 조작하는 방법을 바이너리에서 직접 읽었다. 정적 분석만 했다. Device Hub를 실행하지 않았고, 어떤 프로세스에도 붙지 않았고, 기기에 아무 요청도 보내지 않았다.

## 판정

| 질문 | 판정 |
| --- | --- |
| 1. 연결 | Device Hub는 "연결" API를 부르지 않는다. 기기 화면을 여는 동안 **사용 assertion 하나**를 쥐고, CoreDeviceService가 그 요청을 받아 RemotePairing의 터널 assertion으로 터널을 올린다. 기존 추정이 맞다 |
| 2. 클라이언트↔서비스 | CoreDeviceService가 소켓을 열어 fd를 넘기고, 클라이언트 쪽 CoreDevice가 그 fd로 RemoteXPC 연결을 만들어 **핸들러 설정·활성화까지 한 뒤** 기기·기능별로 보관한다. 기존 추정이 맞다 |
| 3. 화면 | USB·네트워크 구분 없이 미디어 스트림 하나다. 프레임은 avconferenced가 Core Animation 슬롯에 그리고, Device Hub는 그 슬롯을 `CALayer`의 내용으로 붙인다. Device Hub 프로세스도 픽셀 버퍼를 받지 않는다. USB 캡처는 쓰지 않는다 |
| 4. 입력 | 터치·키보드·포인터는 **UniversalHID 서비스에 HID report**로, 버튼은 **`remote.hid.button`에 `IndigoButtonEvent`** 로, 스크롤은 `remote.hid.scroll`로 보낸다. Device Hub는 digitizer 기능(`remote.hid.digitizer`)을 쓰지 않는다. mac-cu의 버튼·키 경로를 고쳐야 한다 |
| 5. 권한 없는 화면 경로 | Device Hub 안에 스크린샷 반복 방식의 화면 보기는 없다. 화면은 미디어 스트림뿐이다. 상태는 `deviceInfo` 변경 스트림에서 얻는다 |

## 근거를 얻은 방법과 한계

- **REA 6.8.0(MCP)**: `open_binary`, `inspect_macho`로 대상 식별과 Mach-O 구조를 얻었다. 디컴파일 provider는 이 MCP 세션에서 쓸 수 없었다(`provider_missing`). `inspect_signature`는 임시 사본에 대한 codesign 실패로 끝나서 권한은 셸의 `codesign`으로 읽었다.
- **디스어셈블**: `xcrun llvm-objdump -d --no-show-raw-insn <바이너리>` 전체 출력에 주석을 붙이는 스크립트를 만들어 썼다. `nm -n`의 기호, `dyld_info -fixups`의 바인딩으로 `bl` 대상 스텁의 import 이름, `adrp+add`·`adrp+ldr`가 가리키는 문자열·GOT 항목·async 함수 포인터를 해석하고 `swift-demangle`로 이름을 푼다. 이 방법으로 호출 명령을 직접 본 것만 "디스어셈블"로 적었다. 기존 조사에서 실패했던 objdump는 `--macho` 없이 주소 범위나 전체 섹션으로 부르면 동작한다.
- **Ghidra 12.2 headless**(조사 도중 설치됨): `analyzeHeadless`와 함수 범위를 디컴파일해 파일로 내보내는 GhidraScript를 직접 실행했다. 공유 캐시 안의 AVConference는 Ghidra의 `DyldCacheFileSystem`으로 이미지 하나만 꺼낸 뒤 `-loader MachoLoader -noanalysis`로 들여와 기호 이름으로 고른 함수만 디컴파일했다(자동 분석을 돌리지 않아 ObjC 선택자 스텁 이름은 풀리지 않는다). DeviceKit과 CoreDevice는 자동 분석까지 돌렸다.
- **REA 6.9.0 CLI + Ghidra provider**: 결론의 근거가 되는 함수 넷(화면 슬롯 연결 둘, 서비스 소켓 생성, 터널 assertion 요청)을 `rea decompile --provider ghidra`로 디컴파일해 Evidence ID를 남겼다. Ghidra를 직접 실행해 얻은 의사코드에는 Evidence ID가 없고 주소로만 가리킨다.
- **메타데이터**: import 표(`dyld_info -imports`), 기호 표, 문자열, ObjC 클래스·ivar 이름, 권한(`codesign -d --entitlements`), launchd plist.
- 한계
  - 이름이 지워진 내부 함수(`redacted function N`)가 많다. 그런 함수는 주소와, 그 안에서 참조하는 로그 문자열·호출 대상으로 식별했다.
  - Swift async 함수는 여러 조각으로 나뉘고 공통 코드가 `_OUTLINED_FUNCTION_n`으로 빠져 있다. 조각 사이의 순서는 로그 문자열과 연속 주소로 판단했고, 분기 조건까지 모두 따라가지는 않았다.
  - 정적 분석은 실행을 관찰한 것이 아니다. "호출 명령이 있다"와 "그 경로가 이 기기에서 실제로 실행된다"는 다르다. 실제 실행 여부가 중요한 항목은 "실행 관찰이 필요한 것"에 따로 적었다.
  - 기기 쪽(iOS) 바이너리는 보지 않았다.

근거 종류 표기: **디컴파일**(Ghidra 의사코드), **디스어셈블**(명령을 직접 확인), **메타데이터**(import·기호·문자열·권한), **추정**, **미확인**.

## 대상 바이너리

Device Hub 앱의 실행 파일은 작고, 로직은 Xcode의 `SharedFrameworks/DeviceKit.framework`에 있다.

| 바이너리 | 경로 | sha256 |
| --- | --- | --- |
| DeviceHub | `/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub` | `b2d716b7eed8076a5d862d8ff70a2fdf919c56502b6994702bcf5f1370bac85b` |
| DevicesTrampoline(번들 실행 파일) | `…/DeviceHub.app/Contents/MacOS/DevicesTrampoline` | `59039ff41933366927882122b14899eb13efb156d556ed9978ee3b89f7fb344e` |
| DeviceKit | `/Applications/Xcode.app/Contents/SharedFrameworks/DeviceKit.framework/Versions/A/DeviceKit` | `49ce0cdfb9a3dc4a4a9fcb1cc6ce10639ed12a5eda5fda599e6475367c864492` |
| CoreDevice | `/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice` | `00bf7055ace3517b0e4c03b12a462eeabed02a17da0b0cc4951e3bd3e56eb48a` |
| CoreDeviceUtilities | `/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities` | `105f6cf36845f796e9d7a9a43563e676c7e9a28a6d39837cd4b8178637d757c2` |
| CoreDeviceService | `…/CoreDevice.framework/Versions/A/XPCServices/CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService` | `a145f8a1500a38dbe034152efd0654982c1cd04744880ae0de145018425318ab` |
| CoreDeviceMediaStreamSupport | `…/CoreDevice.framework/Versions/A/Frameworks/CoreDeviceMediaStreamSupport.framework/Versions/A/CoreDeviceMediaStreamSupport` | `fae3c290f7b23930b826a8f034d889c968f9f8d5676fc5282517fc9da3c2a040` |
| UniversalHID | `…/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID` | 앞 16자리 `6131ca15248f0ec6` |
| devicectl | `…/CoreDevice.framework/Versions/A/Resources/bin/devicectl` | `1a6771cf8829c3acbb556e1585204992c47cc33388850bdf3bf3645677fc8715` |
| Mercury(arm64e 조각) | `/Library/Apple/System/Library/PrivateFrameworks/Mercury.framework/Versions/A/Mercury` | `d9640d0edafddd2dd1e11401ecc0a953168f282ceae9c89abc83952666f5fc95`(universal 파일) |
| CoreDevicePopDeviceKitExtension(플러그인) | `…/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/MacOS/…` | 앞 16자리 `0f66a76b8f194dcc` |
| AVConference | dyld 공유 캐시 안 `/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference` | UUID `D57227F5-F343-3547-A231-A822508F77CA` |

REA Evidence: DeviceHub `inspect_macho` `ev_ba6339c1e777d2afe1527254b55ce36a8fa3d9ecff98cc4a9fa922d1b85f2289`(요약 보기 `ev_f393a497827d474244fcbf600590e35ee858672ac2bccb70dc2f00a38b69e285`), DeviceKit `inspect_macho` `ev_4e7a39077090790ed92c51a278cb96122d9821ef0ee2b5876b3d0167eac7b053`(요약 보기 `ev_407a024969daff5d4b7a711a44eecd69d815a46f7ab578c3c8cb4823b39da676`). 디컴파일 Evidence는 각 표에 적었다.

아래 주소는 파일 안의 가상 주소다(DeviceKit·CoreDevice·CoreDeviceMediaStreamSupport는 0 기준, CoreDeviceService는 `0x100000000` 기준, AVConference는 공유 캐시의 unslid 주소).

## 1. 연결

| 주장 | 근거 종류 | 근거 |
| --- | --- | --- |
| Device Hub 실행 파일은 CoreDeviceService 연결과 복구 불가 상태 핸들러만 직접 다룬다 | 메타데이터 | DeviceHub import: `CoreDeviceService.sharedConnection`, `CoreDeviceServiceConnection.eventManager`, `EventManager.registerUnrecoverableServiceConnectionStateHandler(on:handler:)` |
| 기기 목록은 `DeviceManager(serviceConnection:allowedDeviceVisibilityClasses:)`, `awaitFullInitialization()`, `devices`, `deviceChanges`, 기기별 `deviceInfoChanges`·`capabilityChanges`로 유지한다 | 메타데이터 | DeviceKit import 표(참조 수 2·1·14·4·7·2) |
| DeviceKit은 터널을 여는 "연결" API를 가져오지 않는다. 가져오는 것은 페어링(`RemoteDevice.pair(handlingPINChallengesUsing:)`, `PairingChallenge.answer(withPIN:)`, `unpair()`)과 사용 assertion뿐이다 | 메타데이터 | DeviceKit import 표 전체에서 `RemoteDevice.`·`DeviceManager.` 항목을 나열해 확인. `connect`·`tunnel` 이름의 CoreDevice 함수 import 없음 |
| `ObservedDevice.usageAssertion(reason:requiredDeviceStates:)`는 `UsageAssertionRequirements(deviceStates:capabilities:)`(capabilities는 빈 집합)를 만들어 `RemoteDevice.acquireDeviceUsageAssertion(withReason:requirements:)`를 부른다 | 디스어셈블 | DeviceKit `0x72423c`–`0x7245b8`. `0x724534` `_swiftEmptySetSingleton` 적재, `0x72453c` `bl UsageAssertionRequirements.init`, `0x72454c` async 함수 포인터 적재, `0x7245b8` `b acquireDeviceUsageAssertion`. 앞뒤 로그 "Getting usage assertion." / "Got usage assertion." |
| 기기 화면을 다루는 `DeviceInteractionModel.acquireUsageAssertion()`이 요구하는 상태는 `developerModeEnabledIfRequired`, `coreDeviceServicesLoaded`, `extendedDeviceInfoLoaded`, `remoteServiceDiscoveryTrustedConnectivityAvailable`, `secureNetworkingAvailable`이고 이유 문자열은 `"DeviceKit.DeviceInteractionModel"`이다 | 디스어셈블 | DeviceKit `0x52074c`–`0x520798`의 다섯 getter 호출, `0x5207dc` 이유 문자열, `0x520864` `b ObservedDevice.usageAssertion`. 앞의 넷은 항상 넣고(`0x520770`에서 집합 생성), `secureNetworkingAvailable`은 `0x52077c`의 판정 함수(`0x5101ac`)가 거짓일 때만 넣는다(`0x520780` `tbnz`). 그 판정의 내용은 미확인 |
| 얻은 assertion에 무효화 핸들러를 건다 | 디스어셈블 | DeviceKit `0x521040` `bl DeviceUsageAssertion.registerInvalidationHandler(invokingOnQueue:handler:)`. 직전 로그 "Acquired usage assertion: %s" |
| assertion의 수명은 별도 태스크(`manageUsageAssertionLifecycle()`)가 관리한다. 기기의 `acquireUseAssertion` capability 유무와 연결 상태·부트 상태를 관찰해 잡고 놓는다 | 디스어셈블 + 메타데이터 | DeviceKit `0x4cce68`("Usage assertion lifecycle task already running."), `0x51fcec` `Capability.acquireUseAssertion`, `0x51f970` 로그 "acquireUseAssertion capability %d → %d; capabilities=…, connectionState=…, bootState…", ivar `usageAssertionLifecycleTask`·`_usageAssertionState`, `UsageAssertionState` case `none`/`acquired(assertion, acquiredAt)`/`failed(Error)` |
| 무효화되면 원인을 셋으로 나눠 기록한다: 기기가 실행 중이 아님 / 오류와 함께 무효화 / 해제됨. 파괴적 작업(복원 등) 때문일 수 있다는 분기도 있다 | 디스어셈블(문자열 참조) | DeviceKit `0x5230c8` "Invalidation handler fired for assertion %s — error=%s, state=%s", `0x524510`, `0x524630`, `0x524768`, `0x524824` |
| 다시 얻는 것은 타이머가 아니라 관찰 값의 변화다. 수명 태스크는 모델의 다섯 값(상호작용 요청 유무, 일시 중지 여부, `acquireUseAssertion` capability 유무, assertion 보유 여부, 카운터 하나)을 `Observations`로 관찰하고, 바뀔 때마다 `shouldAcquire`/`shouldRelease`를 다시 계산한다 | 디컴파일(Ghidra) + 디스어셈블 | 입력 클로저 DeviceKit `0x51fadc` 의사코드: 모델 접근자 둘 → `ObservedDevice.capabilities`에 `Capability.acquireUseAssertion` 포함 여부 → `UsageAssertionState`의 case가 0(`acquired`)인지 → 결과 구조체에 기록. 루프 `0x51dbf4`–`0x51fadc`: `0x51fad8` `Observations.Iterator.next`, 로그 "Observation yielded — shouldAcquire: %d, shouldRelease: %d, hasInteractionRequests: %d, isSuspended: %d, hasCapability: %d, hasAssertion: %d". 무효화로 보유 값이 바뀌면 루프가 다시 돈다는 것은 이 구조에서 나온 추정이고, `shouldAcquire`의 정확한 식은 추출하지 못했다 |
| 화면을 닫거나 상호작용을 멈추면 `releaseAssertion()`으로 놓는다 | 디스어셈블 | DeviceKit `0x4ce4a0`(`releaseUsageAssertion(reason:)`, 로그 "Releasing usage assertion (reason: %s)"), `DeviceUsageAssertion.releaseAssertion()` dispatch thunk 호출 다수 |
| 화면 보기 외의 작업(앱 설치·정보 조회 등)도 "assertion 획득 → 작업 → `releaseAssertion()`" 형태다 | 디스어셈블 | `ObservedDevice.usageAssertion` 호출 지점 8곳 이상(`0x7e7cc`, `0x83c94`, `0x1acfbc`, `0x1b257c`, `0x215858`, `0x23b024`, `0x26d350`, `0x270a80` …)과 짝이 되는 `releaseAssertion()` 호출. `remoteServiceDiscoveryTrustedConnectivityAvailable` getter 참조 63곳 |
| CoreDeviceService는 assertion 요청을 받으면 RemotePairing에 터널 assertion을 요청한다 | 디컴파일 + 디스어셈블 | CoreDeviceService `0x10003f3d0` "Received request to create usage assertion %s for device %s, (required deviceStates=…, owning pid=%d, reason=%s", `0x100023704` "Requesting tunnel assertion for %s for assertion %s", `0x10015f304` `bl ConnectableDevice.createTunnelUsageAssertion(invokingHandlerOnQueue:assertionHandler:)`, `0x10015a334` `bl TunnelUsageAssertion.registerInvalidationHandler`. 디컴파일(REA 6.9.0 CLI, Ghidra 12.2) Evidence `ev_110b839f444d583dde2c0c1024c60746bcff5ed010455dfb36c73f1316b68cd2`(`0x10015eb6c`)에서 `RemotePairing::ConnectableDevice::_createTunnelUsageAssertion` 호출 확인 |
| assertion이 하나도 없으면 터널을 내린다 | 메타데이터 | CoreDeviceService 문자열 "The tunnel was disconnected because no outstanding usage assertions were held."(`0x1001608c0`에서 참조), "Releasing assertion %s for device %s as required preparedness is no longer satisfied (required = %s, actual = %s)" |
| 요구 상태에 따라 서비스가 단계별로 진행한다: 전원 assertion → 개발자 모드 확인 → DDI 서비스 활성화 → 확장 기기 정보 → 클라이언트 통지 | 메타데이터 | CoreDeviceService 문자열 "Not acquiring a power assertion … as it was not requested in required device states. Proceeding to developer mode enablement" 등 단계별 문구 |
| 기기 화면 자동 시작은 정책 함수가 정한다. 자동 시작을 끈 설정이면 시작하지 않고, 동작 값 0은 항상 시작, 1은 시작하지 않음, 그 밖에는 기기 종류(`DeviceReality`)와 전송 방식(`TransportType`)으로 정한다 | 디스어셈블 | DeviceKit `LiveDeviceActivation.Policy.shouldAutoStart(behavior:reality:transportType:disableAutoStart:)` `0x586b10`–`0x586b3c`. 나머지 경우를 정하는 `0x58822c`는 전송 방식을 `TransportType.cloud`와만 비교하고(`0x588354`), 기기 종류가 `DeviceReality.physical`이면 거짓을 돌려준다(`0x588450`–`0x588460`). `wired`와 `localNetwork`를 가르는 비교는 없다. 즉 실기기 화면은 사용자가 시작해야 열린다(트리거 `userStartedScreenSharing`) |
| 터널이 끊겼을 때 Device Hub가 따로 다시 연결하는 코드 | 미확인 | assertion 무효화 핸들러와 capability 관찰 외에 터널 상태를 직접 다루는 호출은 찾지 못했다. `tunnelState`는 정보 표시(인스펙터)에만 쓰인다(문자열 `info.inspector.tunnel.state.visible`) |

남은 것: 네트워크 기기에서 assertion 없이 `getImplementation`·`xpcConnection`을 부르면 서비스가 터널을 자동으로 올리는지는 CoreDeviceService의 각 액션 구현을 모두 봐야 하고, 이번에 보지 않았다.

## 2. 클라이언트와 CoreDeviceService의 역할

| 주장 | 근거 종류 | 근거 |
| --- | --- | --- |
| `RemoteDevice.xpcConnection(forFeatureIdentifiedBy:)`는 전역 `ActionConnectionCache.shared`의 `getOrCreateConnection(to:forFeatureIdentifiedBy:)`로 넘어간다 | 디스어셈블 | CoreDevice `0x33b24`→`0x33b48`, `0x33b8c` async 함수 포인터 적재, `0x33bf8` `b 0xc8c8` |
| 캐시는 기기·기능별 연결 사전(`xpcConnections`), 만드는 중인 연결(`inFlightConnections`), 잠금(`xpcConnectionsLock`)을 가진다 | 메타데이터 | CoreDevice ObjC ivar 이름, 연관 타입 `ActionConnectionCache.…Key` |
| 캐시에 없으면 새로 만들고, **CoreDevice가 이벤트 핸들러를 설정하고 활성화한다** | 디컴파일 + 디스어셈블 | CoreDevice `0xdde4` "Creating new XPC connection to device %s for feature %s.", `0xe4b8` `bl XPCPeerConnection.setEventHandler`, `0xe4e4` `bl XPCConnection.activate()`. 디컴파일(Ghidra, `0xe34c` 조각)에서도 캐시와 연결을 약하게 잡은 클로저를 만든 뒤 `XPCPeerConnection::_setEventHandler()` → `XPCConnection::activate()` 순서 |
| 그 핸들러는 오류가 오면 캐시에서 연결을 뺀다. 예상 밖 메시지는 무시한다 | 디스어셈블 | CoreDevice `0x128bc` "Error on remote XPC connection to device %s, discarding connection: %s", `0x12eac` `ActionConnectionCache.removeCachedXPCConnection(_:toDeviceIdentifiedBy:)`, `0x12db4` "Unexpected XPC message on remote XPC connection to device %s, ignoring: %s" |
| 기기가 끊기면 그 기기의 연결을 모두 버린다 | 디스어셈블 | `removeAllCachedXPCConnections(forDeviceIdentifiedBy:)` 호출 3곳: `0x407fb4`(같은 함수에 "Remote device disconnected: %s"), `0x12fc14`, `0x1b3730` |
| 연결 생성은 액션 `com.apple.coredevice.action.createservicesocket`을 CoreDeviceService로 보내 `XPCFileDescriptor`를 받고, 복제한 fd로 `xpc_remote_connection_create_with_connected_fd`를 부르는 것이다 | 디스어셈블 | CoreDevice `ActionBasedDeviceCapabilityImplementation<CreateServiceSocketActionDeclaration, CreateServiceConnectionCapability>.remoteXPCConnection(toFeatureIdentifiedBy:…)` `0x2bd48c`, `0x2bd274` `bl XPCFileDescriptor.duplicate()`, `0x2bd308` `bl _xpc_remote_connection_create_with_connected_fd` |
| CoreDeviceService는 입력의 `serviceName`/`featureIdentifier`로 서비스를 찾아 `remote_service_connect_socket`으로 소켓을 연결하고 fd를 돌려준다 | 디컴파일 + 디스어셈블 | CoreDeviceService `0x1000512c8`: `0x100051354` `Input.serviceName`, `0x1000513f0` `Input.featureIdentifier`, `0x100051664` `bl _remote_service_connect_socket`; `0x100052d8c` `XPCFileDescriptor.init(fileDescriptor:closeWhenDone:)`, `0x100052db8` `Output.init(fileDescriptor:remoteXPCVersionFlags:featureIdentifiers:)`; 로그 "Connected socket to '%s' (fd=%d); returning to client". 디컴파일(REA 6.9.0 CLI, Ghidra 12.2) Evidence `ev_f7460d1eb3fd4266e8027bf16feabc1c74d9e1bed1cccdfadb5e2daec2792795`: `Input::_get_serviceName` / `_get_featureIdentifier` → `OS_remote_service::_get_features` → `_remote_device_get_xpc_remote_connection_version_flags` → `_remote_service_connect_socket(…)`. 이 함수 안에는 audit token·권한 조회 호출이 없다(그 앞 단계의 요청 분배 코드는 보지 않았다) |
| 기능 식별자는 RSD 서비스의 속성 `CapabilityFeatureIdentifier`와 맞춰 찾는다 | 메타데이터 | 같은 구현 안의 문자열 `"CapabilityFeatureIdentifier"` |
| 이 경로에서 호출 프로세스의 권한을 이름으로 검사하는 코드는 찾지 못했다 | 메타데이터(범위 한정) | CoreDeviceService·CoreDevice·CoreDeviceUtilities 문자열에서 권한 이름은 `com.apple.private.CoreDevice.takeDeviceSysdiagnose`, `…obtainContainerAccess`뿐. 기존 조사에서 권한 없는 프로브가 digitizer 연결을 받은 실측과 일치 |
| 이벤트 전송은 응답을 기다리지 않는다 | 디스어셈블 | CoreDevice Indigo 인코더 네 곳과 `0x297510`이 모두 `XPCConnection.send(message:)`를 부른다(`0x297730`, `0x297950`, `0x297b70`, `0x297d90`) |
| **barrier는 응답을 기다리는 동기 전송이다.** `HIDXPCService`의 barrier 함수는 `isBarrier`(Bool) 필드 하나만 담은 사전을 만들어 `XPCConnection.sendSync(message:)`를 부른다 | 디스어셈블 | CoreDevice `0x29de84`: `0x29dfc0` `XPCDictionary.init()`, `0x29dfc4` `messageIsBarrierFieldName`, `0x29dfe0` Bool 설정, `0x29dff4` `bl XPCConnection.sendSync(message:) throws -> XPCDictionary`. 호출자 `0x29e404`(HIDXPCService), `0x29b43c`(universalhidservice 쪽) |
| 기기가 보낸 오류는 `errorContainer` 필드로 온다 | 디스어셈블 | CoreDevice `0x295350`, `0x295b64`, `0x296424`의 `errorFieldName` 사용(연결별 수신 처리) |

mac-cu의 수명 규칙에 대한 판정:

- **넘겨받은 연결에 이벤트 핸들러를 설정하지 않는다 — 맞고, 이유가 확인됐다.** CoreDevice가 이미 자기 핸들러를 걸었고 그 핸들러가 오류 때 캐시를 비운다. 덮어쓰면 죽은 연결이 캐시에 남는다.
- **반환된 peer의 소유권을 한 번 인수한다 — 유지.** 함수는 `Mercury.XPCPeerConnection`을 돌려주고 캐시는 자기 참조를 따로 가진다.
- **우리 참조를 놓아도 연결은 닫히지 않는다 — 확인.** 캐시가 강하게 보관한다. 닫히는 때는 연결 오류, 기기 끊김, 프로세스 종료다.
- **마지막 이벤트 뒤 500 ms 유지 — 대체할 수 있다.** 프로세스가 살아 있는 동안에는 캐시가 연결을 유지하므로 참조를 붙잡고 기다릴 이유가 없다. 이벤트 전송이 비동기라 전달 완료를 알아야 할 때(프로세스 종료 직전, 다음 스크린샷 직전)는 시간 대기 대신 **barrier**(`{isBarrier: true}`를 응답 대기로 전송, 형 있는 API로는 `HIDDigitizer.sendBarrier()`)를 쓸 수 있다. 기기가 barrier에 응답하는 시점이 "앞선 이벤트 처리 뒤"인지는 기기 쪽 구현이라 실기기 확인이 필요하다.

## 3. 화면

| 주장 | 근거 종류 | 근거 |
| --- | --- | --- |
| Device Hub의 화면 공급자는 미디어 스트림(AVC)과 VNC 둘이다. iPhone 화면은 미디어 스트림이다 | 메타데이터 | DeviceKit 타입 `DisplayViewFramebufferProviderAVC`, `DisplayViewFramebufferAVC`, `AVConferenceVideoStreamHelper`, `AVConferenceVideoStreamManager`, `AVCVirtualExternalDisplay`, `VNCDisplayViewFramebufferProvider`(ScreenSharing의 `SSSessionView` 사용). VNC 공급자가 어떤 기기에 쓰이는지는 보지 않았다 |
| 시작 전에 기기가 보낼 수 있는 스트림을 묻는다 | 디스어셈블 | DeviceKit `0x4ca870`, `0x5d3954`, `0x5d412c`, `0x5d48b0` `MediaStreamSupport.deviceCanSend(_:)`; import `MediaStreamSupportedFeatures.primaryDisplayMirroredOutput`·`videoOutputByDisplayID`·`systemAudioOutput` |
| `MediaStreamSession(clientSessionID:)`을 만들고, 설정에 **자기 `CALayer`** 를 넣어 `makeVideoStream(withConfiguration:fromRemoteDevice:)` → `activate()`를 부른다. 끝낼 때 `invalidate()` | 디스어셈블 | DeviceKit `AVConferenceVideoStreamHelper.init(device:clientSessionID:)` `0x5c35a4`(`0x5c399c` 세션 생성), `0x5c3e84` `makeVideoStream`, `0x5c4058` `activate()`, `0x5d5bc4` `VideoStreamConfiguration.receiveMirroredDisplayByIdentifier(_:layer:timeout:)`, `0x5c9ca8` `receiveVirtualExternal(layer:resolution:timeout:)`; `receiveMirroredPrimary(layer:timeout:)`도 import |
| CoreDeviceMediaStreamSupport는 협상기를 만들어 offer를 얻고 `StartRequest`에 담아 `startMediaStream(with:)`을 부른다 | 디스어셈블 | `0x13de8` `-[AVCMediaStreamNegotiator initWithMode:options:error:]`, `0xf774` `offer`, `0x1f05c` `DeviceMediaStream.StartRequest.init(timeout:type:direction:negotiatorOffer:clientSupportedFeatures:…)`, `0x1f0e8` `b MediaStreamFunctions.startMediaStream(with:)` |
| 응답의 answer를 협상기에 넣고 `AVCVideoStream`을 만들어 시작한다 | 디스어셈블 | `0x141cc` `setAnswer:withError:`, `0x16f48` `-[AVCVideoStream initWithNetworkSockets:options:error:]`, `0x17cb0` `setVideoStreamMode:`, `0x18260` `setDelegate:`, `0x18270` `start` |
| 스트림 토큰으로 `AVCRemoteVideoClient`를 만들고, 그 클라이언트에서 **슬롯 번호**를 얻어 `[CAContext objectForSlot:]`의 결과를 레이어의 `contents`로 넣는다 | 디컴파일 + 디스어셈블 | `0x57678` `-[AVCRemoteVideoClient initWithStreamToken:delegate:]`, `0x57a90` `slotForMode:`, `0x57ab8` `unsignedIntValue`, 로그 "Found videoSlotNumber: %u.", `0x58570` `objectForSlot:`(`CAContext` 클래스), `0x58588` `setContents:`; ivar `VideoStreamReceiveHelperAVC.layer`·`.remoteVideoClient`. 디컴파일(REA 6.9.0 CLI, Ghidra 12.2)에서도 `AVCRemoteVideoClient::initWithStreamToken_delegate_` → `slotForMode_(client, 0)`, `CAContext::objectForSlot_(…)` → `setContents_(layer, …)` 순서 확인: Evidence `ev_f3db9618b7758c6e425534f6d3dcdf5806e8f0e8976925c3f6bd20fef9fb2050`(`0x571bc`), `ev_5c00bfbad4a7d6b7880e9b02add2231f4a7c37e0c0fea714f05f0173ac9847fb`(`0x584d0`) |
| 따라서 디코딩된 프레임은 Device Hub 프로세스로 오지 않는다. 렌더 서버 슬롯을 레이어에 붙일 뿐이다 | 추정(위 호출에서 도출) | DeviceKit·CoreDeviceMediaStreamSupport에 `IOSurface`·`CVPixelBuffer`·`CMSampleBuffer` import 없음(플러그인 `CoreDevicePopDeviceKitExtension`만 `IOSurfaceCreate`를 가져오며 iPhone 화면 경로와 무관한 별도 기기용) |
| 방향·비율은 스트림 속성에서 받는다 | 메타데이터 | DeviceKit import `VideoStreamAttributes.orientation`·`contentsRect`·`ratio`·`scaleFactor`; 델리게이트 셀렉터 `remoteVideoClient:remoteVideoAttributesDidChange:` |
| USB와 네트워크의 화면 경로는 같다. USB 캡처는 없다 | 메타데이터 + 디스어셈블 | DeviceHub·DeviceKit·플러그인의 링크 목록과 import에 AVFoundation·CoreMediaIO·ScreenCaptureKit 없음. DeviceKit 전체에서 `TransportType` case 참조는 기기 목록 표시(`0x1547b4`), 다른 표시 상태(`0x55cb48`), 자동 시작 정책뿐이고 화면 공급자 코드(`0x5be000`–`0x5d6000`)에는 없다 |
| 영상 스트림을 받는 쪽은 사용자 에이전트 avconferenced다 | 메타데이터 | `/System/Library/LaunchAgents/com.apple.avconferenced.plist`의 mach 서비스 `com.apple.videoconference.camera`·`.avconference` 등 |
| 권한 검사 함수는 audit token으로 `SecTask`를 만들고 권한 값을 읽어 불리언 참인지 본다 | 디컴파일 + 디스어셈블 | AVConference `+[AVConferenceXPCServer(XPCManagement) entitlementStatusForToken:]` `0x1C0A8DA8C`: 토큰 32바이트 복사 → 호출 → 실패 시 cold 경로("Failed to create SecTask from audit token") → CFString `0x1E6F043E0`(길이 44, `com.apple.videoconference.allow-conferencing`의 길이와 같음)과 오류 포인터를 넘겨 호출 → 타입 ID 비교 → 값 1이면 상태 1, 아니면 2. 디컴파일(Ghidra)에서 이 함수가 참조하는 문자열이 `"com.apple.videoconference.allow-conferencing"`임을 확인 |
| 연결을 받을 때 상대의 audit token으로 권한 상태를 구하고, 구하는 중 오류면 연결을 무시한다 | 디컴파일(Ghidra, 선택자 스텁 이름은 미해석) | AVConference `-[AVConferenceXPCServer(XPCManagement) _xpc_handle_incoming_request:]` `0x1C0A8DBB8`: 토큰 32바이트를 스택에 복사 → 클래스 객체와 토큰 주소를 넘기는 메시지 전송 → 결과가 0이면 로그 "Process %s (PID=%d) encountered error while checking entitlement=%s, ignoring connection"(인자 문자열이 위 권한 이름). 호출되는 선택자가 `entitlementStatusForToken:`이라는 것은 인자 형태와 바로 앞에 놓인 그 메서드로 판단한 추정 |
| 메시지마다 서비스별로 등록된 **authorization 블록**을 부르고, 거짓이면 처리하지 않는다 | 디컴파일(Ghidra) | 같은 메서드의 블록 `0x1C0A8E01C`: 등록된 블록을 (이름, 오류 출력, 권한 상태 …) 인자로 호출 → 결과의 최하위 비트가 0이면 로그 "API name=%@ failed authorization check error=%@, entitlementStatus=%ld". 등록 API는 `registerBlockForService:block:queue:eventLogLevel:authorizationBlock:allowablePublicAPIs:` |
| 영상 스트림 서비스의 authorization 블록이 권한 상태 1을 요구하는지 | 미확인 | 그 블록을 등록하는 쪽(스트림 서비스 초기화)은 보지 않았다. 권한 없는 프로세스의 실제 거절 응답도 관찰하지 않았다 |

## 4. 입력

Device Hub의 입력은 `HIDManager`가 이벤트 큐로 모아 보낸다. 큐의 이벤트 종류(`HIDManager.HIDEvent`)는 `report(HIDReport, HIDServiceID)`, `button(Int, Int, HIDButtonState)`, `scroll(ScrollPoint, ScrollPhase, ScrollMomentum, ScrollTarget)`, `createService(HIDServiceDescriptor)`, `removeService(HIDServiceID)`, `reset(HIDServiceID)`다(메타데이터: enum case 기호).

| 입력 | Device Hub가 부르는 API | CoreDevice 구현과 전송 | 근거 종류 |
| --- | --- | --- | --- |
| 터치 | Mac의 마우스·트랙패드 이벤트를 `IOHIDEventCreateDigitizerEvent`/`…FingerEvent`로 만들고 `UniversalHID.DigitizerFilter.filterEvent`로 HID report로 바꾼 뒤 `UniversalHIDService.send(report:to:)`. 대상은 `HIDServiceID.touchscreen(displayID:)` | 기능 `com.apple.coredevice.feature.remote.universalhidservice`(클래스 `DDIUniversalHIDService`) | 디스어셈블: DeviceKit `0x4974b0`·`0x4974e4`(이벤트 생성), `0x4ac84c`(전송); CoreDevice `0x29a794`(기능 문자열) |
| 키보드 | 같은 report 경로(`HIDServiceID.mainKeyboard`). 메뉴 명령 등 일부는 `HIDKeyboard.send(key:state:)` | `UniversalHIDKeyboard`: `UniversalHIDService.primaryKeyboard()`로 서비스를 찾아 키보드 이벤트를 report로 보낸다. 없으면 `hidDeviceNotAvailable` | 디스어셈블: DeviceKit `0x7c2a8`, `0x7d1e8`; CoreDevice `0x2a3934`, `0x2a3b10`, `0x2a3ae0` |
| 버튼(홈·전원·음량 등) | `HIDButton.sendCustomButton(usagePage:usageCode:state:)`(큐 경로), `HIDButton.sendButton(page:code:state:)`(33곳) | `IndigoHIDButton`: `IndigoButtonEvent(usagePage:usageCode:state:)`를 `XPCObjectEncoder`로 인코딩해 `{featureIdentifier, messageType: "IndigoButtonEvent", payload}` 사전으로 `XPCConnection.send(message:)`. 기능 `com.apple.coredevice.feature.remote.hid.button` | 디스어셈블: DeviceKit `0x4abe40`; CoreDevice `0x29eccc`·`0x29efc4`(이벤트 생성), `0x297560`–`0x297730`(인코딩·전송), `0x29e78c`(기능 문자열) |
| 스크롤(디지털 크라운 등) | `HIDScroll.send(point:phase:momentum:target:)` | `IndigoHIDScroll`, `"IndigoScrollEvent"`, 기능 `…remote.hid.scroll` | 디스어셈블: DeviceKit `0x4ac350`; CoreDevice `0x297d4c`, `0x2a0b4c` |
| 제스처 상태 초기화 | `UniversalHIDService.resetGestureState(service:)` | universalhidservice | 디스어셈블: DeviceKit `0x4acd04` |
| HID 서비스 준비 | `connectedServiceDescriptors()`, `createService(descriptor:)`, `remove(service:)`. 실패하면 간격을 늘려 재시도 | universalhidservice | 디스어셈블: DeviceKit `0x4a4628`, `0x4ad218`, `0x4ad960`, 로그 "Failed to get available HID services from %s: %s. Retrying in %llds." |

그 밖의 확인 사항:

| 주장 | 근거 종류 | 근거 |
| --- | --- | --- |
| DeviceKit은 digitizer capability를 가져오지 않는다. 가져오는 HID capability는 `.hid.button`, `.hid.scroll`, `.hid.keyboard`, `.universalHidService`다 | 메타데이터 | DeviceKit import 표. CoreDevice는 `.hid.digitizer`·`.pointer`·`.vendorDefined`도 내보내지만 DeviceKit에는 참조가 없다 |
| CoreDevice에는 digitizer용 Indigo 구현이 따로 있다: `IndigoHIDDigitizer`, 메시지 `"IndigoDigitizerEvent"`(`pointOne`, `pointTwo`, `eventType`, `edge`, `target`), 기능 `…remote.hid.digitizer`, 그리고 `sendBarrier()` | 디스어셈블 + 메타데이터 | CoreDevice `0x29790c`, `0x29f2b4`; 기호 `HIDDigitizer.send(pointOne:pointTwo:eventType:edge:target:)`, `HIDDigitizer.sendBarrier()`. barrier의 전송 방식은 2절의 `0x29de84` 참조 |
| CoreDevice의 기본 구현 표에는 `IndigoHIDButton`, `IndigoHIDDigitizer`, `IndigoHIDScroll`, `UniversalHIDKeyboard`, `UniversalHIDPointer`가 등록돼 있다. **키보드의 Indigo 구현은 없다** | 디스어셈블 | CoreDevice `CoreDeviceCapabilityImplementations.baseDeviceCapabilityImplementations` 초기화 `0x3c6b04`: `0x3c703c`, `0x3c7054`, `0x3c706c`, `0x3c70e4`, `0x3c70fc`의 메타데이터 접근자 호출 |
| 분석한 어떤 바이너리에도 `IndigoKeyboardButtonEvent`라는 문자열이 없다. 있는 것은 `IndigoButtonEvent`, `IndigoDigitizerEvent`, `IndigoScrollEvent`, `IndigoVendorDefinedEvent` 넷이다 | 메타데이터(범위: 대상 표의 바이너리) | `strings` 전체 검색 |
| 메시지 필드 이름은 `featureIdentifier`, `messageType`, `payload`, `isBarrier`, `errorContainer`다 | 디스어셈블 | CoreDeviceUtilities `HIDXPCServiceEvent.*FieldName` getter `0x2a8730`–`0x2a87c0`의 즉시값 문자열 |
| 버튼 usage 값: 홈 = Consumer(0x0C) 0x40, 전원(`sleepWake`=`power`) = 0x30, 음량 올림 0xE9, 내림 0xEA, Siri(`watchSideButton`과 같은 값) = 0x95. Telephony 페이지는 0x0B, Apple 키보드 벤더 페이지는 0xFF01 | 디스어셈블 | CoreDevice getter `0x3a07bc`, `0x3a0768`(←`0x3a0a4c`), `0x3a0780`, `0x3a078c`, `0x3a07c8`, `0x3a0760`, `0x3a07d4`, `0x3a07e8` |
| Device Hub가 가져오는 버튼 코드는 `home`, `sleepWake`, `volumeIncrement`, `volumeDecrement`, `siri`, `eject`, `watchSideButton`, 키보드 벤더 페이지의 `userDefined1`이다 | 메타데이터 | DeviceKit import 표 |
| `remote.universalhid`(서비스 없는 옛 이름)는 capability 식별자로만 존재하고 Device Hub 경로에서는 `universalhidservice`를 쓴다 | 메타데이터 | CoreDeviceUtilities 문자열에 둘 다 있음. CoreDevice 코드가 참조하는 것은 `…remote.universalhidservice`(`0x29a794`, `0x29aa58`) |
| Device Hub는 응답이나 확인을 기다리지 않는다. barrier를 쓰는 digitizer API를 가져오지 않기 때문이다. 큐가 가득 차면 이벤트를 버린다 | 디스어셈블 + 메타데이터 | 이벤트는 `send(message:)`. DeviceKit import에 `sendBarrier` 없음. DeviceKit `0x4aa134` "HID queue at capacity (%ld), dropping %s", ivar `HIDManager.EventSender.maxQueueDepth` |
| HID 준비는 기기에 `universalHIDService` capability가 있을 때 시작하고, 사라지면 서비스를 무효화한다 | 디스어셈블 | DeviceKit `0x4a0674`, `0x4a41c0`, 로그 "HID capabilities became available, initializing HID services" / "HID capabilities lost, invalidating services" |
| 회전: 기기를 돌리는 것은 `OrientationControl.rotate(direction:)`·`changeDeviceOrientation(_:)`(기능 `…remote.devicecontrol.orientation`, 클래스 `BackBoardOrientationControl`). 화면 배치는 스트림의 `VideoStreamAttributes.orientation`과 `DisplayInfo.orientation`으로 다시 계산한다 | 메타데이터 + 디스어셈블 | DeviceKit import, 로그 "nativeDeviceOrientation: %s, videoHelper.videoOrientation: %s, currentRotation: %s…", "Unable to rotate device. Orientation lock enabled."; CoreDevice `0x294a70` |
| 잠금: Device Hub는 잠금 상태 API를 부르지 않는다. 시도가 실패한 뒤 그 오류를 "잠긴 기기에서 실패함" 상태로 기억하고 안내문을 띄운다 | 메타데이터 | DeviceKit에 `LockState` 계열 import 없음. `DeviceState.KnownCondition.deviceLockedOnPriorAttempt(Error)`·`.microphoneOrCameraActive(Error)`, 문구 "Make sure the device is unlocked, connected, and its screen is on, then try again.", import `CoreDeviceError.mediaStreamSensorInUse`·`mediaStreamInterruptedBySensorActivity`. 어떤 오류 코드를 잠금으로 분류하는지는 미확인 |

## 5. 서드파티 클라이언트에 쓸 수 있는 것

| 주장 | 근거 종류 | 근거 |
| --- | --- | --- |
| Device Hub에는 스크린샷을 반복해 화면을 보여 주는 방식이 없다 | 메타데이터 + 디스어셈블(범위 한정) | `captureScreenshot(displayUniqueID:)` 참조는 5곳이고 저장·클립보드 기능(`ScreenCaptureClipboardWriter`, 설정 `saveCapture`)에 속한다. 화면 공급자 타입은 AVC·VNC뿐 |
| 디스플레이 정보는 `displayInfoUpdates()`가 아니라 `deviceInfo[.displayInfo]`와 `deviceInfoChanges`로 받는다 | 메타데이터 | DeviceKit import: `DeviceInfoFieldDescriptor.displayInfo`(20곳), `RemoteDevice.deviceInfoChanges`(7곳), `DisplayInfoProtocol.displayInfo`(2곳). `displayInfoUpdates` import 없음 |
| 화면 녹화는 기기가 파일을 만들어 넘기는 별도 경로다 | 메타데이터 | DeviceKit import `ScreenRecordingProtocol.recordScreen(displayUniqueID:)`, `ScreenRecordingHandle.stopRecording()`, `ScreenRecording.videoData: Data`. 실시간 프레임이 아니고, 기존 조사에서 iPhone은 이 capability를 지원하지 않는다고 응답했다 |

Device Hub의 권한과 그것이 필요한 코드:

| 권한 | 필요한 곳 | 근거 종류 |
| --- | --- | --- |
| `com.apple.videoconference.allow-conferencing` + mach 조회 예외 `com.apple.videoconference.camera` | 화면 스트림 수신(`AVCVideoStream`, `AVCRemoteVideoClient`). avconferenced의 요청 처리에서 검사 | 디컴파일(검사 함수·요청 처리부). 스트림 서비스의 조건은 미확인 |
| `com.apple.private.hid.client.event-filter`, `…event-monitor`, TCC `kTCCServicePostEvent`·`kTCCServiceListenEvent` | **Mac 쪽** 키보드·포인터 이벤트를 가로채 기기로 넘기는 기능(`HIDServiceClient`, `SystemHIDServiceLookup.hidSystemClient`, `InputCaptureModel`, `SecureKeyboardInput`). 기기와의 통신에는 필요 없다 | 추정(타입·ivar 이름과 import `_OBJC_CLASS_$_HIDServiceClient`) |
| mach 조회 예외 `com.apple.remoted` | 샌드박스 안에서 RSD에 닿기 위한 것 | 추정 |
| `com.apple.private.coredevice.client` | 미확인. CoreDevice·CoreDeviceService·CoreDeviceUtilities·DeviceKit·RemotePairing·remoted·avconferenced의 문자열에 이 이름이 없다 | 메타데이터(범위 한정) |
| `com.apple.private.CoreDevice.takeDeviceSysdiagnose`, `com.apple.private.sysdiagnose` | sysdiagnose 수집. CoreDevice가 이름으로 검사 | 메타데이터 |

입력 경로(연결 생성과 HID 전송)는 Device Hub의 권한에 의존하지 않는다. 화면 스트림만 권한에 막힌다.

## 기존 조사 문서 대비

[physical-device-remote-research.md](physical-device-remote-research.md)의 추정 항목별 결과.

| 기존 문서의 서술 | 결과 | mac-cu에 미치는 영향 |
| --- | --- | --- |
| "권한을 가진 CoreDeviceService가 RSD 서비스에 소켓을 연결해 fd를 넘기고 클라이언트가 그 fd로 RemoteXPC 연결을 만든다"(추정) | **확인.** 양쪽 호출을 모두 봤다. 액션 이름은 `createservicesocket` | 변경 없음 |
| "CoreDevice가 기능별 peer를 보관한다"(추정) | **확인.** `ActionConnectionCache`. 오류와 기기 끊김 때 비운다 | 우리 참조 해제를 연결 종료로 보지 않는 규칙 유지. 연결을 다시 열 때 `xpcConnection`을 다시 부르면 된다(캐시가 죽은 연결을 이미 뺐다) |
| "CoreDevice는 이미 활성화된 연결을 넘긴다. 핸들러를 다시 설정하지 않는다"(규칙) | **확인.** `setEventHandler` → `activate()` 순서로 CoreDevice가 한다 | 유지. 핸들러를 덮어쓰면 캐시 정리가 깨진다는 이유를 주석에 적을 것 |
| "마지막 HID 이벤트 뒤 peer를 500 ms 유지" | **수정.** 연결은 캐시가 유지하므로 참조 유지 자체는 효과가 없다. CoreDevice에는 전달 완료를 기다리는 수단으로 barrier(동기 전송)가 있다 | 시간 대기를 barrier로 바꾼다. barrier가 실패하거나 응답하지 않는 기기를 위해 짧은 대기를 대체 경로로 둔다. 바꾸기 전에 실기기에서 확인 필요 |
| "네트워크 기기는 사용 assertion을 얻는 과정에서 터널이 만들어진다"(추정) | **확인.** CoreDeviceService → `ConnectableDevice.createTunnelUsageAssertion`. Device Hub도 이 방법만 쓴다 | 무선에서는 기능 연결 전에 assertion을 얻고 세션 동안 쥔다. 호출은 `acquireDeviceUsageAssertion(withReason:requirements:)`이고 요구 상태에 최소 `remoteServiceDiscoveryTrustedConnectivityAvailable`을 넣는다. HID는 DDI 서비스이므로 `coreDeviceServicesLoaded`도 넣는 것이 Device Hub와 같다 |
| "터널 상태는 `tunnelState`나 `deviceInfoChanges`로 본다. 내려가면 assertion을 다시 얻는다"(권장) | **수정.** Device Hub는 assertion의 `registerInvalidationHandler`와 `acquireUseAssertion` capability 변화를 본다 | assertion에 무효화 핸들러를 걸고, 무효화되면 입력·프레임을 멈춘 뒤 capability가 돌아오면 다시 얻는다. `tunnelState` 폴링은 필요 없다 |
| "avconferenced가 호출 프로세스의 권한을 검사한다"(추정) | **검사 함수와 호출 구조 확인.** 권한 이름을 읽는 함수, 연결 수락 시 그 결과를 구하는 코드, 메시지마다 authorization 블록으로 거절하는 코드를 봤다. 영상 스트림 서비스가 등록한 블록의 조건만 남았다 | 2b 판정(닫힘) 유지 |
| "Device Hub의 USB 화면이 미디어 스트림인지 USB 캡처인지"(미확인) | **미디어 스트림.** USB 캡처 코드가 없다 | mac-cu의 USB 캡처 경로는 Device Hub와 무관한 mac-cu 고유 경로다. Device Hub와 같은 화질·지연을 기대할 근거로 쓰지 말 것 |
| (새로 확인) 권한이 있어도 프레임은 렌더 서버 슬롯으로만 온다 | — | 권한 문제를 푼다 해도 스트림에서 `CGImage`를 얻을 수 없다. 스크린샷 경로가 유일한 in-process 픽셀 소스다 |
| "기존 HID 경로를 그대로 쓴다"(digitizer 기능 하나로 터치·키·버튼) | **수정 필요.** 아래 | 아래 |
| "입력 전 잠금 확인은 `currentLockState`" | Device Hub는 잠금 API를 쓰지 않고 실패 뒤에 안내한다 | mac-cu의 사전 확인은 Device Hub보다 엄격한 자체 정책이다. 유지 |

입력 경로 수정:

1. **버튼**은 `com.apple.coredevice.feature.remote.hid.button` 연결을 따로 열어 `IndigoButtonEvent`를 보낸다. `featureIdentifier` 필드도 그 기능 이름이어야 한다. payload는 `usagePage`(UInt16), `usageCode`(UInt16), `state`(`down`/`up`)다. 홈은 0x0C/0x40, 전원 0x0C/0x30, 음량 0x0C/0xE9·0xEA. digitizer 연결로 버튼 메시지를 보내던 것이 홈 버튼 실패의 원인일 가능성이 높다(기기 쪽 서비스가 기능별로 다르다는 것은 연결 생성이 기능 식별자로 서비스를 고른다는 데서 나온 추정).
2. **키**는 CoreDevice에 Indigo 메시지가 없다. `IndigoKeyboardButtonEvent`는 CoreDevice가 실기기에 보내는 메시지가 아니다. 선택지는 형 있는 API `HIDKeyboard.send(key:state:)`(capability `.hid.keyboard`, 내부적으로 universalhidservice의 기본 키보드 서비스에 report 전송)를 쓰거나, mac-cu가 시뮬레이터에서 이미 쓰는 UniversalHID report 경로(`SimulatorGestureHID.swift`)를 실기기 연결에 붙이는 것이다. 스텁 모듈을 쓰기로 했다면 전자가 단순하다.
3. **터치**는 지금의 `IndigoDigitizerEvent`(`remote.hid.digitizer`)가 CoreDevice에 등록된 구현이므로 틀린 경로는 아니다. 다만 Device Hub가 쓰는 경로가 아니어서 Apple이 계속 검증하는 경로라고 볼 수 없다. Device Hub와 같은 경로는 universalhidservice의 `touchscreen(displayID:)` 서비스에 digitizer report를 보내는 것이고, 손가락이 여러 개인 제스처도 이 경로로만 표현된다.
4. **스크롤**은 `remote.hid.scroll`의 `IndigoScrollEvent`로 Device Hub와 같다.

## 실행 관찰이 필요한 것

정적으로 정하지 못했고 사용자가 지켜보는 실행으로만 확정되는 항목이다. 모두 사용자가 직접 Device Hub를 조작하고 이미 기록된 통합 로그를 읽는 방식이며, Apple 프로세스에 붙지 않는다.

| 항목 | 방법 |
| --- | --- |
| 무선 기기에서 터널이 올라오는 시점과 순서 | 사용자가 Device Hub에서 무선 기기를 선택. 이후 `log show --last 2m --predicate 'process == "CoreDeviceService" AND eventMessage CONTAINS[c] "assertion"'`에서 "Received request to create usage assertion" → "Requesting tunnel assertion" → "Succesfully fulfilled assertion" 순서 확인 |
| Device Hub가 실제로 여는 기능 연결 목록 | 같은 조작 뒤 `log show … --predicate 'eventMessage CONTAINS "Creating new XPC connection to device"'`(CoreDevice 로그, 기능 이름이 public으로 찍힌다)와 CoreDeviceService의 "Connected socket to" |
| 홈 버튼이 `remote.hid.button`으로 가는지 | Device Hub에서 홈 버튼을 누른 뒤 위 로그에 `…remote.hid.button` 연결 생성이 찍히는지 확인 |
| 잠긴 기기에서 화면 시작이 어떤 오류로 끝나는지 | 기기를 잠근 채 Device Hub에서 화면 보기 시작. `process == "DeviceHub"` 로그의 "Failed"·"deviceLockedOnPriorAttempt" 주변 오류 코드 확인 |
| 케이블을 뽑았을 때 assertion 무효화와 재획득 | 화면을 보는 중 케이블 분리. DeviceHub 로그의 "Usage assertion invalidated …"와 이후 "Attempting to acquire usage assertion" 간격 확인 |
| 종료 직전 대기 시간 | mac-cu 프로브로 이벤트 전송 직후 대기 시간을 0/50/200/500 ms로 바꿔 기기 반응 확인(기기 조작이므로 소유자 규칙에 따라) |

로그에는 기기 이름과 식별자가 섞이므로 문서에 옮길 때 지운다.

## 다시 분석하는 방법

Xcode가 바뀌면 주소는 달라진다. 함수는 이름과 로그 문자열로 다시 찾는다.

```sh
B=$(eyebuild dir devicehub-re); export TMPDIR=$B/tmp; mkdir -p $B/sym $B/lst $TMPDIR
DK=/Applications/Xcode.app/Contents/SharedFrameworks/DeviceKit.framework/Versions/A/DeviceKit

# 식별
shasum -a 256 "$DK"; otool -L "$DK"; codesign -d --entitlements :- /Applications/Xcode.app/Contents/Applications/DeviceHub.app

# 메타데이터
nm -arch arm64e -n "$DK" | xcrun swift-demangle > $B/sym/DeviceKit.dem
xcrun dyld_info -imports "$DK" | xcrun swift-demangle > $B/sym/DeviceKit.imports.txt
xcrun dyld_info -fixups "$DK" > $B/sym/DeviceKit.fixups.txt
strings -a "$DK" > $B/sym/DeviceKit.strings          # universal 파일은 lipo -thin arm64e 뒤에

# 디스어셈블(--macho를 붙이지 않는다)
xcrun llvm-objdump -d --no-show-raw-insn "$DK" > $B/lst/DeviceKit.dis
xcrun llvm-objdump -d --no-show-raw-insn --start-address=0x72423c --stop-address=0x7245bc "$DK"

# 공유 캐시 안의 AVConference
A=/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference
xcrun dyld_info -disassemble "$A" > $B/lst/AVConference.dis
xcrun dyld_info -section __AUTH_CONST __cfstring "$A"

# Ghidra 12.2 headless
export JAVA_HOME=/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home GHIDRA_HEADLESS_MAXMEM=8G
H=/opt/homebrew/opt/ghidra/libexec/support/analyzeHeadless; mkdir -p $B/ghidra/proj
"$H" $B/ghidra/proj dk -import "$DK" -scriptPath $B/ghidra/scripts -postScript DecompRanges.java $B/ghidra/out/DeviceKit 51f000-525400
"$H" $B/ghidra/proj dk -process DeviceKit -noanalysis -scriptPath $B/ghidra/scripts -postScript DecompRanges.java $B/ghidra/out/DeviceKit2 at:51dbf4   # 분석된 프로젝트 재사용
"$H" $B/ghidra/proj avc -import $B/ghidra/dsc/AVConference -loader MachoLoader -noanalysis -scriptPath $B/ghidra/scripts -postScript DecompSyms.java $B/ghidra/out/AVConference '_xpc_handle_incoming_request|entitlementStatusForToken'

# REA 6.9.0 CLI + Ghidra provider (thin Mach-O만)
export GHIDRA_INSTALL_DIR=/opt/homebrew/opt/ghidra/libexec
node /Volumes/eyedisk/REA-6.9/node_modules/rea-agents/scripts/rea.mjs decompile <thin-macho> <주소> --provider ghidra --snapshot <파일> --format json
```

- 주석 스크립트는 objdump 출력의 각 명령에 대해 `bl`/`b` 대상(스텁이면 `dyld_info -fixups`의 바인딩 이름), `adrp+add`·`adrp+ldr` 결과 주소의 기호·문자열·GOT 항목을 덧붙이고 `swift-demangle`을 통과시킨다. 스텁 표의 간접 기호가 지워져 있어 `otool -Iv`로는 스텁 이름을 얻을 수 없고, 스텁 본문의 GOT 주소를 fixup 표와 맞춰야 한다.
- Ghidra 기본 힙(2 GB)으로는 CoreDevice 분석과 공유 캐시 열기가 메모리 부족으로 실패한다. `GHIDRA_HEADLESS_MAXMEM`을 올린다.
- Ghidra 스크립트 둘은 `DecompInterface`로 주소 범위(`lo-hi`), 주소가 속한 함수(`at:주소`), 기호 이름 정규식에 해당하는 함수를 디컴파일해 파일로 쓴다. 공유 캐시에서 이미지를 꺼내는 스크립트는 `FileSystemService.openFileSystemContainer`로 캐시를 열고 `lookup(경로)`의 `ByteProvider`를 파일로 쓴다. 꺼낸 파일은 기본 로더(Extracted DYLD Component)로는 들어오지 않으므로 `-loader MachoLoader`를 준다.
- 찾을 때 쓴 문자열: "Getting usage assertion", "Attempting to acquire usage assertion", "Creating new XPC connection to device", "Connected socket to", "Requesting tunnel assertion", "Starting AVCRemoteVideoClient", "IndigoButtonEvent", "HID queue at capacity".
