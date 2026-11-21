# CNDF macOS 키 프로브 (F0a + UF3)

RDP 한/영 따라가기(F0, V-H) 및 한글 유니코드 보조 경로(UF3, V-U2) 검증을 위한 단일 파일 AppKit 키 프로브입니다.

- 기본 실행 모드: **UF3 (V-U2, 뷰 C)** — macOS 2벌식 한국어 입력기가 `NSTextInputClient` 에 호출하는 순서(`setMarkedText`, `insertText`, `unmarkText`, `doCommand(by:)`, `hasMarkedText`, `discardMarkedText`)를 13단계로 기록합니다.
- `--mode vh` 옵션: 기존 선행H F0a(V-H, 뷰 A/B) 13단계 모드로 실행합니다.

## 안전 및 개인정보 원칙

- 네트워크에 접속하지 않습니다.
- `TISSelectInputSource`, 시스템 설정 쓰기, 접근성/입력 모니터링 권한이 필요한 API(`CGEventTap` 등)를 호출하지 않습니다.
- 프로브 창 안으로 들어오는 이벤트만 관찰합니다.
- 입력한 글자 내용은 결과 파일·클립보드에 남기지 않습니다. 뷰 C 의 조합 구조는 UTF-16 단위 수, 스칼라 수, NFC 스칼라 수, 자모 개수, 문자 범주(한글 음절/자모/한자/공백/제어/BMP 밖 등)와 호출 순서·시각(ms)으로만 기록합니다.
- 결과 보고서에는 사용자 이름, 홈 경로, 호스트명을 넣지 않습니다.
- 측정이 끝나면 바탕화면에 새 파일(`cndf-keyprobe-uf3-YYYYMMDD-HHMM.md`)로 저장합니다. 클립보드는 사용자가 "결과 복사" 버튼을 누를 때만 씁니다.

## 직접 빌드 (Xcode 명령줄 도구 사용 시)

단일 아키텍처:

```bash
swiftc -O -framework AppKit -framework Carbon KeyProbe.swift -o KeyProbe
```

Universal(`arm64` + `x86_64`) + ad-hoc 서명:

```bash
swiftc -O -target arm64-apple-macos13.0 -framework AppKit -framework Carbon KeyProbe.swift -o KeyProbe-arm64
swiftc -O -target x86_64-apple-macos13.0 -framework AppKit -framework Carbon KeyProbe.swift -o KeyProbe-x86_64
lipo -create -output KeyProbe KeyProbe-arm64 KeyProbe-x86_64
codesign --force --sign - KeyProbe
```

## 자동 검증 실행

```bash
./KeyProbe --self-test
./KeyProbe --smoke-test
```

## 사용 방법 (UF3 / V-U2)

1. `CNDFKeyProbe.app` 을 실행합니다(처음 실행 시 Gatekeeper 격리 해제가 필요하면 `xattr -dr com.apple.quarantine CNDFKeyProbe.app` 을 실행합니다).
2. 2벌식 한글 입력기로 전환한 뒤 창에 표시되는 안내대로 13단계를 진행합니다(단계 6 은 `Esc` 키를 측정하므로, 건너뛰기는 하단의 "건너뛰기" 버튼을 사용합니다).
3. 각 단계는 동작 후 자동으로 넘어가며, 하단 "다음 단계" 버튼으로 바로 넘길 수도 있습니다. 단계 10 은 조합 중 하단 "강제 확정" 버튼을 누릅니다.
4. 완료되면 바탕화면의 `cndf-keyprobe-uf3-YYYYMMDD-HHMM.md` 파일 또는 "결과 복사" 버튼으로 복사한 내용을 전달합니다.
