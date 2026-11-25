# Windows Server 인수 측정
`scenarios.py <출력 디렉터리> <Mac 시드 디렉터리> --port <역방향 터널 포트> --domain <Windows 컴퓨터 이름>`으로 `rdp-engine-harness` 입력을 생성한다. 정상 암호는 `I8_PASS`, 거부 검증에 쓰는 틀린 암호는 `I8_BAD` 환경변수로 실행 직전에 전달한다. TOFU 세 회차와 변경 거부는 엔진별 동일한 전용 신뢰 저장소에서 순서대로 실행한다.

- 텍스트, 파일, 오디오, 휠은 `Harness/windows-i8/i8probe.ps1`을 사용한다. 각 회차의 로그온 전에 `C:\i8\runid.txt`에 실행 이름을 써 두고, 각 시험 실행 후 로그를 회수하고 로그오프한다.
- 리사이즈와 드라이브는 같은 대화형 세션에서 `observe.ps1`을 실행한다. 리사이즈 서버 측 크기와 `\\tsclient\Home`에서 읽고 되쓴 값은 `C:\i8\out\<실행 이름>.server.log`에 기록된다. 드라이브 회차의 Mac 작업 폴더에 생기는 하네스 공유 폴더에 `한글-seed.txt`를 만들고, `한글-write.txt`를 하네스가 공유 폴더를 지우기 전에 확인한다.
- Win→Mac 파일 회차는 `C:\i8\src\한글-win.txt`, 끊김 회차는 그 폴더의 `cut.bin`을 사용한다. Mac→Win과 취소 회차는 Mac 시드 디렉터리의 `한글-mac.txt`, `cancel.bin`을 사용한다. 끊김 회차에서 스테이징에 파일이 생기면 해당 회차의 시험 터널을 내렸다가 복원한다.
- 한/영 키는 `Harness/windows-ime/probe.ps1`을 사용한다. Windows 한글 IME를 활성화하고 `C:\k5\runid.txt`에 회차 이름을 기록한다. `*.keys.log`에서 두 오른쪽 Option 입력과 IME 상태 변화를 확인한다.
