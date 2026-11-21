# CNDF macOS 키 프로브 (F0a)

RDP 한/영 따라가기 설계(F0) 검증을 위한 단일 파일 AppKit 키 프로브입니다.

## 안전 및 개인정보 원칙

- 네트워크에 접속하지 않습니다.
- `TISSelectInputSource`, 시스템 설정 쓰기, 접근성/입력 모니터링 권한이 필요한 API(`CGEventTap` 등)를 호출하지 않습니다.
- 프로브 창 안으로 들어오는 이벤트만 관찰합니다.
- `keyCode`, 수식키 플래그(16진), 이벤트 종류, 입력 소스 ID, 언어 코드, 시각만 기록하며, 입력한 글자 내용은 남기지 않습니다.
- 뷰 B 의 `DropAllClient` 도 받은 글자를 즉시 버리고 길이와 종류만 기록합니다.
- 결과 보고서에는 사용자 이름, 홈 경로, 호스트명을 넣지 않습니다.
- 측정이 끝나면 바탕화면에 새 파일(`cndf-keyprobe-YYYYMMDD-HHMM.md`)로 저장합니다. 클립보드는 사용자가 "결과 복사" 버튼을 누를 때만 씁니다.

## 직접 빌드 (Xcode 명령줄 도구 사용 시)

```bash
swiftc -O -framework AppKit -framework Carbon KeyProbe.swift -o KeyProbe
```

## 자동 검증 실행

```bash
./KeyProbe --self-test
./KeyProbe --smoke-test
```

## 사용 방법

1. `CNDFKeyProbe.app` 을 실행합니다.
2. 창에 표시되는 안내대로 13단계를 진행합니다(쓰지 않는 전환 방법은 `Esc` 로 건너뜁니다).
3. 완료되면 바탕화면의 `cndf-keyprobe-YYYYMMDD-HHMM.md` 파일 또는 "결과 복사" 버튼으로 복사한 내용을 전달합니다.
