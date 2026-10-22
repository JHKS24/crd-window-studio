# Windows 창 진단 소스

[English](README.md)

원래 공유 창이 표시되지 않는 환경에는 추가 도우미를 설치할 필요가 없습니다. 이 폴더는 Windows 10/11용 읽기 전용 진단 CLI 소스입니다. macOS 설정 앱의 Windows 버전이나 완성된 설정 backend가 아닙니다. 실행 파일, 상주 앱, 자동 시작 항목을 설치하지 않습니다.

## 빌드와 선택적 실행

Windows의 Visual Studio 2022 C++ Build Tools(Windows 10/11 SDK 포함)와 CMake 3.20 이상이 필요합니다. PowerShell에서:

```powershell
.\build.ps1
.\build\Release\CRDWindowProbe.exe --once
# Optional event observation; Ctrl+C stops only this diagnostic.
.\build\Release\CRDWindowProbe.exe --watch
# Optionally restrict candidates to an exact executable path:
.\build\Release\CRDWindowProbe.exe --once --exe-path 'C:\실제설치경로\remoting_host.exe'
```

`build.ps1`은 빌드만 하고 진단기를 실행하지 않습니다. 관리자 권한 요청, 서비스 설치, 정책과 보안 설정 변경을 하지 않습니다. `--watch`는 실행한 동안만 `SetWinEventHook(WINEVENT_OUTOFCONTEXT)`와 메시지 루프를 사용합니다. 타이머, 주기적 열거, DLL 주입은 없습니다. 최초 snapshot 이후 create/destroy/show/hide/location 이벤트를 받고, geometry와 visibility가 같은 중복 통지는 출력하지 않습니다. 프로세스만 새로 시작되고 창 이벤트가 전혀 없으면 다음 `--once`까지 발견되지 않을 수 있습니다.

## 출력과 한계

출력은 UTF-8 NDJSON(한 줄에 JSON 하나)입니다. 후보 process/window와 요약을 구분합니다. 창 제목, 본문, 계정 주소, 명령줄, 전체 실행 경로는 출력하지 않습니다. 내부에서는 실제 실행파일 경로를 조회해 선택적 exact-path 필터와 Authenticode 확인에 사용합니다.

- 기본 후보 executable은 `remoting_host.exe`, `remoting_desktop.exe`입니다. Chromium의 [공식 Windows BUILD.gn](https://raw.githubusercontent.com/chromium/chromium/155.0.8059.19/remoting/host/win/BUILD.gn)에 `remoting_me2me_host`의 `output_name = "remoting_host"` 및 `remoting_desktop` target이 있습니다. 버전 변경 시 이름을 다시 확인해야 합니다.
- `authenticodeTrusted`는 로컬 cache만 사용하는 `WinVerifyTrust` 결과입니다. `googleSignerDisplayNameMatched`는 해당 검증 성공과 embedded signer certificate의 표시 이름 `Google LLC`/`Google Inc` 일치를 함께 확인합니다. revocation cache 부족, catalog-only 서명, 접근 제한 등은 Google 여부를 확정하지 못할 수 있습니다. 이름 일치만으로 Google host라고 확정하지 않습니다.
- **모든 창은 candidate**입니다. Google 서명 파일에 속한 창도 특정 공유 표시창인지, 실제 원격 세션이 있는지는 이 CLI가 확인하지 않습니다. `sharingSessionConfirmed`는 항상 false입니다. 프로세스는 있어도 창이 0개인 결과가 정상일 수 있습니다.
- `GetWindowRect`의 screen 좌표를 출력하며 DPI virtualization과 보이지 않는 resize border가 포함될 수 있습니다. `visible`은 `IsWindowVisible`이며 가려짐, 최소화, 다른 virtual desktop까지 포함한 실제 사용자 가시성을 보증하지 않습니다.
- 현재 사용자 desktop의 top-level 창만 열거합니다. 다른 Windows session, secure desktop, 접근 불가능한 프로세스의 창은 누락될 수 있습니다. 권한 상승이나 다른 session 접속으로 우회하지 않습니다.
- 파일 서명 결과는 PID와 process creation time으로 cache합니다. 프로세스 실행 중 디스크 파일이 교체되면 새 `--once` 프로세스로 다시 확인해야 합니다. 실행 중인 image의 audit identity까지 검증하는 보안 제품은 아닙니다.

## 향후 Windows 포트가 필요해질 때

`schema/SettingsSchema.json`은 macOS와 같은 최신 canonical schema의 복사본입니다. **현재 CLI는 이 설정을 읽거나 적용하지 않습니다.** macOS source가 바뀌면 이 복사본도 함께 갱신해야 합니다.

1. 실제 불편한 공유창이 재현될 때 해당 Windows/CRD 버전에서 UI Automation tree와 Win32 owner PID를 읽어 정확한 식별 계약부터 정합니다. 제목이나 계정 문자열에 의존하거나 basename만으로 동작시키지 않습니다.
2. 자체 Win32 패널 또는 WinUI/WPF 창에서 공통 schema의 색상, 형상, 배치, geometry를 렌더링하고, `SetWinEventHook`/UIA observer와 디렉터리 변경 통지로 갱신합니다. Windows에 원본 표시창이 없으면 추가 상주창도 만들지 않습니다.
3. 공유 중지는 검증된 원본 control의 UIA `InvokePattern` 같은 지원 action에 사용자 직접 클릭 때만 연결합니다. 자동 click, 프로세스 종료, Google 코드 로드, 서비스 전환으로 대체하지 않습니다.
4. 숨김과 복원은 Windows에서 의미와 지원 가능성이 확인된 후 별도 동의 범위로 구현합니다. session, UAC, integrity level, UIAccess 제약을 문서화하고 모호하면 원본 UI를 유지합니다. macOS AXHidden을 Windows에 그대로 대응시킬 수 있다고 가정하지 않습니다.

현재 소스에는 창 숨김, 이동, resize, close, 입력 주입, 원격 종료, Google DLL 로드, 서비스, 권한, 자동 시작 변경 API가 없습니다. Windows 컴파일과 실행은 미검증이며 Mac의 빌드로는 이 대상을 검증할 수 없습니다. 실제 빌드와 실행은 사용자가 필요하다고 결정한 Windows 컴퓨터에서 수행해야 합니다.

## 라이선스

자체 진단 소스는 MIT 라이선스입니다. 저장소 루트의 LICENSE를 따르며 별도 Windows 소스 ZIP에도 같은 LICENSE를 포함합니다. Google 바이너리나 인증 자료는 배포하지 않습니다. Google과 제휴한 도구가 아닙니다.
