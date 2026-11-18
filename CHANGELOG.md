# Changelog

## 1.2.0 — 2026-11-19

mac-computer-use 1.32.0, simulator-pilot 1.9.0.

- 동시에 켜 두는 시뮬레이터 대수에 제한을 둔다. 제한은 이 Mac의 메모리와 시동 디스크 여유 공간에 맞춰 정해진다: 메모리 8GiB마다 한 대, 디스크 여유가 30GiB 아래면 두 대, 15GiB 아래면 한 대까지. 24GiB Mac에서는 세 대이고, 그중 기본 기기 세트는 두 대까지다(한 자리는 Xcode Previews 기기 몫). mac-cu 메뉴 막대의 **시뮬레이터 동시 실행 제한**에서 자동 대신 1~8대를 직접 고를 수 있다. 설정은 `~/Library/Application Support/sim-pilot/budget.json`에 있고 mac-cu와 `sim-pilot`이 함께 읽는다.
- mac-cu가 누가 켰든(Xcode, `xcodebuild`, `simctl`, T3 기기 패널, mac-cu) 켜진 시뮬레이터를 1분마다 세어, 제한을 넘으면 메뉴 막대에 `⚠ 시뮬레이터 5/3`을 띄우고 알림을 한 번 보낸다. 메뉴에는 대수와 제한, Previews 기기, **쓰는 곳 없는 기기 지금 종료**가 나온다.
- 메뉴에서 켜면(기본은 꺼짐) 제한을 넘은 동안 15분 넘게 쓰는 곳이 없던 기본 세트 기기를 자동으로 종료하고, 어느 기기를 왜 껐는지 알림과 메뉴에 남긴다. 다음 중 하나라도 있으면 쓰는 중으로 본다: `sim-pilot` 사용 기록, 소유 프로세스가 살아 있는 T3 기기 패널(agent-device) 기록, 그 기기를 이름으로 가리키는 Mac 쪽 프로세스(`xcodebuild`, `simctl` 등), 기기 안의 UI 테스트 러너, 열린 mac-cu LCD 창. 기기 안에서 앱이 새로 뜨거나 꺼지거나, Simulator 앱이 맨 앞에 있으면 15분을 다시 센다. Previews 기기는 끄지 않는다. 읽지 못한 agent-device 기록이 있으면 아무 기기도 끄지 않는다. 종료는 기기 전원만 끄며 기기와 데이터는 남는다.
- `sim-pilot budget`이 제한, 켜진 기기(기본·Previews 세트), 기기마다 쓰는 쪽을 JSON으로 알려 준다. `--would-boot [--udid U] [--set default|previews]`는 한 대 더 켜도 되는지 답한다(되면 종료 코드 0, 꽉 찼으면 3; 이미 켜진 기기는 항상 0). `sim-pilot acquire (--udid U | --name N) [--note …] [--wait 초]`는 켜져 있는 기기는 그대로 잡고, 꺼진 기기는 자리가 있을 때만 켜고 사용 기록을 남긴다(꽉 찼으면 3, 다른 세션이 쓰는 기기면 4). CoreSimulator에는 부팅을 막는 길이 없어서, 이 명령을 거치지 않은 부팅은 mac-cu가 사후에 경고하거나 정리한다.
- mac-computer-use 1.31.1의 변경:

  - mac-cu 데몬이 큰 응답을 돌려준 뒤에도 메모리를 내놓지 않던 문제를 고쳤다. 스크린샷이나 뷰 계층 캡처(최대 32MB JSON)의 응답 버퍼가 요청이 끝나도 남아 수백 MB까지 쌓였다(실행 7분 된 데몬에서 최고 628MB, 128MB·30MB 버퍼 잔류를 확인). 요청 큐와 연결·확장·웹 인스펙터 스레드가 요청마다 메모리를 비운다.
  - 부팅된 시뮬레이터 상태를 5초마다 읽던 것을, LCD 창·상태 창·시뮬레이터 관리 창·메뉴가 보일 때만 5초마다 읽고 그 밖에는 1분마다 읽도록 바꿨다. 읽을 때마다 시뮬레이터 한 대당 `devicectl` 프로세스가 하나씩 실행되던 부하가 줄어든다. 메뉴나 창을 열면 바로 한 번 읽는다.
  - 데몬과 Chrome 확장 호스트의 연결 수락이 계속 실패할 때(파일 디스크립터 고갈 등) 쉬지 않고 재시도해 CPU 코어 하나를 차지할 수 있던 루프에 대기를 넣었다.

## 1.1.0 — 2026-11-15

- 실기기 iPhone용 `device` 도구를 추가했다. `list`로 기기를 찾아 식별자로 한 대만 허용하고, 스크린샷과 탭·스와이프·키·텍스트 입력·버튼(홈·잠금·음량)을 CoreDevice HID로 보낸다. Mac의 커서·키보드·앞 앱은 바뀌지 않는다. 암호가 필요한 잠금 상태와 가로 방향에서는 입력을 거절하고, `type`은 한 번에 200자까지다. `view`는 Xcode Device Hub를 그 기기 페이지로 열며, 화면은 사용자가 View Screen을 눌러야 시작된다. mac-cu 자체의 실기기 화면 창은 없다. 결과의 "connection drained"는 기기가 처리했다는 보장이 아니므로 스크린샷으로 확인한다. `key`·`type`은 US 배열 키 코드를 보내므로 기기의 하드웨어 키보드 배열이 다르면 다른 글자가 들어간다. iPhone 14 Pro(iOS 27.2) USB 연결에서 홈·음량 버튼, 탭, 스와이프, 폴더 탭, 숫자 입력·삭제, 스크린샷, `view`와 Mac 비간섭을 확인했다. 연결 방식별 확인 상태는 [physical-device.md](mac-computer-use/skills/mac-computer-use/references/physical-device.md)에 있다.
- 설치본을 서명할 Apple Development 인증서가 여러 개면 설치된 mac-cu와 같은 팀의 인증서를 먼저 고른다. 그런 인증서나 설치본이 없으면 환경 변수 `MAC_CU_SIGNING_TEAM`에 지정한 팀을, 그것도 맞지 않으면 이전처럼 처음 나온 인증서를 쓴다. 쓰지 않게 된 카메라 사용 설명(`NSCameraUsageDescription`)을 앱 정보에서 뺐다.

- Fix SwiftUI recording preparation failing to load its sibling Python modules when the inspector launches the helper in isolated mode. Create its request with private permissions so the observer can validate it.

- SwiftUI 기록 준비가 필요한 캡처에 명시적인 “SwiftUI 기록을 켜고 다시 실행” 버튼을 추가했다. 현재 실행 상태와 기존 실행 설정이 유지되지 않음을 표시하고, 검증된 검사 세션 해제와 새 앱 수명 확인을 거친다. 불확실한 실행 결과는 자동 재시도하지 않는다. 실제 제품 재실행 검증은 별도다.
- SwiftUI 기록 재실행에서 helper의 실제 조상 프로세스가 소유한 기기 claim을 허용한다. 다른 프로세스의 claim과 변경된 소유권은 계속 거부하며, 종료·실행 직전에 다시 확인한다. 요청 형식과 대상 수명 검증을 추가했다. 이 변경의 현재 검증 범위는 headless 검사다.

- 대상 앱의 identity 조회를 native 커널 읽기로 옮겨 Python 자식 실행을 제거했다. 기기 ID·수명·실행 경로·상태 검사를 유지하고, 조회 중 관찰한 실행 파일 변경을 거절한다. 캡처 백엔드의 독립 재검사는 유지한다.

- Prepare mac-computer-use 1.31.0 for local delivery. Canonical host manifests and catalog metadata match; marketplace publication remains separate.

- 이미 펼쳐진 LCD에는 Dock 복원을 요청하지 않는다. 비동기 복원 응답이 새 3D 검사 창의 키 포커스를 LCD로 되돌리는 경합을 수정했다.

- LCD 검사에 명시적 AX 새로 읽기, 지원 동작·값 편집과 복원 결과를 추가했다. 확인된 runtime에서 press·증가·감소·서로 다른 custom action·문자열 적용/복원을 실제 guest 상태와 대조했다.
- 별도 native 3D 검사 창에 트리·텍스처·수동 선택과 hidden/alpha 적용·복원을 연결했다. 상세 정렬, 최소 크기, 후보·선택 상태, 스크롤과 닫힘 정리를 수정했다. 실제 LCD→3D 캡처·편집·복원·재열기와 늦은 결과 거부를 검증했다. native 작업 도중의 강제 중단은 이 UI 검증의 범위가 아니다.
- 일반 앱의 schema 2 캡처·편집을 resident helper로 옮겼다. LLDB는 고정 bootstrap 뒤 detach하며, UIKit 작업은 native main-queue callback에서 실행한다. 반복 캡처, 복원, release·새 owner 전환, stale 객체 거절, 예외·취소의 메모리 해제와 실행 권한 차단을 실제 Simulator에서 확인했다.
- arm64 / Xcode 27B48 / iOS Simulator 24B114의 확인된 UIKit·표준 SwiftUI 진입을 지원한다. SwiftUI 내부 UIKit 뷰의 캡처·편집을 검증했으며, hosting texture에서 텍스트·도형이 빠질 수 있다는 제한을 검사 창에 표시한다. SwiftUI 값 타입 노드와 UIKit 뷰의 LCD 강조는 제공하지 않는다.

- Replace the simulator inspector’s initial command forms with an explicitly refreshed accessibility element list, optional filtering, coordinate-linked selection, a read-only screen picker and explicit HID tap or supported AXPress actions. Revalidate the front app and selected geometry before touch; invalidate selection after input, screen changes and closing. Keep specialist tools and drafts behind an explicit entry. Prepare mac-computer-use 1.30.1 for local delivery only.

- Recognize current simulator backlight readback so an active display is available to LCD and input workflows when `devicectl` omits the older active flag.

- Improve the LCD's related tool flows while preserving the compact connected-glass toolbar, opaque LCD and directional rotation. Environment controls display backend-confirmed values, pending requests and retry; View exposes window state and size directly. Input/location retain drafts and show local feedback. Inspection opens directly with labeled fields, guide capture and persistent results; report images, recovery and recent activity share the same result content. Coordinate transient close/Escape/focus, prevent keyboard forwarding from taking focus out of a form, and remove overlapping Watch inspection controls. Preserve manager/preview workflows while clarifying stale inventory, settings drafts and preview names. Prepare mac-computer-use 1.30.0 for local delivery only.

- Remove the standalone LCD design preview app, scenario/feedback UI and runner. Keep the production LCD as the implementation and verification path, preserve existing user feedback, and migrate directional-turn/chrome-restoration regressions into the finite native selfcheck harness. Explicitly lay out and display a newly opened LCD before its first capture. Production live floating previews remain available. Prepare mac-computer-use 1.29.8 for local delivery.

- Animate delivered simulator turns with signed clockwise/counterclockwise travel, continuous bounded retargeting and a physical-top bezel mark. Keep the common container and its layout space while temporarily hiding upper/right/lower controls during the body/LCD turn; restore controls after the final layout settles and reject stale restoration callbacks. Keep capture/guest AX at committed host geometry and guard moving desktop input; fade instead of rotating with Reduce Motion. Preserve ordered HID delivery and asynchronous observation, including the host/guest distinction on Phone and Duo. Prepare mac-computer-use 1.29.7 for local delivery only.

- Simplify the attached simulator toolbars to 44pt icons with tooltips and accessibility names. Remove the persistent ready/response footer, move response history and the last result into menus, and retain visible progress/failure indicators on the fixed device menu.

- Correct the simulator’s raised grip and toolbar silhouette: put the opaque LCD inside a regular-glass enclosure and merge that enclosure with all three raised control surfaces in one window and one shared container. Inset the top/bottom attachments to form shoulders and remove the separate capsule rims at the joins. Keep the cross-arrow grip and independent menu at 44pt, retain scrolling and guest input, and record preview source/binary hashes for build identification. Extend the joining caps into the enclosure so no pinched neck or open notch remains between body and toolbar. Prepare mac-computer-use 1.29.6 for local delivery; publication remains separate.

- Attach the simulator's glass action and task toolbars to the fitted device body, align its movable handle with that body, and keep compact controls scrollable without covering the LCD. The initial 1.29.4 placement alone did not produce a joined silhouette.
- Improve simulator control responsiveness by separating bounded display/angle observation from ordered HID delivery and safe hinge motion. Apply successfully delivered Duo host rotations immediately, admit subsequent controls after delivery/motion, reject stale observations, and skip hinge movement only for a freshly verified same target. Structured setter results explicitly distinguish delivered motion from pending guest confirmation.

- Fix visible iPhone Duo rotation: rotate the live device surface and model mask even when the guest cover stays rot0. Keep host presentation separate from guest orientation, preserve it across fold/app/input-connection changes, and use matching pointer, accessibility, screenshot, guide and preview transforms. Confirm the actual displayed surface before reporting visible rotation. Preserve compact toolbars and the integrated hinge slider.
- Prepare mac-computer-use 1.29.3 for local delivery; simulator-pilot remains 1.8.2. Marketplace publication is separate.

- Tighten native toolbar spacing: content-fit right actions, 60×44pt inline bottom items, compact popovers and resolved legacy-scroller sizing to prevent clipped icons. Preserve keyboard/AX focus, exact angle retry and persistent rotation feedback.

- Fix floating simulator preview dragging with event-based screen anchors instead of late performDrag; retain manual placement through layout updates and guard the real panel event regression under the native watchdog.

- Implement the approved native simulator LCD toolbars with grouped Liquid Glass surfaces, a right action column and bottom task row, while keeping the LCD opaque. Use one hinge slider for exact 0°/90°/180° ticks and arbitrary 1° angles; gate unsupported capabilities with visible reasons.

- Add an interactive LCD toolbar design proposal with a single right-hand column and bottom row, direct clockwise rotation, a single fine-angle hinge slider with clickable 0°/90°/180° detents, and a feature-entry classification based on Apple's Device Hub documentation.
- Prepare mac-computer-use 1.29.0 and simulator-pilot 1.8.2; publication and installed app updates remain separate steps.
- Make the simulator LCD window follow drag events directly from its visible **⠿ 이동**/device capsule. Preserve guest screen input and focus mode, clean up interrupted drags, and verify real borderless-window frame changes with guarded local AppKit events.
- Add a native **시뮬레이터 관리…** menu in mac-cu to list all devices and usage records, create compatible devices, download/import Apple runtimes, and boot a selected UDID into the existing LCD window.
- Verify actual inventory after mutations, distinguish specialized runtimes, block claimed devices and keep existing devices/data on failure or cancellation. Run long operations off the main thread with bounded output, timeout and cancellation limited to their child process group.
- Add backend, subprocess and native manager UI regression checks; document preparation separately from test app builds, installation, launch and logs.
- Apply interface-first UI design to simulator management: separate device/creation/runtime tabs, place confirmed state and actions beside the selected device, add search/state filters and distinct empty/no-match recovery, preserve failed creation drafts, and keep operation feedback outside scrolling pages. Add inline name admission, keyboard field/picker routes, runtime compatibility display and boot-in-progress waiting without duplicate boot commands.
- Finish the native design with a structured selection card, accent-colored primary actions, Control-Tab/Control-Shift-Tab task switching, and tested runtime-consent Return cancellation with focus restoration. Make the watchdog interruption test wait for actual monitoring instead of a startup-time assumption.
- Prevent recursive GUI entry in production-based test apps: preserve permission-helper dispatch, reject inherited test entry and run both LCD/manager harnesses with a parent deadline, exact executable instance budget and owned-process cleanup. Document and test the native-check safety rules.
## 1.0.0 — 2026-11-08

- Extract Mac Computer Use and Simulator Pilot into the independent Mac Pilot repository with their relevant Git history and preserved local development data.
- Deliver canonical packages directly through Codex and Claude Code `mac-pilot` marketplaces; retain manifest-relative setup, user Keychain and existing macOS permissions.
- Release mac-computer-use 1.27.0 with native borderless LCD windows, draggable handles, detachable sidebar modules, focus mode and OpenAI Decisions settings.
- Show actual synthetic connection requests, validated results, timing and errors in Settings without exposing API keys or authentication headers.
- Release simulator-pilot 1.8.1 with the independent installation source and public verification guidance.
- Make gesture checks reproducible from a clean checkout by packaging the required synthetic test helpers under tests/.
