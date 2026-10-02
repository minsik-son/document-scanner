# 로컬 도구 전체 확인 안내

2026-09-30 · 개발 빌드. 기존 8개에 이어 남은 기능을 14개 도구로 연결했다. 이 목록은 기능의 실행 경로와 실제 구현 범위이며, CamScanner와 모든 조건에서 같은 품질이라는 뜻은 아니다.

## 진입

- 새 도구: **홈 검색창 아래 Tools 카드**.
- 열어둔 문서를 바로 사용: **문서 → Tools → More offline tools**.
- 원래 8개: 카메라의 Scan mode, 문서의 Watermark/Timestamp/ID card layout/Long image, 홈 → Tools의 QR code/Stitch screenshots.
- 기존 촬영·PDF·서명·페이지 관리 기능은 기존 위치를 유지한다. 새 도구는 사진이나 라이브러리 페이지를 읽고 결과를 사본으로 저장한다.

## 한 번에 확인할 순서

| 도구 | 확인 방법 | 실제 출력과 한계 |
|---|---|---|
| Word export | 문서 선택 → Read text → 오인식 수정 → Create Office file → Preview/Share | 실제 DOCX, 편집 가능한 문단. 표/서체/레이아웃의 완전 복원은 아님 |
| Excel export | 표 페이지 → Read text → 탭/줄바꿈으로 셀 수정 → Create Office file | 실제 XLSX. 모든 값은 문자열이며 00123 유지, 수식 실행 없음. 복잡한 표/병합 셀은 수동 수정 |
| PowerPoint export | 페이지 선택, 필요하면 all pages → 이미지 또는 editable text 선택 → Create Office file | 실제 PPTX. 이미지 모드는 원본 모양, 텍스트 모드는 편집 가능. 모든 페이지 텍스트 모드에서는 Read text로 페이지별 텍스트를 먼저 준비 |
| Translate text | 사진 OCR/텍스트 입력 → From/To → Translate offline | iOS 26 이상, 이미 설치된 지원 언어 쌍만 처리. 미설치 시 안내하고 다운로드하지 않음. 번역된 텍스트 공유; 원본 사진의 글자 교체 합성은 아님 |
| Book pages | 책 펼침 사진 → Gutter 조절 → Page curve 조절 → Preview result | 좌우 분할과 수동 원통형 곡면 보정. 단일 페이지도 가능. 복잡한 접힘/가림/소실 글자 복구는 아님 |
| ID photo | 정면 인물 사진 → 35×45mm 또는 2×2in → 흰색/파랑 → Preview | 기기 전경 마스크+얼굴 위치 기반 크롭, 300dpi 이미지와 물리 크기 PDF. 발급 기관 규정 충족 인증은 아님 |
| Smart erase | 입력 이미지에서 작은 표시를 사각형으로 드래그 → Preview | 주변 경계색 보간/가장자리 완화. 종이의 작은 표시용. 복잡한 물체/사진 배경을 생성형으로 복원하지 않음 |
| Remove colored marks | 표시가 있는 페이지 → Strength → Preview | 색 펜/형광펜 감소, 어두운 잉크 보호. 문서의 원래 컬러도 지워질 수 있으므로 비교 필요 |
| Restore photo | 사진 → Strength → Preview | 노이즈 감소·대비·채도·선명도. 찢어진 영역/얼굴을 새로 생성하지 않음 |
| Mega scan | 동일 문서의 겹치는 사진 2–8장 → Image 2 이상 선택 → Align with previous 또는 X/Y 조절 → Preview | 2D 위치 등록·캔버스 합성. 자동 정렬은 같은 크기 이미지와 검증 가능한 겹침에 한정. 원근/크기를 먼저 맞추며, 뒤 사진이 앞 사진의 겹침 영역을 덮음 |
| Count objects | 대비되는 배경의 분리된 물체 → threshold/size → Find objects → 탭으로 마커 추가·삭제 → Preview corrected count | 연결된 명암 영역 후보 + 사용자 검수. 물체 의미를 이해하는 범용 분류기가 아니며 붙은 물체는 수동 보정 |
| Measure | 지원 iPhone → Start → 표면 시작점/끝점 탭 → Export | AR 추정 거리, cm/in 표시, 미터 단위 CSV. 정밀 계측용 아님 |
| 3D scan | LiDAR 지원 iPhone → Start → 천천히 이동 → Stop → Export | 실세계 좌표(미터)의 OBJ 표면 메시. 사진 텍스처·숨은 면 복원 없음. 미지원 기기에서는 이유 표시 |
| Math calculator | 사진 OCR 또는 식 입력 → 검수 → Calculate | 사칙연산·거듭제곱·괄호·sqrt·삼각함수(라디안)·ln/log/abs. AI 문장제 풀이/증명/일반 방정식 풀이 아님 |

## 공통 검수

1. 문서를 열어 도구 실행 전후 원본이 유지되는지 확인한다.
2. 결과를 누르면 확대 화면에서 핀치 확대/축소하고 Close로 돌아온다.
3. Save PDF copy 후 라이브러리에서 새 사본을 연다. 책·지우개·표시 제거·합성 PDF는 다시 OCR을 적용하므로 글자 선택을 확인한다. 인식 실패는 별도 안내된다.
4. Office 출력은 Quick Look과 실제 Word/Excel/PowerPoint 또는 Pages/Numbers/Keynote에서 각각 연다. 서식 호환성과 복잡한 문서는 실사용 표본으로 확인한다.
5. 기기에 내려받은 사진/문서를 준비하고 비행기 모드에서 같은 작업을 반복한다. Photos/Files의 iCloud 전용 항목 다운로드, StoreKit 구매는 별도 시스템 네트워크 기능이다.
6. 번역은 Apple Translate에서 설치한 언어만 사용한다. 앱은 원격 모델/API를 추가하지 않는다.

## 자동 검증과 실기 검증의 구분

엔진/파일 형식/기본 UI는 시뮬레이터에서 검증한다. 실제 카메라, 전경 마스크의 사진별 품질, 설치 언어 번역, AR 거리, LiDAR 메시, 대형 자료의 발열·메모리, 물리 출력 규격은 실기 검증이 남는다. 코드가 존재하는 것과 이 실기 검증이 끝난 것은 구분한다.

Apple 근거: [설치 언어 전용 TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [장면 재구성 지원 검사](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction).
