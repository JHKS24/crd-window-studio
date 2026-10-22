# 빌드와 설치

[English](BUILDING.md) | [개요](README.ko.md)

## 준비와 빌드

macOS 14 이상, Swift 5.9 이상, Apple Command Line Tools 또는 Xcode, Python 3가 필요합니다. `swift`, `clang++`, `python3`, `sips`, `iconutil`, `codesign`을 사용합니다. 필요하면 `xcode-select --install`로 Apple 도구를 설치하세요. 개발자 계정, 외부 Swift 패키지, Google 바이너리는 빌드에 필요하지 않습니다.

소스 폴더에서:

```sh
./scripts/build.sh --all --universal
open "dist/CRD Window Studio.app"
```

`--universal`은 Apple Silicon과 Intel을 함께 빌드합니다. 생략하면 현재 Mac용입니다. `--ui`는 도우미 없이 설정 앱만, `--backend`는 네이티브 도우미, `--all`은 둘 다 빌드해 같은 아키텍처의 도우미와 관리기를 앱에 포함합니다. `--ui`는 `build/`의 이전 도우미를 재사용하지 않습니다. 공백이 있는 경로도 지원합니다.

결과는 `dist/CRD Window Studio.app`과 `build/OverlayAgent`입니다. 아이콘, 언어, 스키마, 라이선스 고지를 넣고 로컬 ad hoc 서명합니다. Developer ID 서명이나 공증된 배포 앱은 아닙니다. 설치를 위해 macOS 보안 보호를 끄지 마세요.

기존 앱을 교체할 때는 macOS 14 이상에서 지원하는 Foundation 휴지통 API를 사용합니다. `/usr/bin/trash`나 Finder, 자동화 권한 요청은 필요하지 않습니다. 새 서명 앱을 배치할 때까지 이전 앱을 보관한 뒤 휴지통으로 옮깁니다. 휴지통 이동에 실패하면 삭제하지 않고 남겨 둔 경로를 오류로 알립니다.

공개 빌드의 기본값은 ad hoc 서명(`CRD_SIGN_IDENTITY=-`)입니다. 같은 Mac에 반복 설치할 때는 이미 준비한 코드 서명 인증서를 명시적으로 선택할 수 있습니다.

```sh
export CRD_SIGN_IDENTITY="Your Local Signing Identity"
./scripts/build.sh --all
python3 scripts/companionctl.py prepare
```

이 설정으로 두 앱을 모두 서명합니다. 패키징한 설정 앱에도 선택한 인증서 이름을 기록하므로 GUI에서 도우미를 준비할 때 셸 환경 없이 같은 인증서를 사용합니다. 요청한 인증서를 찾을 수 없으면 오류로 끝나며 ad hoc 서명으로 대체하지 않습니다. 재빌드할 때 같은 인증서와 개인 키, 번들 식별자(`local.crdwindow.studio`, `local.crdwindow.host`)를 유지하세요. 표시 이름만 같고 키가 다른 인증서는 같은 서명자가 아닙니다. 설치된 앱을 교체하기 전에 `codesign -dr - "앱 경로"`로 지정 요구사항을 확인하세요. 이 선택만으로 앱이 공증되거나 손쉬운 사용 권한이 부여되지는 않습니다.

## 실제 공유 창에 적용

공식 Chrome 원격 데스크톱을 먼저 설정하고 원격 접속이 되는지 확인합니다. 기본 원본 경로는 `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app`입니다.

설정 앱은 `~/Applications/CRD Window Studio.app`처럼 이동하지 않을 위치에 보관하세요. 앱을 교체할 때는 먼저 설정 앱을 닫고, 실행 중인 도우미를 덮어쓰지 마세요.

설정 앱에서 처음 **창 도우미 켜기**를 누르면 먼저 macOS에 권한을 요청하고, 권한이 확인된 뒤에만 도우미를 설치합니다. 아직 권한이 없으면 권한 설정을 열 수 있게 안내합니다. 아래 명령은 같은 과정을 명령줄에서 하는 방법입니다.

```sh
python3 scripts/companionctl.py prepare
python3 scripts/companionctl.py permissions --prompt
```

`prepare`는 원본의 서명과 버전을 읽고 자체 도우미 번들을 준비합니다. `permissions --prompt`는 고정 설치 경로에 도우미를 준비한 뒤 독립 사용자 launchd 작업으로 **CRD Window Host** 자체를 실행해 손쉬운 사용 권한을 요청합니다. 요청 대상은 설정 앱이나 Terminal, Python이 아닌 도우미입니다.

처음 설치할 때 **시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용**, macOS 27 이상에서는 **개인정보 보호 및 보안 > 기기 제어 및 데이터 접근**에서 **CRD Window Host**를 허용하세요. 권한 요청은 비동기 방식입니다. 명령은 현재 권한 상태를 출력하고 종료하므로, 요청 직후에는 허용하기 전까지 `"accessibility": false`가 나올 수 있습니다. `--prompt` 없는 `permissions`는 권한 요청 창을 띄우지 않습니다. 두 방식 모두 임시 확인 작업을 정리하며 별도 권한 감시 프로세스를 남기지 않습니다. 도구는 권한 DB를 직접 바꾸지 않으며 화면 기록 권한은 요구하지 않습니다.

허용한 뒤 요청 없는 확인 명령을 실행하세요.

```sh
python3 scripts/companionctl.py permissions
```

`"accessibility": true`일 때만 설치를 진행하세요. 확인 명령이 성공적으로 끝나도 권한 결과는 `false`일 수 있습니다.

```sh
python3 scripts/companionctl.py install
python3 scripts/companionctl.py status
```

실제 원격 세션에서 도우미 준비와 공유 창 감지를 각각 확인하세요. 도우미 프로세스가 실행된 것만으로 원격 연결이 확인되지는 않습니다. 원본이 아직 실행되지 않았다면 대기 상태도 정상입니다.

원본 경로가 다르면 `prepare`, `permissions`, `install`에 `--host-app "/path/to/ChromeRemoteDesktopHost.app"`을 전달하거나 `CRD_HOST_APP`을 설정합니다. 원본 서명 검사는 유지됩니다. `sudo`는 사용하지 않습니다.

도우미는 `~/Library/Application Support/CRDWindowPatch/CRD Window Host.app`, 자체 LaunchAgent는 `~/Library/LaunchAgents/local.crdwindow.host.plist`입니다. 메뉴바는 도우미가 관리해 설정 앱을 닫아도 남습니다. 설정 앱의 로그인 옵션은 설정 화면의 시작을 별도로 제어합니다.

## 업데이트와 복구

새 소스를 먼저 빌드해 확인하고 설정을 백업하세요. `restore`로 자체 도우미만 종료한 뒤 필요하면 설정 앱을 교체하고 새 빌드의 `permissions`, `install`을 반복합니다. ad hoc 서명이 바뀌면 시스템 설정의 손쉬운 사용(macOS 27 이상에서는 기기 제어 및 데이터 접근)에서 이 도우미의 기존 등록을 다시 추가해야 할 수 있습니다. Google 호스트 항목은 바꾸지 마세요.

```sh
python3 scripts/companionctl.py restart
python3 scripts/companionctl.py restore
```

‘공유 창 바꾸기’를 끄면 원본 표시가 돌아오고 도우미와 메뉴 막대는 유지됩니다. ‘창 도우미 끄기’ 또는 `restore`는 도우미 자체를 종료합니다. 이전 자체 앱, LaunchAgent, 설치 기록은 한 세대로 묶어 지원 폴더의 archives에 최신 완료 세대 5개까지 보관합니다. 더 오래된 세대는 휴지통으로 옮기며 설정은 그대로 둡니다. 복원 대기나 휴지통 이동 실패 시의 예외는 [Privacy](docs/PRIVACY.md)에 있습니다.

정상 종료와 감지된 오류에서는 원본 숨김 상태를 복원합니다. 비정상 종료 후에는 자체 LaunchAgent가 최소 5초 간격으로 재시작할 수 있습니다. 권한 철회나 원본 구조 변경 등에서는 즉시 복구되지 않을 수 있습니다. 권한이 있는 상태에서 `restore`를 사용하고, 권한 복구가 필요하면 **개인정보 보호 및 보안 > 손쉬운 사용**, macOS 27 이상에서는 **기기 제어 및 데이터 접근**의 **CRD Window Host** 항목을 사용하세요. 도우미로 복구할 수 없을 때는 현장에 있는 사용자가 Google 원본 조작으로 세션을 종료할 수 있어야 합니다. 이 앱을 유일한 비상 제어 수단으로 간주하지 마세요.

`restore`가 `cleanup_failed`를 보고하면 도우미와 복원 기록을 그대로 두세요. 위 경로에서 도우미의 권한을 다시 허용한 뒤 `restore`를 재실행하세요. 이 재시도는 보관된 서명 앱으로 제한 시간 안에 복원만 수행하며, 꾸민 창을 띄우거나 원본을 다시 숨기지 않습니다. 원본 프로세스의 종료나 교체가 확인되면 권한 없이도 복원 기록을 정리할 수 있습니다. 실행 여부를 확인하지 못하거나 숨김 해제가 다시 실패하면 복원 대기 상태를 유지합니다. 검사를 우회하려고 복원 기록을 삭제하거나 수정하지 마세요.

완전히 제거하려면 `restore`와 원본 표시를 확인한 뒤 설정 앱, 필요 없어진 지원 폴더, 위 권한 화면의 도우미 등록을 제거합니다. 삭제할 설정과 내보낸 로그는 먼저 백업하세요. Google CRD 설치는 별개입니다.

## 검사

```sh
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
./build/OverlayAgent --crd-overlay-self-test
codesign --verify --strict "dist/CRD Window Studio.app"
```

네이티브 검사는 격리된 임시 fixture를 쓰며 실제 Google 호스트에 접근하지 않습니다. Python 검사는 프로세스, 서비스, 서명, 권한 동작을 모의 처리합니다. 실제 공유 중지는 연결을 끝낼 의도가 있을 때만 누르세요.

`status`의 실제 도우미 PID로 `12345`를 바꾸면 리소스를 측정할 수 있습니다.

```sh
python3 scripts/measure_resources.py --pid 12345 --duration 20   --label overlay-idle --output build/overlay-idle-resources.json
```

언어 원본은 `Sources/CRDSettingsCore/Resources/Localization/{ko,en}.json`입니다. 네이티브 헤더는 빌드 시 생성하며 사용자 입력 문구는 번역하지 않습니다. CLI의 기술 오류 출력은 일부 한국어로 남아 있습니다.

## 공개용 소스

```sh
python3 scripts/package_source.py --directory "dist/CRDWindowStudio-OpenSource"
python3 scripts/package_source.py --windows
```

첫 명령은 전체 소스 ZIP과 Git 이력이 없는 깨끗한 폴더를 만듭니다. 폴더가 이미 있으면 덮어쓰지 않습니다. 두 번째는 별도 Windows 진단 ZIP입니다. 선언된 소스, 문서, 라이선스만 넣고 일반적인 개인 경로와 자격 증명 패턴을 검사하며 SHA-256 목록을 포함합니다. 향후 추가 자료도 공개 전에 실제 출력물을 검토하세요. [공개 안내](docs/RELEASING.md)를 참고하세요.
