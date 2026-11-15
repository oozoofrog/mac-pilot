# 실기기 USB 화면 캡처 실측

2026-11-13, macOS 27.2 / Xcode 27.2, USB 연결 iPhone 14 Pro(iOS 27.2). 입력이나 기기 설정 변경 없이 헤드리스 프로브로 측정했다. 카메라 권한은 사용자 승인을 받았다.

## 결론

**USB 캡처는 실시간 LCD 프레임 소스 후보로 적합하다.** 약 58 fps의 연속 버퍼와 IOSurface를 확인했다. 다만 실제 표시 지연, 화면 영역과 잠금 동작은 미확인이므로 제품 적용 전에 검증해야 한다. 카메라 권한 거부, USB 부재 또는 캡처 실패 시에는 기존 `devicectl` 스크린샷 반복(이전 실측 약 1.46 fps)을 대체 경로로 사용한다.

| 항목 | 결과 | 방법 |
| --- | --- | --- |
| 장치 발견 / 첫 프레임 | 0.272초 / 1.754초 | 권한 허용 후 프로세스 시작부터 경과 시간. 다른 실행은 0.357초 / 1.381초 |
| 프레임 | 583개, 10.023초, 58.065 fps | 첫 프레임부터 마지막 프레임까지 수신 시각. 샘플 타임스탬프 간격 16.7–50.2 ms |
| 연속성 | 프레임 버퍼가 계속 도착 | 입력 없이 10초 관찰. 화면 내용이 정적이었는지와 중복 프레임 여부는 미확인 |
| 크기 / 픽셀 형식 | 1180×2556, `2vuy` (422 YCbCr) | CVPixelBuffer 메타데이터. 기기 기본 해상도 1179×2556보다 가로 1픽셀 큼. 스케일링·검은 테두리·유효 영역은 미확인 |
| IOSurface | 있음 | 첫 CVPixelBuffer의 `CVPixelBufferGetIOSurface` |
| 지연 | 미확인 | 타임스탬프의 기준 시계와 실제 화면 표시 시각을 대조하지 않음 |
| 스크린샷 동시 실행 | 성공, 1179×2556 | 첫 영상 프레임 수신 후 같은 기기에 `devicectl device capture screenshot` |
| 상태 표시 영역 변화 | 상단 150행 평균 절대 RGB 차이 5.509/255 | 캡처 전과 첫 프레임 후 스크린샷 비교. 자연 변화와 캡처 부작용을 구분할 수 없음 |
| 잠금 / 절전 | 미확인 | `lockState`는 `passcodeRequired=false`, `unlockedSinceBoot=true`를 반환. 상태를 바꾸지 않음 |
| 권한 | macOS 카메라 권한 필요 | `AVCaptureDevice.requestAccess(for: .video)` 승인 후 캡처. 제품 번들의 `setup.py` Info.plist에는 `NSCameraUsageDescription`이 아직 없음 |

프로브와 빌드 방법은 `mac-computer-use/tests/physical-device-capture-probe/` (local investigation tool, not shipped)에 있다. 결과는 한 기기·한 OS 조합의 단기 측정이며 장시간 안정성, 방향 전환, 연결 해제·재연결, 다른 기기와 제품 앱 서명에서의 동작은 미확인이다. 영상은 저장하지 않았고 비교용 스크린샷은 측정 직후 삭제했다.
