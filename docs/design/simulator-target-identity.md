# Native target identity

`simulatorViewCaptureTarget`는 지정된 PID를 native 커널 API로 읽는다. identity 조회에는 임시 캡처 폴더, `xcrun`, Python 또는 자식 프로세스가 필요하지 않다. 캡처·편집 백엔드와 wire schema는 바꾸지 않는다.

`proc_pidinfo`로 PID와 시작 시각을 읽고, `proc_pidpath`와 `KERN_PROCARGS2`로 실행 경로 및 대상 프로세스의 `SIMULATOR_UDID`를 읽는다. 경로를 다시 읽은 뒤 최종 상태와 시작 시각을 확인한다. 요청 기기가 일치하고 최종 상태가 running/sleeping이며 traced flag가 없을 때만 결과를 반환한다. 읽기 실패·불완전한 데이터·수명 또는 경로 변경·대상 불일치를 구분해 거절한다. main thread에서는 읽기 전에 거절한다.

경로 버퍼는 4,096바이트, 인자·환경 버퍼는 1 MiB로 제한한다. 환경에서는 `argc`개의 인자를 건너뛴 후 정확한 키 하나만 인정한다. UUID의 대소문자는 정규화하고, 중복·잘못된 표기·미종결 데이터는 거절한다. 환경과 인자는 로그나 결과에 저장하지 않는다. 경로는 `realpath`로 정규화한다. 존재하지 않는 실행 파일이나 끊어진 심볼릭 링크는 identity 확인 실패로 처리한다.

Apple의 공개 [libproc 구현](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)에서 `proc_pidpath`는 NUL을 제외한 문자열 길이를 반환한다. decoder는 해당 길이와 종결 바이트를 함께 검사한다. 공개 소스의 반환 규약과 설치된 SDK 선언을 참고했으며, 공개 소스를 현재 운영체제 바이너리의 동일성 증거로 사용하지 않는다.

두 번의 상태·경로 읽기는 원자적 exec 검사가 아니다. 같은 경로로 exec하거나 값이 바뀌었다가 돌아오는 경우를 완전히 배제하지 않는다. Python 캡처 백엔드의 attach 직전 및 복구 후 독립 재검사는 그대로 유지한다. 버퍼 크기와 읽기 횟수는 제한하지만, 커널 호출의 종료 시간을 보장하지는 않는다. native 검증은 별도 부모 watchdog 아래에서 수행한다.

모의 검사는 identity 전달, 수명 변경, 최종 상태·traced flag, 잘못된 기기, 접근 거절, 불완전한 읽기, 환경 파싱, 경로 정규화와 main-thread 거절을 확인한다. 실제 canonical caller를 추출한 별도 검사는 interpreter 호출이 0회이고 native identity가 그대로 전달되는지 확인한다. 검사 실행 파일은 helper·잘못된 인자·상속된 entry를 먼저 거절하며, 각 실행은 부모 watchdog의 15초·인스턴스 1개 제한을 적용한다.

현재 headless 검증은 모의 경계 69개, caller 회귀, 전체 canonical 소스 타입 검사·링크 및 기존 hierarchy/edit wrapper 검사를 통과했다. 타입 검사에는 기존 TLS/Keychain deprecation 경고가 남아 있다. 새 모의 검사에는 컴파일 경고가 없다.

같은 canonical 소스로 만든 격리 CLI는 이미 실행 중인 일반 Simulator의 SpringBoard identity를 독립 Python 조회와 대조했다. native 조회 및 잘못된 기기 ID 거절은 합쳐 약 3.4 ms였다. 전후의 PID·시작 시각·정규화 경로·기기 ID가 일치했고, 대상은 running/sleeping 및 untraced 상태를 유지했다. 검증 실행 파일은 정상 회수됐고 잔존 인스턴스는 없었다. 이 검증에는 GUI, 대상 실행·종료 또는 debugger attach가 없었다. 설치된 앱의 서명·실행 상태를 검증한 결과는 아니다.

이 변경은 일반 session probe의 `xcode-select` 및 display utility 실행을 제거하지 않는다. 별도 프로세스였던 identity Python의 live 관찰 조건은 새 경로에 적용하지 않는다. 기존 실패한 proof 기록을 성공으로 바꾸지는 않는다. 나머지 utility 경로와 SwiftUI 캡처·제품 UI 검증은 아직 남아 있다.
