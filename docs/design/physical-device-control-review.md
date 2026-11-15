# 실기기 iPhone 화면 연결·조작 구현 검토

2026-11-13, macOS 27.2 / Xcode 27.2(27B48)에서 USB로 연결한 iPhone 14 Pro(iOS 27.2, 개발자 모드 켬)로 실측했다. 필수 조건은 사용자의 Mac 마우스·키보드 조작을 방해하지 않는 것이다.

## 결론

- **입력은 구현할 수 있다.** Apple 서명도 비공개 권한도 없는 프로세스가 CoreDevice를 거쳐 실기기 터치 HID 연결을 받았고, 지금 시뮬레이터에 보내는 것과 같은 `IndigoDigitizerEvent` 메시지로 실기기 화면을 스크롤했다. 입력은 기기 안에서 주입되므로 Mac 커서와 포커스를 쓰지 않는다.
- **실시간 화면은 경로를 하나 더 실측해야 확정된다.** Device Hub가 쓰는 미디어 스트림은 mac-cu가 가질 수 없는 권한에 묶여 있다. 공개 API인 USB 화면 캡처 장치로는 기기가 잡히지만, 프레임 수신과 속도는 카메라 권한이 필요해 아직 재지 못했다. 스크린샷 반복은 초당 약 1.5장이다.
- **권장 순서**: 실기기 입력 + 스크린샷 기반 도구를 먼저 만들고, USB 캡처 프레임 속도를 실측한 뒤 실시간 LCD 창을 붙인다.

## 실측 결과

| 항목 | 결과 | 방법 |
| --- | --- | --- |
| 실기기 HID 연결 | 성공 | 임시 서명(ad hoc), 권한 0개인 프로브가 `RemoteDevice.xpcConnection(forFeatureIdentifiedBy:)`로 `…remote.hid.digitizer` 연결을 받음. 반환 객체는 `Mercury.RemoteXPCPeerConnection`(내부에 `OS_xpc_remote_connection`) |
| 터치 전달 | 성공 | 한 손가락 드래그(0.62→0.42, 0.5초) 후 화면 평균 픽셀 차이 9.51, 반대 드래그 후 원래 화면과의 차이 0.18(0–255 기준) |
| Mac 입력 비간섭 | 변화 없음 | 드래그 전후 커서 좌표와 최전면 앱이 같음. 프로브는 CGEvent·AX 계열 기호를 하나도 참조하지 않음 |
| 스크린샷 | 0.68–0.88초/장 | `devicectl device capture screenshot`, 1179×2556. 임시 서명한 devicectl 복사본도 같은 결과 |
| 스크린샷 연속 | 초당 1.46장 | 10장 연속 6.87초(프로세스 시작 시간 포함). 4장 동시 요청은 0.86초에 3장만 저장됨 |
| `devicectl … screen-record` | 실기기 미지원 | `com.apple.coredevice.feature.screenrecording` capability 없음(오류 1001) |
| remoted 직접 연결 | 막힘 | 권한 없는 프로세스는 기기는 보이지만 서비스 항목이 보이지 않음 |
| 미디어 스트림 권한 | 가질 수 없음 | `com.apple.videoconference.allow-conferencing`을 임시 서명으로 붙인 바이너리는 실행 즉시 종료됨(exit 137). Device Hub와 devicectl은 이 권한을 가짐 |
| USB 화면 캡처 장치 | 발견됨 | `kCMIOHardwarePropertyAllowScreenCaptureDevices`를 켜면 약 1초 뒤 muxed 외부 장치 1개("iOS Device")가 나타남. 캡처 세션은 열지 않음 |
| Xcode MCP 기기 조작 | 실기기 불가 | 워크스페이스 없는 `DeviceInteractionStartSession`은 시뮬레이터만 대상으로 받음 |

기기가 알리는 관련 capability: `remote.hid.digitizer`·`button`·`keyboard`·`scroll`·`vendordefined`, `remote.universalhid`, `capturescreenshot`, `getdisplayinfo`, `getlockstate`, `startmediastream`, `startvideooutput`, `viewdevicescreen`. 로컬 네트워크 터널로 연결된 다른 iPhone(iOS 27.0.1)도 같은 목록을 알리지만, 그 기기에는 정보 조회와 스크린샷만 했다.

## 입력 구조

시뮬레이터와 실기기는 연결을 얻는 부분만 다르다.

| | 시뮬레이터(현재) | 실기기(제안) |
| --- | --- | --- |
| 기기 찾기 | CoreSimulator `SimServiceContext` | CoreDevice `DeviceManager.shared` → `deviceNamed(_:)` |
| 연결 얻기 | `lookup:error:` mach 포트 → `xpc_connection_t` ([Simulator.swift](../../mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src/Simulator.swift) `simulatorConnection`) | `xpcConnection(forFeatureIdentifiedBy:)` → `OS_xpc_remote_connection` |
| 보내기 | `xpc_connection_send_message` | `xpc_remote_connection_send_message` |
| 메시지 | `messageType`·`isBarrier`·`featureIdentifier`·`payload` 사전 | 같음(터치로 확인) |

- `HIDLink`의 전송 함수만 추상화하면 `touch`·`key`·`button`·`crown` 메시지 생성부를 그대로 쓸 수 있다. 터치 좌표는 화면 대비 0–1 정규화 값이 그대로 통했다.
- CoreDevice는 연결을 이미 활성화된 상태로 넘긴다. 이 연결에 `xpc_remote_connection_set_event_handler`를 다시 부르면 RemoteXPC가 프로세스를 중단시킨다. 끊김 감지는 Mercury의 `setEventHandler`나 전송 실패 확인으로 해야 한다.
- CoreDevice에는 Swift 모듈 인터페이스가 없다. 프로브는 맹글된 기호를 `@_silgen_name`으로 선언하고 자리표시 클래스로 `self`를 맞춰 호출했다(`mac-computer-use/tests/physical-device-probe/connect.swift` (local investigation tool, not shipped)). 제품에서는 이 호출을 한 파일에 가두고, 기호가 없으면 "이 Xcode에서는 실기기 조작을 쓸 수 없음"으로 실패하게 한다. `dlopen`·`dlsym`으로 늦게 묶어 Xcode가 없는 Mac에서도 mac-cu가 뜨게 한다.
- 첫 조회 전에 기기 목록이 채워질 시간이 필요하다. 프로브는 3초를 기다렸다. 제품에서는 목록 갱신 알림을 기다리는 방식으로 바꾼다.

## 화면 경로

| 경로 | 장점 | 제약 | 상태 |
| --- | --- | --- | --- |
| A. 스크린샷 반복(CoreDevice) | 공개 명령, USB·네트워크 모두, 권한 불필요 | 초당 약 1.5장. 실시간 조작감은 부족 | 실측 |
| B. USB 화면 캡처 장치(CoreMediaIO + AVFoundation) | 공개 API, 연속 영상 | USB 전용. mac-cu에 카메라 권한 필요. 프레임 속도·지연·기기 쪽 표시 변화 미측정 | 장치 발견까지 |
| C. CoreDevice 미디어 스트림(AVConference) | Device Hub와 같은 화질·지연, 네트워크도 가능 | 필요한 권한을 Apple 서명 없이 가질 수 없음. 권한 없이 동작하는지는 미확인 | 권한 단계에서 막힘 |
| D. iPhone 미러링 창 | — | 조작에 Mac 포인터·포커스를 쓰므로 조건 위반. 기기를 잠가 둬야 함 | 제외 |

실시간 LCD 창은 B를 주 경로로, A를 권한이 없거나 네트워크 연결일 때의 대체 경로로 두는 구성을 권장한다. B가 기대에 못 미치면 C가 권한 없이 동작하는지 따로 확인한다.

실기기의 `devicectl device info displays`는 `chromeIdentifier`와 `framebufferMaskIdentifier`를 준다. 시뮬레이터 LCD의 기기 외형·마스크 코드를 재사용할 수 있는지는 이 값으로 판단한다. USB iPhone 14 Pro는 디스플레이를 2개(1179×2556 켜짐, 1184×2560 꺼짐) 보고했다. 주 디스플레이 선택이 필요하다.

## 구현 단계

1. **실기기 입력 도구**: CoreDevice 연결 계층, `HIDLink` 전송 추상화, 기기 목록에 실기기 표시, 스크린샷 관찰. 터치·스와이프·키·홈/잠금 버튼을 기기별로 검증한다.
2. **USB 캡처 실측**: mac-cu 서명과 카메라 권한으로 캡처 세션을 열어 프레임 속도, 지연, 해상도, 기기 쪽 표시 변화를 잰다. 권한 요청 창은 사용자가 직접 시작한 설정 동작에서만 띄운다.
3. **실시간 LCD 창**: 2의 결과로 프레임 소스를 정하고, 시뮬레이터 LCD 창의 표시·좌표 변환·입력 가드를 프레임 소스와 분리해 붙인다.

## 위험과 남은 미확인 사항

- **비공개 기호 의존**: Xcode 27.2의 CoreDevice·Mercury 기호와 호출 규약에 묶인다. Xcode 갱신 때마다 연결 계층 검사가 필요하다.
- **서명 조건**: 임시 서명으로 확인했다. 팀 인증서로 서명한 mac-cu 본체에서는 아직 실행하지 않았다.
- **확인하지 않은 입력**: 키보드, 하드웨어 버튼, 스크롤, 두 손가락 이상 제스처, 가로 방향 좌표, 실기기에서의 연결 유지 시간.
- **잠금 상태**: `devicectl device info lockState`로 읽을 수 있다. 잠긴 기기에서 입력이 어떻게 처리되는지 확인하지 않았다. 암호 입력은 도구가 대신하지 않는 것으로 한다.
- **접근성 트리**: 실기기 화면 요소 읽기 경로는 조사하지 않았다. 기기는 `voiceover` capability와 `testmanagerd.remote.automation` 서비스를 알린다.
- **개인 기기 보호**: 실기기는 결제·메시지·계정이 실제로 동작한다. 기기별 명시 허용, 첫 연결 확인, 시뮬레이터와 구분되는 표시, 기기 claim이 필요하다. 같은 Mac에 여러 사람의 기기가 잡힐 수 있으므로 이름이 아닌 식별자로 대상을 고정한다.
- **전제 조건**: 기기 페어링, 개발자 모드, 개발자 디스크 이미지 서비스가 필요하다. 조건이 빠졌을 때의 오류 문구는 확인하지 않았다.

## 프로브

`mac-computer-use/tests/physical-device-probe/` (local investigation tool, not shipped)

- `lookup.c`: remoted에서 기기·서비스가 보이는지 확인(기기에 아무것도 보내지 않음)
- `connect.swift`: CoreDevice로 기능 연결을 받고, `drag` 인자를 주면 한 손가락 드래그 전송
- `capture-devices.swift`: USB 화면 캡처 장치 탐색(캡처 세션은 열지 않음)

빌드 예: `swiftc -O connect.swift -F /Library/Developer/PrivateFrameworks -framework CoreDevice -Xlinker -rpath -Xlinker /Library/Developer/PrivateFrameworks -Xlinker -rpath -Xlinker /Library/Apple/System/Library/PrivateFrameworks`
