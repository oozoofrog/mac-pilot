# 실기기 무선(CoreDevice 네트워크) 연결 조사

2026-11-14, macOS 27.2 / Xcode 27.2(27B48) / CoreDevice 651.31, iPhone 14 Pro(iOS 27.2).

조사 시점에 기기는 다른 작업 때문에 **USB(`transportType: wired`)** 로 연결되어 있었다. 아래 실측은 모두 USB 위의 CoreDevice 터널에서 잰 값이고, 무선에서 같은지는 바이너리 근거로 추정한 것과 다시 재야 하는 것을 따로 적었다. 입력 이벤트는 보내지 않았다.

## 판정

| 항목 | 판정 | 요약 |
| --- | --- | --- |
| 1. 네트워크 입력 | 동작할 것으로 추정(미실측) | HID 연결은 전송 매체가 아니라 CoreDevice 터널 위의 RemoteXPC 연결이다. 네트워크 기기는 터널을 먼저 올려야 한다 |
| 2a. in-process 스크린샷 | **동작(USB 실측)** | devicectl 없이 프로세스 안에서 호출. 요청을 겹쳐 보내면 초당 9–31장, 장당 지연 95–260 ms |
| 2b. 미디어 스트림·화면 보기 | 닫힘 | 영상 수신에 필요한 AVConference 권한을 로컬 데몬 avconferenced가 호출 프로세스에 대해 검사한다 |
| 2c. 공개 무선 경로 | 앱 없이는 없음 | 실시간 무선 영상은 기기에 설치한 앱의 ReplayKit 방송뿐이다 |
| 2d. iPhone 미러링 | 제외 | 기기를 잠가야 해서 `device` 도구의 잠금 가드와 양립하지 않는다(실행하지 않음) |
| 3. in-process 상태 조회 | **동작(USB 실측)** | 잠금 상태 32–39 ms, 디스플레이 정보 10–14 ms, 변경 스트림 구독 가능 |

## 근거를 얻은 방법과 한계

- **REA**: 이 Mac의 REA 서버(rea-agents 6.8.0)에는 디컴파일 엔진(Ghidra·Hopper·IDA·Kuna)이 설정되어 있지 않아 `search_procedures`, `procedure_pseudo_code`가 `provider_unavailable`로 끝났다. `inspect_signature`도 실패했고, `inspect_with_objdump`의 기호 단위 디스어셈블은 Xcode의 objdump가 인자를 거부했다. REA로 얻은 것은 대상 식별뿐이다: CoreDevice sha256 `00bf7055…eb48a`, Evidence `ev_27a0b033…b7b2`(file headers), `ev_52ed68c6…b706`(실패한 디스어셈블 명령 기록).
- 그래서 바이너리 근거는 **셸 도구 관찰**이다: `nm -m`, `xcrun dyld_info -imports`, `strings`, `otool -L`, `codesign -d --entitlements`, `swift-demangle`. 아래에서 "기호", "문자열", "import"라고 적은 것은 모두 이 방법이고 디컴파일로 흐름을 확인한 것이 아니다.
- 실행 근거는 이 조사에서 만든 프로브(`mac-computer-use/tests/physical-device-remote-probe/` (local investigation tool, not shipped))의 출력이다. 프로브는 임시 서명(ad hoc), 권한 0개다.

| 바이너리 | sha256 앞 16자리 |
| --- | --- |
| `/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice` | `00bf7055ace3517b` |
| `…/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities` | `105f6cf36845f796` |
| `…/CoreDevice.framework/Versions/A/Resources/bin/devicectl` | `1a6771cf8829c3ac` |
| `…/XPCServices/CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService` | `a145f8a1500a38db` |
| `…/Frameworks/CoreDeviceMediaStreamSupport.framework/CoreDeviceMediaStreamSupport` | `fae3c290f7b23930` |
| `/Library/Apple/System/Library/PrivateFrameworks/Mercury.framework/Mercury` | `d9640d0edafddd2d` |
| `/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub` | `b2d716b7eed8076a` |

## 1. 네트워크 입력

### 관찰

- USB로 연결한 시험용 iPhone도 터널을 쓴다. `devicectl list devices`의 연결 속성이 `transportType: wired`, `tunnelState: connected`, `tunnelIPAddress`(IPv6 ULA), `tunnelTransportProtocol: tcp`다. Mac에는 그 주소 대역의 `utun` 인터페이스(MTU 16000)가 있다.
- HID 연결을 주는 `RemoteDevice.xpcConnection(forFeatureIdentifiedBy:)`는 프로세스 안에서 `Mercury.RemoteXPCPeerConnection`을 돌려준다(8회 열고 닫음, 메시지 0건). 첫 호출 22–28 ms, 같은 프로세스의 다음 호출은 0.0 ms에 같은 객체 주소를 돌려줬다.
- import 분포: CoreDeviceService는 `remote_service_connect_socket`, `xpc_remote_connection_create_with_remote_service`를, 클라이언트 쪽 CoreDevice는 `xpc_remote_connection_create_with_connected_fd`와 `Mercury.RemoteXPCConnection.unsafePeer(from:)`를 가져온다.
- CoreDeviceService의 권한: `com.apple.private.CoreDevice.hid`, `…canViewDeviceDisplay`, `…devicecontrol`, `com.apple.private.remoted.coredevice`, `com.apple.private.RemoteServiceDiscovery.device-admin`. 프로브에는 권한이 없다.
- Mac 쪽 CoreDevice 계열에서 호출 프로세스의 권한을 이름으로 검사하는 문자열은 `com.apple.private.CoreDevice.takeDeviceSysdiagnose`(CoreDevice)와 `com.apple.private.CoreDevice.obtainContainerAccess`(CoreDeviceUtilities `EntitlementChecks.swift`) 둘뿐이다(문자열 검색 범위 한정).
- 터널이 내려간 네트워크 기기(`localNetwork`, `tunnelState: disconnected`)의 capability는 5개뿐이다: `acquireusageassertion`, `connectdevice`, `default.user.credentials`, `tags`, `unpairdevice`. `remote.hid.*`, `capturescreenshot` 등은 터널이 올라온 뒤에 나타난다. USB 시험용 iPhone은 65개다.
- `AcquireDeviceUsageAssertionActionDeclaration.ProgressUnit`의 case가 `started → createdTunnelConnection → enablingDeveloperDiskImageServices → fetchingExtendedDeviceInfo → completed`다. devicectl은 `RemoteDevice.acquireDeviceUsageAssertion(withReason:options:)`를 가져온다.

### 추정

- 권한을 가진 CoreDeviceService가 기기의 RSD 서비스에 소켓을 연결해 그 fd를 클라이언트에 넘기고, 클라이언트가 그 fd로 RemoteXPC 연결을 만든다(import 분포와 권한 보유 주체로 추정. 호출 흐름은 디컴파일로 확인하지 못했다).
- 이 경로에는 USB 전용 요소가 없다. 터널이 올라와 있으면 `localNetwork`에서도 같은 호출이 같은 연결을 줄 것이다.
- 네트워크 기기는 **사용 assertion을 얻는 과정에서 터널이 만들어진다.** 따라서 무선에서는 HID 연결을 열기 전에 `acquireDeviceUsageAssertion`을 부르고, 세션 동안 그 객체를 쥐고 있어야 한다.
- CoreDevice가 기능별 peer를 보관한다(두 번째 호출 0.0 ms, 같은 주소). 우리 쪽 참조를 놓아도 연결이 닫히지 않을 수 있다.

### 미확인

- 네트워크 터널에서의 입력 전달, 지연, 마지막 이벤트 뒤 유예 시간(USB에서 경험적으로 500 ms)이 충분한지.
- `getImplementation`이나 `xpcConnection` 호출만으로 터널이 자동으로 올라오는지, assertion이 반드시 필요한지.
- 터널이 끊겼을 때 `xpc_remote_connection_send_message`(반환값 없음)가 어떻게 되는지. 기기 화면이 꺼지거나 Wi-Fi가 절전에 들어갈 때 터널이 유지되는지.

## 2a. in-process 스크린샷

### 호출 경로

devicectl이 쓰는 형 있는 API를 그대로 부른다(devicectl import로 확인):

```swift
let capture = try await device.getImplementation(for: CapabilityStaticMember<CaptureScreenshotCapability>.captureScreenshot)
let output = try await capture.captureScreenshot(displayUniqueID: nil, format: .png)   // throws(CoreDeviceError)
output.image   // CGImage
```

- `RemoteDevice.getImplementation<A: DeviceCapability>(for: CapabilityStaticMember<A>) async throws -> A.ProtocolType` (dispatch thunk `$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTj`)
- `CaptureScreenshotProtocol.captureScreenshot(displayUniqueID: String?, format: ScreenshotImageFormat) async throws(CoreDeviceError) -> CaptureScreenshotOutput`
- 실제 구현 타입은 `ActionBasedDeviceCapabilityImplementation<CaptureScreenshotActionDeclaration, CaptureScreenshotCapability>`(런타임 출력), 액션 식별자 `com.apple.coredevice.action.capturescreenshot`, 입력 `CaptureScreenshotInput(displayUniqueID:requestedFormat:)`, 출력 `CaptureScreenshotOutput(image:displayUniqueID:imageFormat:)`.
- `ScreenshotImageFormat`의 case는 `png` 하나다(`allCases` 런타임 출력). JPEG·HEIC를 요청할 수 없다.
- 제네릭 함수라 `@_silgen_name`으로는 부를 수 없다. 프로브는 **선언만 담은 스텁 모듈**(`-enable-library-evolution`, 본문 없음)을 만들어 컴파일러가 올바른 호출을 만들게 하고 실제 프레임워크에 약하게 링크한다. 프로브가 가져오는 CoreDevice·CoreDeviceUtilities·Mercury 기호는 모두 실제 바이너리에 약한 import로 묶였다(`dyld_info -imports`). 프레임워크 경로를 없는 곳으로 바꾼 사본도 실행은 되고 기호 확인에서 멈춘다(`error: missing $s10CoreDevice25CaptureScreenshotProtocolMp`).

### 실측 (USB)

`remote-probe <DEVICE_UUID> shots <n> [--interval-ms <ms>]`. 요청 하나가 끝나기를 기다리지 않고 일정 간격으로 다음 요청을 시작하는 방식이 핵심이다.

| 화면 내용 | 방식 | 결과 |
| --- | --- | --- |
| 넓은 색 영역(48비트 PNG) | 순차 20장 | 중앙 245 ms/장, 3.67장/초 |
| 〃 | 200 ms 간격 20장 | 4.78장/초, 실패 0, 장당 245 ms |
| 〃 | 130 ms 간격 | 7.09장/초, 실패 0, 장당 249 ms |
| 〃 | 100 ms 간격(20장, 3회) | 8.80–8.99장/초, 실패 0, 장당 262–267 ms |
| 〃 | 70 ms 간격 | 11.79장/초, 실패 0, 장당 372 ms |
| 〃 | 40 ms 간격 | 20장 중 5장 실패(오류 25003) |
| sRGB(32비트 PNG) | 100 ms 간격 60장 | 9.08장/초, 실패 2(한 장이 490 ms 걸린 직후), 장당 95 ms |
| 〃 | 80 ms 간격 60장 | 11.59장/초, 실패 0, 장당 93 ms |
| 〃 | 60 ms 간격 60장 | 15.28장/초, 실패 0, 장당 96 ms |
| 〃 | 45 ms 간격 60장 | 19.52장/초, 실패 0, 장당 94 ms |
| 〃 | 33 ms 간격 90장 | 25.24장/초, 실패 1, 장당 101 ms |
| 〃 | 25 ms 간격 90장 | 31.04장/초, 실패 1, 장당 125 ms |
| 〃 | 16 ms 간격 90장 | 20장 실패 |

- 실패는 모두 `CoreDeviceError(errorCode: 25003 … "A screenshot capture is already in progress …")`이고 즉시 돌아온다. 기기의 캡처 구간(약 16–40 ms로 추정)만 배타적이고, 인코딩과 전송은 겹칠 수 있다.
- 동시 2개(`--parallel 2`)는 20장 중 6장, 동시 4개는 24장 중 20장이 실패했다. 동시에 시작하지 말고 간격을 두어야 한다.
- 이미지: 1179×2556. 넓은 색 영역 화면에서는 `bitsPerPixel=48`, sRGB 화면에서는 32였다(같은 기기, 몇 분 차이. 화면 내용은 확인하지 않았고 형식 차이로 구분했다).
- 터널 수신 바이트(`netstat -I <utun> -b`, 배경 트래픽 약 150 KB/초 포함): 넓은 색 영역 **약 1.3 MB/장**, sRGB **약 0.4 MB/장**. 이 Mac에서 다시 PNG로 인코딩하면 652 KB / 198 KB, JPEG(q0.7)는 312 KB / 287 KB.
- 구현 객체 획득 8–21 ms(프로세스당 한 번), 기기 조회 0 ms, 프로브 최대 상주 메모리 32 MB.
- devicectl 반복(1.46장/초) 대비 순차 호출만으로 2.5배, 간격 요청으로 6–20배다.

### 미확인

- 전달된 프레임이 서로 다른 화면 시점인지(중복 여부)는 비교하지 않았다. 응답 순서가 요청 순서와 같다는 보장도 확인하지 않았다.
- 초당 10–30장을 계속 요청할 때 기기의 발열·배터리·앱 성능 영향.
- 네트워크 터널에서의 속도. 대역만 보면 sRGB 10장/초에 약 32 Mbit/s, 넓은 색 영역 10장/초에 약 105 Mbit/s가 필요하다.
- 잠금 화면, 화면 꺼짐, 가로 방향에서의 결과.

## 2b. 미디어 스트림, `viewdevicescreen`, `startvideooutput`

### 관찰

- 기기 쪽 기능 설명(`RemoteDevice.mediaStreamSupportInfo`, 권한 없는 프로브에서 85 ms에 응답): 기기 `supportedFeatures: 972` = "Primary video display mirrored output stream, System audio output stream, Virtual external video output stream, Video output stream by display ID, Display information, Screenshot capture". `startvideooutput`의 표시 이름은 "Start Video Output", `viewdevicescreen`은 "View Device Screen"이다(CoreDeviceUtilities 문자열).
- `RemoteDevice.mediaStreamServerStatus`도 권한 없이 응답했다. 조사 시점에 다른 클라이언트의 오디오 출력 세션 하나가 터널 IPv6 주소 사이(기기 포트 → Mac 포트)로 열려 있었다. 미디어도 터널 주소로 흐른다.
- 제어면 타입: `DeviceMediaStream.StartRequest`(`negotiatorOffer: Data`, `receiverIP`, `receiverPort`, `type`, `direction`, `clientSupportedFeatures`, `options`, `sessionEventChannel`) → `StartResponse.connection: ConnectionInfo`(`sender`/`receiver: NetworkInfo`, `streamConfig: MediaStreamConfig` — SRTP/SRTCP cipher suite, SSRC, payload type, RTCP 설정 등). `RemoteDevice.startMediaStream(with:)`는 공개 기호다.
- 미디어면 구현: `CoreDeviceMediaStreamSupport`가 `AVConference.framework`에 링크하고 `AVCMediaStreamNegotiator initWithMode:options:error:`, `AVCVideoStream initWithNetworkSockets:options:error:`, `AVCRemoteVideoClient initWithStreamToken:delegate:`, `AVCScreenCapture`를 쓴다(ObjC 셀렉터·문자열).
- 권한 보유: `com.apple.videoconference.allow-conferencing`은 **DeviceHub**(`com.apple.dt.Devices`)와 **devicectl**에 있고 CoreDeviceService에는 없다. DeviceHub는 mach 서비스 `com.apple.videoconference.camera`의 조회 예외도 가진다. AVConference에 링크하는 것은 DeviceHub다(devicectl·CoreDeviceService·CoreDevice는 링크하지 않음).
- 권한 없는 로컬 프로세스(기기와 무관)에서: `AVCMediaStreamNegotiator`는 프로세스 안에서 만들어지고 offer(432–603바이트)를 돌려줬다. `+[AVCVideoStream capabilities]`도 응답했다. `-[AVCVideoStream initWithNetworkSockets:options:error:]`는 `setUpVideoStreamOutOfProcessWithClientArgs:xpcArguments:error:` → `-[AVConferenceXPCClient sendMessageSync:arguments:xpcArguments:]`로 들어갔고(`sample` 스택), 직전에 `com.apple.videoconference.camera` 연결을 활성화했다(통합 로그). 이 시험은 인자 형식을 맞추지 못해 XPC 직렬화에서 멈췄고 데몬의 응답까지 가지 못했다.
- 데몬 쪽 문자열(dyld 공유 캐시의 AVConference 영역): `+[AVConferenceXPCServer(XPCManagement) entitlementStatusForToken:]`, `Failed to create SecTask from audit token`, `Process %s (PID=%d) encountered error while checking entitlement=%s, ignoring connection`, `API name=%@ failed authorization check error=%@, entitlementStatus=%ld`, `-[AVConferenceXPCServer registerBlockForService:block:queue:eventLogLevel:authorizationBlock:allowablePublicAPIs:]`, 그리고 `com.apple.videoconference.allow-conferencing`.
- 이전 검토의 실측: 이 권한을 임시 서명으로 붙인 바이너리는 실행 즉시 종료된다(exit 137).

### 판정: 닫힘

- 영상 수신(AVCVideoStream)은 로컬 데몬 **avconferenced**가 처리하고, 데몬이 호출 프로세스의 audit token으로 권한을 검사한다. 검사 위치는 Mac의 로컬 데몬이다(문자열과 권한 보유 주체로 추정. 실제 거절 응답은 관찰하지 못했다).
- 그 권한은 Apple 서명 없이 가질 수 없다. 권한을 가진 시스템 프로세스가 프레임을 넘겨주는 공개·준공개 XPC 서비스는 찾지 못했다(CoreDeviceService는 그 권한이 없고 AVConference에 링크하지 않는다).
- 제어면(`startMediaStream`)은 권한 없이도 닿을 가능성이 높지만(지원 정보·상태 조회가 응답함), 세션을 시작하지 않았으므로 확인하지 않았다. 닿더라도 SRTP 영상을 받아 풀 수단이 없다.
- AVConference 없이 협상 blob과 RTP/SRTP 수신을 직접 구현하는 길은 조사하지 않았다. 문서화되지 않은 형식이고 유지 비용이 커서 권하지 않는다.
- `devicectl device capture screen-record`는 이전 검토대로 실기기에서 미지원이다(프로브: `supports screenrecording: false`).

## 2c. 공개 무선 경로

| 경로 | 판정 | 근거 |
| --- | --- | --- |
| AVFoundation 장치 탐색 | 무선 화면 없음(부분 관찰) | `capture-discovery` 프로브: muxed 장치 1개(USB의 "iOS Device"), video 장치는 Desk View 1개와 연속성 카메라 1개. 연속성 카메라는 카메라이지 화면이 아니다. 터널이 올라온 네트워크 전용 iPhone이 있는 상태에서는 재지 못했다 |
| AirPlay 수신 | 앱에서 쓸 수 없음 | macOS의 AirPlay 수신은 시스템 기능이고 서드파티 Mac 앱용 수신 API가 없다. 수신 프로토콜을 직접 구현하려면 보호 절차를 우회해야 하므로 범위 밖이다. 사용자가 매번 기기에서 미러링을 켜야 하는 점도 같다 |
| ReplayKit 방송(기기 앱 필요) | 가능(미구현·미실측) | 아래 요건 |

ReplayKit 방송을 쓰려면:

- 기기에 앱과 Broadcast Upload Extension(`RPBroadcastSampleHandler`)을 설치한다. 개발자 서명이면 프로비저닝 만료(무료 계정 7일)마다 다시 설치해야 한다.
- **방송 시작은 매번 기기에서 사람이 눌러야 한다**(시스템 방송 선택 화면 또는 제어 센터). 방송 중에는 상태 표시가 뜬다. 이 승인을 `device` 도구의 입력으로 대신 누르지 않는다.
- 확장이 받은 프레임을 VideoToolbox로 H.264/HEVC 인코딩해 로컬 네트워크로 보내고, mac-cu가 받아 디코딩해 LCD 창에 그린다. 앱에는 로컬 네트워크 권한이 필요하다. 확장의 메모리 한도(약 50 MB)에 맞춰야 한다.
- 기기가 잠기면 방송이 끝난다. 화면 전체가 대상이라 다른 앱으로 넘어가도 이어진다.
- 30–60장/초와 낮은 지연을 기대할 수 있지만 이 조사에서 만들거나 재지 않았다.

## 2d. iPhone 미러링

실행하지 않았다. iPhone 미러링은 기기가 잠겨 있어야 동작하는데 `device` 도구는 잠긴 기기에 입력을 보내지 않으므로, 창을 프레임 소스로만 쓰더라도 입력 경로와 함께 쓸 수 없다. Mac 화면 캡처 권한도 따로 필요하다.

## 3. in-process 상태 조회

```swift
let lock = try await device.getImplementation(for: CapabilityStaticMember<LockStateCapability>.lockState)
let state = try await lock.currentLockState            // LockState: isPasscodeRequired, hasBeenUnlockedSinceBoot
let displays = try await device.getImplementation(for: CapabilityStaticMember<DisplayInfoCapability>.displayInfo)
let info = try await displays.displayInfo              // DisplayInfo: displays, orientation, backlightState
let stream = try await displays.displayInfoUpdates()   // AsyncThrowingStream<DisplayInfo, Error>
```

| 항목 | 결과(USB) |
| --- | --- |
| `currentLockState` | 20회 중앙 32–39 ms(최소 25, 최대 98). 액션 `com.apple.coredevice.action.lockstate` |
| `displayInfo` | 20회 중앙 10–11 ms(첫 호출 111 ms). 액션 `com.apple.coredevice.action.displayinfo` |
| `displayInfoUpdates()` | 구독 0.6 ms, 32 ms 뒤 현재 값 1건 수신. 4초 동안 변화가 없어 이후 이벤트는 없었다. 액션 `com.apple.coredevice.action.displayinfoupdates` |
| 구현 객체 획득 | 잠금 9–21 ms, 디스플레이 0.2–0.3 ms |
| 터널 바이트 | 잠금+디스플레이 40회에 수신 약 0.4 MB(배경 트래픽 포함) |

- `DisplayInfo`: `displays: [Display]`, `orientation: OrientationInfo?`(`currentDeviceOrientation`, `currentDeviceNonFlatOrientation`, `currentDeviceOrientationLocked`), `backlightState`(`unknown`/`off`/`inactiveOn`/`activeDimmed`/`activeOn`).
- `Display`: `displayId`, `primary`, `external`, `nativeSize`, `bounds`, `pointScale`, `currentOrientation`, `nativeOrientation`, `backlightState`, `chromeIdentifier`, `framebufferMaskIdentifier`, `uniqueId` 등. 시험용 iPhone의 주 디스플레이는 `id=1 primary=true native=1179x2556 scale=3 orientation=rot0`, `chrome=com.apple.dt.devicekit.chrome.phone7`이었다. 조사 시점에는 디스플레이가 6개 보고됐고(나머지는 `external=true`, 백라이트 꺼짐) 주 디스플레이는 `primary`로 고른다.
- 방향 제어 capability(`remote.devicecontrol.orientation`, `OrientationControl` 프로토콜)도 기기가 지원한다고 응답했지만 상태를 바꾸는 호출이라 부르지 않았다.
- 접근자의 오류 규약은 맹글된 이름에 나타나지 않는다. 프로브는 `get async throws`로 선언했다. `captureScreenshot`의 `throws(CoreDeviceError)`는 실제 오류(25003)를 받아 확인했고, 상태 접근자의 오류 경로는 발생시키지 못했다.

## 권장 설계

**프레임 소스**

1. USB이고 카메라 권한이 있으면 기존 USB 캡처(약 58장/초).
2. 그 밖의 모든 경우(무선, 카메라 권한 없음, 캡처 실패)는 **in-process CoreDevice 스크린샷을 일정 간격으로 겹쳐 요청**한다.
3. 스텁 ABI 확인이 실패하면 기존 devicectl 스크린샷 반복으로 내려간다.

**기대값**: USB에서 sRGB 화면 15–25장/초·지연 약 100 ms, 넓은 색 영역 화면 9–12장/초·지연 250–370 ms(실측). 무선은 미실측이며 Wi-Fi 처리량에 따라 5–15장/초, 지연 150–500 ms로 예상한다.

**간격 제어**

- 시작 간격 100 ms, 동시에 진행 중인 요청 최대 4개.
- 25003 오류가 오면 간격을 1.5배로 늘리고, 연속 20장 성공하면 10%씩 줄인다(하한 45 ms).
- 완료 지연이 간격의 3배를 넘으면 간격을 늘린다. 무선에서 대역이 부족할 때의 주된 신호다.
- 요청마다 순번을 붙여, 이미 그린 프레임보다 오래된 응답은 버린다.
- 창이 가려졌거나 화면 변화가 2초 이상 없으면 초당 2장으로 낮추고, 입력 직후에는 다시 올린다.

**상태**

- 창을 여는 동안 `displayInfoUpdates()`를 구독해 방향·백라이트 변화를 받는다. 스트림이 끝나면 `displayInfo`를 1초 간격으로 읽는다.
- 입력 전 잠금 확인은 `currentLockState`(약 35 ms)로 바꾼다. devicectl 하위 프로세스(0.7초 안팎)가 없어지므로 연결 직후 재확인과 긴 입력 중 재확인 비용이 줄어든다.

**입력**

- 기존 HID 경로를 그대로 쓴다. 네트워크 기기는 먼저 `acquireDeviceUsageAssertion`으로 터널을 올리고, 창이나 도구 세션이 끝날 때까지 assertion을 쥔다.
- 터널 상태는 `devicectl`의 `tunnelState` 또는 `RemoteDevice.deviceInfoChanges`로 본다. 내려가면 프레임 요청과 입력을 멈추고 "기기 연결 끊김"을 표시한 뒤 assertion을 다시 얻는다.

**대체 경로**: in-process API 실패 → devicectl 스크린샷. 터널 없음 → 연결 필요 상태 표시. 실시간 무선 영상이 꼭 필요하면 ReplayKit 앱(아래 결정 사항).

## 구현 개요

기존 코드: [PhysicalDeviceLink.swift](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/PhysicalDeviceLink.swift), [Device.swift](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/Device.swift), [native_build.py](../../mac-computer-use/skills/mac-computer-use/scripts/native_build.py).

1. **스텁 모듈**: 프로브의 `stubs/CoreDevice.swift`, `stubs/CoreDeviceUtilities.swift`를 제품 소스 옆으로 옮긴다. `native_build.py`가 본 컴파일 전에 `swiftc -emit-module -parse-as-library -enable-library-evolution -module-name <이름>`으로 `.swiftmodule`만 만들고 본 컴파일에 `-I <그 폴더>`를 준다. 링커 플래그에 `-weak_framework CoreDeviceUtilities`를 더한다(지금은 CoreDevice만). Mercury 스텁은 `xpcConnection`을 스텁 경로로 옮길 때만 필요하고, 그때는 `-F /Library/Apple/System/Library/PrivateFrameworks -weak_framework Mercury`도 더한다.
2. **실행 전 확인**(`PhysicalDeviceLink.checkedManager`의 기호 목록 확장): 새로 쓰는 dispatch thunk·프로토콜 기술자·연관 타입 기술자의 `dlsym` 존재, 세 프로토콜이 클래스 제약이 아님(기술자 플래그 16번 비트 = 1), 런타임의 `A.ProtocolType`이 스텁 선언과 같은 타입인지(프로브의 `checkABI()`). 하나라도 어긋나면 in-process 경로를 끄고 devicectl로 내려간다.
3. **새 타입 `PhysicalDeviceSession`**(새 파일): `RemoteDevice`, 사용 assertion, `any CaptureScreenshotProtocol`, `any LockStateProtocol`, `any DisplayInfoProtocol`을 기기당 하나 보관한다. `capture() async throws -> CGImage`, `lockState()`, `displayInfo()`, `displayUpdates()`를 제공한다. 구현 객체는 세션당 한 번 얻고 기기가 끊기면 버린다.
4. **`PhysicalFramePump`**: 위 간격 제어를 구현하고 LCD 창에 `CGImage`와 순번을 넘긴다. LCD 창의 프레임 소스를 `usbCapture` / `coreDeviceScreenshots` / `devicectl`로 나눈다.
5. **`Device.swift`**: `screenshot`과 잠금 확인을 세션 호출로 바꾸고 실패 시 기존 devicectl 호출로 내려간다. `device` 도구의 스크린샷 응답 시간이 1.5초에서 0.1–0.3초대로 줄 것으로 예상한다.
6. **수명 규칙**
   - CoreDevice는 이미 활성화된 연결을 넘긴다. 그 연결에 이벤트 핸들러를 다시 설정하지 않는다.
   - `@_silgen_name` 선언으로 `xpcConnection`을 부르는 지금 코드에서는 반환된 peer의 소유권을 `takeRetainedValue()`로 정확히 한 번 인수한다. 스텁 모듈로 옮기면 반환 타입이 `any XPCPeerConnection`이라 컴파일러가 소유권을 관리하므로 수동 인수를 지운다. 두 방식을 섞지 않는다.
   - 마지막 HID 이벤트 뒤 peer를 500 ms 유지하는 기존 규칙은 그대로 둔다.
   - CoreDevice가 peer를 보관하는 것으로 보이므로, 우리 참조를 놓는 것을 "연결 종료"로 간주하지 않는다.
   - 사용 assertion은 세션 객체가 소유하고 세션이 끝날 때 놓는다.
7. **검사**: 프레임워크 경로를 없는 곳으로 바꾼 실행 검사에 스텁 경로를 포함한다. 모의 backend로 간격 제어(25003 → 간격 증가, 순번 역전 폐기)를 검사한다.

비공개 ABI 의존이 `@_silgen_name` 기호 몇 개에서 스텁 모듈의 타입·프로토콜 선언으로 넓어진다. Xcode가 바뀌면 링크 실패나 실행 전 확인 실패로 드러나고, 그때는 devicectl 경로로 동작한다.

## 케이블을 뺀 뒤 다시 잴 것

1. 터널 올리기: `tunnelState: disconnected`에서 `acquireDeviceUsageAssertion` 소요 시간, assertion 없이 `getImplementation`·`xpcConnection`만 불렀을 때의 결과, 기기가 잠겼거나 화면이 꺼졌을 때의 결과.
2. `remote-probe <DEVICE_UUID> open com.apple.coredevice.feature.remote.hid.digitizer 3`: 네트워크에서 peer를 받는지와 시간.
3. 입력 전달과 지연(소유자 규칙에 따라), 500 ms 유예가 충분한지.
4. `shots 60 --interval-ms 200/100/70/45/33`: 두 화면 종류 각각의 장/초, 장당 지연, 실패율, `utun` 수신 바이트.
5. `state 20`, `updates 30`(기기를 돌려 방향 이벤트가 오는지).
6. 끊김: 기기 잠금·화면 꺼짐·Wi-Fi 범위 이탈 때 `captureScreenshot`이 던지는 오류와 걸리는 시간, HID 전송의 동작, 다시 연결되는 시간.
7. 10–25장/초를 10분 유지할 때 기기 발열과 배터리.
8. `capture-discovery`: 네트워크 전용 상태에서 muxed 장치가 0개인지.

## 결정이 필요한 것

1. 무선 화면을 "스크린샷 기반 준실시간(USB 기준 9–25장/초)"으로 받아들일지, 기본 상한(예: 10장/초)을 얼마로 둘지.
2. 실시간 무선 영상이 꼭 필요하면 ReplayKit 방송 앱을 기기에 설치하는 방식을 받아들일지. 세션마다 기기에서 방송 시작을 직접 눌러야 한다.
3. 비공개 프레임워크의 스텁 모듈을 제품 빌드에 넣을지.
4. LCD 창이 열려 있는 동안 사용 assertion을 계속 쥘지(터널 유지. 기기 절전에 미치는 영향은 미확인).

## 이 조사에서 기기에 한 일

모두 읽기 전용, 2026-11-13 15:29–15:40 UTC, 11회의 짧은 점유(각 1–15초, 합계 약 80초).

- 스크린샷 요청 약 770회(성공분은 메모리에서 크기만 읽고 버림, 1장만 빌드 폴더에 저장했다가 삭제)
- 잠금 상태 약 83회, 디스플레이 정보 약 83회, 디스플레이 변경 스트림 4초 구독 1회
- 미디어 지원 정보·서버 상태 조회 각 1회(스트림 시작 없음)
- HID digitizer 기능 연결 8회 열기(메시지 0건)
- AVFoundation 장치 탐색 1회(캡처 세션 없음)
- 입력 이벤트, 방향 변경, 녹화·방송 시작: 없음
