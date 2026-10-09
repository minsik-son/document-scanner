# PRD 1.0 구현·검증 현황

갱신: 2026-09-30. 기준: `../PRD.md`의 A/B 기능과 사용자가 추가 요청한 로컬 도구 범위. **기능 코드 구현과 App Store 출시 준비 완료는 구분한다.**

| 영역 | 반영한 기능 | 검증 범위 |
|---|---|---|
| 촬영 | 실시간 종이 감지, 자동/수동 촬영, 중복 억제, 플래시, 마지막 페이지, 권한 거절 시 사진 가져오기/설정 | 추적 로직·시뮬레이터 흐름. 실제 카메라 검증 필요 |
| 보정·프리뷰 | 원근/잔여 기울기/그림자 보정, 톤·밝기·대비·선명도, 같은 렌더러의 PDF/프리뷰, 확대·축소, 크롭 확대경·접근성 이동, 네 방향 Trim margins/결과 보기/Reset | 화질·픽셀 일치·텍스트 선택 및 리뷰 UI 회귀 테스트 |
| 추가 로컬 도구 | 신분증 앞뒤/한 장 배치, 워터마크/타임스탬프, 긴 PNG, QR 생성/사진 인식, 화이트보드·슬라이드 모드, 스크린샷 연결 | 로컬 엔진·원본 보존·UI 검증. 실기 카메라/인쇄/대용량 검증 별도 |
| 확장 로컬 도구 | DOCX/XLSX/PPTX, 설치 언어 번역, 책 분할/수동 곡면, 증명사진 배경/규격, 지우개/색 표시 제거/사진 복원, 2D 합성/자동 위치 제안, 보조 개수 세기, AR 측정/LiDAR OBJ, 수식 계산 | 로직 및 UI 검증 기록은 all-offline-results.txt. 번역 모델·실기 카메라·센서 검증 별도 |
| 페이지 | 추가/재촬영/복제/순서/삭제, Undo/Redo, 마지막 페이지 확인, 스캔 보정 일괄 적용 | 저장·취소·복제/이력 UI 및 데이터 보존 테스트 |
| 기존 문서 수정 | 카메라 추가 작업은 별도 임시 문서에 기록. 취소 시 기존 PDF·페이지 유지, 저장 성공 시 함께 교체 | 추가 취소/재촬영 확정 UI, 원본 보존 및 실패 롤백 테스트 |
| PDF 가져오기 | 다중 파일 순서 변경, 파일 제공자 다운로드 조정, 암호 입력, 개별 오류/재시도. 텍스트·벡터·링크 보존 | 네이티브/이미지 PDF, 올바른/틀린 암호, 회전·링크 테스트 |
| PDF 출력·도구 | 용지·방향·여백, 병합/분할/추출 사본, 압축과 실제 크기, 암호 사본, JPG/PNG 범위·해상도, 시스템 인쇄 | PDF 페이지·문자·링크·암호·압축 검증. 외부 뷰어/실제 프린터 필요 |
| 서명·주석 | 그리기/가져오기/선택 저장, 위치·크기, 텍스트·펜·형광펜, 색·굵기·삭제·Undo, 편집 메타데이터 보존 | PDF 출력 및 Pro 도구→주석 저장 UI. 인증서 서명/redaction 아님 |
| OCR | 오프라인 다국어 인식, 자동 선택 가능한 PDF, 페이지별 수정·TXT, 전체 TXT, 취소·완료 페이지 캐시 | 한글 혼합·다중 문자 체계·PDF 좌표·수정 UI. Vision 미지원 언어는 제외 |
| 검색·정리 | 제목/본문 검색, 첫 일치 페이지 이동, 폴더·즐겨찾기, 목록/격자, 양방향 스와이프 휴지통 | 검색 이동/복원/양방향 삭제 UI. 대규모 검색 성능 목표는 미측정 |
| 휴지통 | 30일 정리, 남은 일수, 복원, 영구 삭제 확인, 참조되는 원본 보호, OCR 캐시 정리 | 기간·공유 자산 보존·삭제 실패 테스트 |
| 백업 | v2 스트리밍, 헤더/자산 SHA-256, 손상·잘림·추가 데이터 거절, 추가 복원, 중복 건너뛰기/둘 다 유지, v1 호환, 재사용 서명 opt-in | 무결성·호환성·중복·원본 보존 테스트. 대용량 실기 프로파일링 필요 |
| 앱 잠금 | LocalAuthentication, 생체 인증/기기 암호, 시트 포함 잠금 창, 앱 전환 가림 | 컴파일·코드 연결 완료. 생체 인증/앱 전환 타이밍은 실기 미검증 |
| 구독 | 월 USD 4.99/연 USD 29.99 동일 Pro, StoreKit 실제 표시 가격, 구매·복원·만료·검증된 grace, 결제 뒤 작업 재개 | 로컬 StoreKit 가격/구매/만료 및 Pro 작업 UI. 실제 Sandbox 시나리오 필요 |
| 보존·취소 | 원본 분리, 메타데이터 원자적 저장, 실패 시 기존 PDF 유지, OCR/내보내기/가져오기/백업 취소, 오래된 미참조 파일 정리 | 실패 주입·재실행·손상 데이터 테스트. 모든 전원 차단 시점 보장은 아님 |

## 현재 제한과 선택한 정책

- PDF 한 파일 1–100페이지, Photos 한 번에 50장. 50/100장 실기 메모리·발열·완료 시간 목표는 아직 측정하지 않았다.
- OCR는 기기 Vision 엔진의 지원 언어 범위다. 모든 언어·필기·수식·읽기 순서를 완벽하게 처리한다는 뜻이 아니다.
- PDF 암호: 8–32자 ASCII. 보호 결과를 잠금/해제로 재검증한다. 비ASCII 비밀번호는 명확히 거절한다.
- 가져온 PDF를 이미지 보정/텍스트 수정하면 해당 출력 페이지는 이미지 기반으로 바뀔 수 있다. 용지 변경/주석 출력은 대화형 폼을 평면화할 수 있어 UI에서 알린다. 원본 PDF 자산은 유지한다.
- 재사용 서명 이미지 배경 제거는 제공하지 않는다. 투명 이미지 사용을 안내한다.
- 백업은 **비암호화**다. 체크섬은 손상 검사이며 기밀성이나 발신자 인증을 제공하지 않는다. v1 JSON 복원은 인코딩된 파일 280MB 한도, v2는 파일 스트리밍이다.
- 구독은 검증된 거래와 Apple grace 기간만 인정한다. PRD의 제안이었던 임의 7일 연결 유예는 적용하지 않았다.
- OCR 완료 페이지는 재사용하지만 모든 종류의 작업을 자동으로 재개하는 영속 작업 스케줄러는 아니다. 중단한 촬영/편집은 Unfinished scans에서 이어서 완료한다.
- 핵심 흐름은 구현했지만 전체 VoiceOver/Dynamic Type·작은 기기·백그라운드·대용량 수용 테스트가 완료된 것은 아니다.

## 출시 전 남은 항목

- [ ] 실기 iPhone 촬영·오프라인·메모리·발열·생체 잠금·VoiceOver 및 큰 글씨 검증
- [ ] 실제 파일 제공자 실패/공유 취소, AirPrint, Apple Files/Preview/Adobe Acrobat 호환성
- [ ] 실제 App Store Connect 상품 및 Sandbox 갱신·grace·환불·복원 테스트
- [ ] 최종 앱 이름/아이콘/번들 식별자, 공개 개인정보처리방침·개발자 연락처, 스토어 메타데이터
- [ ] 서명/배포·TestFlight와 PRD 성능 목표 및 100페이지 문서 벤치마크

팩스, 클라우드 협업/동기화, 태그, 임의 곡면의 완전 자동 복원, 후속 UI 번역은 완료 주장에 포함하지 않는다. Office 변환과 수동 책 곡면 도구는 추가됐지만 원본 레이아웃 완전 복원은 보장하지 않는다.

자동 검증의 실행별 결과와 남은 범위는 `Verification/prd-implementation-results.txt`를 참조한다.

## 2026-10-01 Office 변환 흐름 비교 및 개선

경쟁 앱 A iPhone 미러링에서 Word/Excel/PPT의 스캔·사진·기기 파일·앱 내 문서 진입을 확인했다. 개인정보 문서 대신 Chrome 폴더의 일반 부동산 도면 PDF로 변환을 시험했다. Excel은 여러 시트, 셀 선택/편집 도구와 도면 이미지 배치를 표시했다. PPT는 변환 후 재생/미리보기/내보내기 화면으로 이동했으나 이번 파일의 미리보기 본문은 공백이었다. Word는 기기 PDF 선택 후 DOCX 준비 및 백그라운드 변환 UI를 거쳐 원본 도면/배치가 있는 미리보기와 텍스트 편집기를 표시했다. 이 샘플에서는 편집기의 세로 제목 줄바꿈이 흐트러지고 빈 페이지가 생겨 경쟁 앱도 원본 배치를 완벽하게 복원하지는 못했다. 화면 관찰만으로 네이티브 앱의 내부 엔진이나 서버 호출을 확인했다고 주장하지 않는다. 경쟁 앱 A 공식 웹 Word/Excel 변환 안내는 클라우드 처리를 명시한다.

반영:
- Word: 여러 사진을 순서대로 선택, 촬영/PDF 입력, 페이지별 텍스트 검토, DOCX 페이지 나눔 보존, 생성 후 미리보기/공유.
- Excel: 촬영/여러 사진/PDF/저장 페이지 선택 → 로컬 표 인식 → 셀 편집 → XLSX 생성 → 미리보기/공유. iOS 26 Vision 문서 인식으로 행·열·병합 셀을 복원하고, 구형 OS 또는 표 미검출 시 위치 기반 OCR 추정임을 안내한다. 여러 표는 별도 시트, 앞자리 0/사용자 입력 수식 문자열은 텍스트로 보존한다. 행/열 추가와 병합 해제 가능.
- PPT: 촬영/다중 선택/순서 변경 → 출력 방식 선택 → 원본 이미지 슬라이드 생성 또는 텍스트 추출·검토 → 생성 → 미리보기/공유. 원본 이미지 방식은 편집 가능한 텍스트로 오인하지 않도록 설명한다.
- 단계마다 하단 주 행동 하나. 취소/뒤로 가기는 입력을 유지하며, 입력 선택만으로 라이브러리에 저장하지 않는다.

한계: 로컬 Word는 텍스트와 페이지 구분을 보존하며 원본 그림·폰트·표 레이아웃을 복원하지 않는다. Excel은 셀 중심으로 복원하며 원본 도면 이미지/서식/수식을 재구성하지 않는다. PPT 편집 모드는 텍스트 슬라이드이며 원본 그림/배치 복원이 아니다. 경쟁 앱 A와 동일한 레이아웃 복원 엔진 구현 완료를 의미하지 않는다. 입력은 최대 30페이지, 파일당 100MB, 표별 1,000행/100열/20,000셀 범위이며 실제 인식은 언어·촬영 품질·OS에 따라 달라진다.

참고: (경쟁 앱 웹 문서) · (경쟁 앱 웹 문서) · (경쟁 앱 웹 문서) · https://developer.apple.com/documentation/vision/recognizedocumentsrequest

검증: AdvancedOfflineTests 23개와 Office UI 흐름 5개가 통과했다. 실제 표 이미지 인식, 병합 셀/다중 시트 OOXML, 텍스트 안전성, DOCX 페이지 나눔, PPT 순서·삭제·편집 모드, 생성 후 공유와 Quick Look을 확인했다. 최종 시각 검증 자료는 `Verification/office-flow-comparison-20261001/`에 저장했다. iPhone 대상 서명 없는 빌드도 성공했다. 실제 기기 카메라 촬영·외부 Microsoft Office 앱 호환성 전체를 검증했다는 의미는 아니다.

## 2026-10-01 번역·수식 진입 흐름 재검수

- 이전 공용 도구 폼은 사진 선택/OCR/실행을 한 화면에 배치했으며, 경쟁 앱 A와 같은 촬영 진입 흐름을 충족하지 못했다. 앞선 로직·버튼 검증을 전체 사용자 흐름 검증으로 해석하면 안 된다.
- iPhone 미러링에서 경쟁 앱 A의 사진 번역과 수식 아이콘을 각각 눌러 카메라로 바로 진입하는 것을 확인했다. 번역은 상단 언어 선택, 수식은 수식/시험지/잘못된 질문 선택, 두 화면 모두 중앙 셔터와 보조 가져오기 구조였다. 미러링의 카메라 사용 제한 때문에 실제 촬영·인식 결과 비교는 하지 못했다.
- 두 도구를 CameraTextToolView로 분리: 카메라 → 자동 OCR → 원본 이미지/인식 내용 검토 → 번역 또는 계산 → 결과. 사진은 보조 버튼, 파일/직접 입력/문서 페이지는 More 메뉴에 둔다. 촬영·인식·뒤로/취소는 라이브러리 저장을 하지 않는다.
- 번역은 iOS 26 이상에 이미 설치된 Apple 언어 모델만 사용하며 자동 다운로드/외부 번역 서버는 사용하지 않는다. 모델 미설치 시 입력을 유지하고 안내한다.
- 수식은 로컬 산술 계산기다. OCR 후 식을 수정하거나 여러 줄 중 하나를 선택한다. 분수 레이아웃 복원, 필기 수식 완전 인식, 대수방정식/문장제 풀이를 구현한 것으로 간주하지 않는다.
- 입력 PDF는 첫 페이지를 읽고 다중 페이지이면 이를 명시한다. 문서 상세에서 진입한 경우 More의 문서 페이지 선택으로 다른 페이지를 사용할 수 있다.

- 검증: 시뮬레이터 UI 3개(수식 카메라/OCR/결과/재촬영/미저장, 번역 카메라/OCR/모델 미설치 시 입력 유지, 수동 수식 입력 및 Word 회귀)와 산술 단위 테스트 통과. 오류 안내는 스크롤 아래로 묻히지 않도록 실행 버튼 위에 표시하고 별도 UI 테스트 재통과. 카메라 센서는 테스트 이미지로 대체했지만 OCR은 실제 엔진을 실행했다. 실제 iPhone 대상 컴파일 성공. 설치된 언어로 번역 성공 및 실기 촬영 품질은 이 검수에서 확인하지 않았다. 증거: `Verification/camera-text-tools-20261001/`.

## 2026-10-01 사진 번역 → 레이아웃을 유지하는 스캔본 재구성

- Translate text를 Photo translation으로 변경. 카메라/사진/파일 → 기존 문서 감지·원근/조명/선명도 보정 → 위치별 OCR → 설치된 언어로 영역별 번역 → 원문 잉크 제거 및 동일 영역 내 번역문 조판 → 비교 미리보기/PDF 사본 저장·공유.
- 원본은 유지하며 모든 수정은 보정된 원본에서 다시 합성한다. 표·사진·비텍스트 영역을 다시 생성하지 않는다. OCR 상자만 믿고 지우지 않고 주변 배경 및 실제 잉크 픽셀을 분석한다. 복잡한 배경/겹친 영역/지나치게 긴 번역은 원문을 유지하고 사용자에게 표시한다. 일부 미처리 영역이 있는 공유 파일은 Partially translated document로 명명한다.
- 문서 검토에서 네 모서리 크롭 수정, 원문/번역문 영역별 수정, 원문 유지 선택, 결과 확대 및 원문 스캔 비교를 제공한다. PDF 선택 레이어는 실제 조판된 번역문 좌표로 만든다. 교체된 영역의 원문 OCR을 숨겨서 남기지 않는다.
- 제한: 한 번에 한 페이지(20MP, OCR 400영역/번역 입력 20,000자). PDF 가져오기는 첫 페이지임을 알린다. 폰트는 근사하며 글자 폭·위치에 맞춰 크기를 조절한다. 문서의 원본 폰트/굵기/단락 의미·줄바꿈·세로쓰기·사진 속 글자를 완벽하게 재현하는 엔진은 아니다. 원문에 인식되지 않은 글자는 그대로 남는다. 설치 언어가 없는 기기에서는 번역을 성공한 것처럼 처리하지 않는다.
- 검증: 엔진 4개 테스트 통과(실제 보정+OCR, 표 선/컬러 배경/이미지 픽셀 보존, 한글 번역문 PDF 추출, 원문 숨은 텍스트 제거, 긴 번역·겹친 영역 보호, 재합성 좌표). UI에서 촬영→보정→수동 번역 수정→레이아웃 미리보기→PDF 공유 통과. 자동 번역은 실제 설치 모델이 없어 입력 보존/오류 경로만 검증했다. 예시 전후 이미지는 지정된 번역문을 사용하는 합성 테스트이며 번역 모델 품질 검증이 아니다.
- 증거: `Verification/photo-translation-20261001/translation-original-layout.png`, `translation-reconstructed-layout.png`, UI 화면 및 실행 로그. 실기 촬영 품질·설치 언어 모델 결과·복잡한 실제 문서 전반은 별도 검증 대상이다.

## 2026-10-01 수식 스캔 · 텍스트 문서 내보내기

- Math calculator를 Math scan으로 변경했다. 카메라/사진/파일 → 문서 감지·원근/조명/선명도 보정 → 스캔 검토(원본 비교/확대/네 모서리 크롭) → 전체 줄 OCR 및 편집 → 형식 선택 → 파일 미리보기/공유 순서로 진행한다. 각 단계에는 하나의 주 행동이 있다. 수동 산술 입력·계산기는 카메라 More의 Type expression에 유지했다.
- 기존 첫 줄만 계산하는 경로를 교체했다. 모든 OCR 줄을 유지하고, 수식 변수명이 사전 단어로 교정되지 않도록 이 도구에서만 언어 교정을 끈다. 인식되지 않은 내용은 사용자 입력으로 보완할 수 있다. 크롭을 바꾸면 전사문이 초기화됨을 확인하고 다시 추출한다. 외부 AI/API/서버를 사용하지 않는다.
- 내보내기 5종: UTF-8 TXT, 편집 가능한 텍스트 DOCX, 선택 가능한 텍스트 PDF, RTF, HTML. HTML은 내용을 이스케이프한다. PDF는 내용 길이에 맞춰 페이지를 나누고 보정된 스캔을 별도 참고 페이지로 붙이는 옵션을 제공한다. 임시 작업/취소/재촬영은 라이브러리에 자동 저장하지 않는다. 공유에서 Files로 저장 가능.
- 중요한 미구현 범위: **전용 수식 구조 인식 모델은 추가되지 않았다.** 현재 사진 OCR의 초안을 검토·수정해 내보내는 기능이며, 손글씨·위첨자·분수·행렬·적분의 2차원 구조를 자동 LaTeX/MathML/Word OMML로 복원하는 엔진은 아니다. DOCX는 Word 수식 개체가 아닌 편집 가능한 텍스트다. `(a+b)/(c+d)`, `x^2`, `sqrt(x)`처럼 직접 교정할 수 있다. 원래 수식 모양은 PDF 참고 스캔 이미지로 보존된다. 한 번에 한 페이지를 처리하며 다중 페이지 PDF 가져오기는 첫 페이지임을 안내한다.
- 검증: 엔진 4개 테스트 통과(실제 문서 보정→OCR 두 줄 유지, TXT/DOCX/RTF Unicode 보존 및 HTML escape, PDF 한글/수학기호 선택 텍스트 및 원본 추가, 긴 PDF 180줄 전체 보존/페이지 분할, 빈/초과 입력 거절). 최종 UI 테스트 통과(카메라→보정→전체 텍스트→PDF 생성→Quick Look→공유창 닫기→재촬영→취소→빈 라이브러리). 수동 산술 입력 및 Word 내보내기 기존 UI 회귀도 통과. iPhone용 unsigned 빌드 성공.
- 테스트 카메라는 인쇄체 테스트 이미지를 공급하고 실제 보정/OCR/파일 생성을 실행했다. 실제 카메라 센서·손글씨·복잡한 수식 정확도는 검증하지 않았다. 초기 UI 검수 실패(검토 토글/공유창 닫기 선택자)는 해결 후 최종 통과. 증거: `Verification/math-document-20261001/`, 최종 UI `/tmp/math-document-ui-verified.xcresult`.

## 2026-10-01 사진 번역 재배치 보강 — 일반 스캔과 분리

- 수정한 앱 파일은 `PhotoTranslation.swift`, `PhotoTranslationView.swift`이며 추가 파일은 `PhotoTranslationLayout.swift`다. 작업 전후 전체 기존 Swift 파일의 SHA-256 비교로 이 범위를 검증했다. 일반 Camera→PDF의 DocumentProcessing/Imaging/TextRecognition/PDFExport 및 수식 스캔 경로는 수정하지 않았다.
- 사진 번역에서만 OCR의 정렬·줄 높이·간격·픽셀 장애물을 이용해 이어지는 줄을 문단으로 묶는다. 열/표 선/다른 글자 영역을 가로지르는 병합을 막고 원래 줄 상자를 별도로 보존한다. 따라서 번역 입력은 문단이고 잉크 제거는 각 원래 줄에서 수행한다. 제목/버튼처럼 짧은 영역은 개별 처리한다.
- 종이 경계색이 조금 다르다는 이유로 전체 영역을 거부하던 조건을 제거했다. 연결된 잉크 픽셀과 긴 선을 구분하고, 깨끗한 위·아래 경계색을 보간해 잉크만 복원한다. 표 선·다른 OCR 영역은 보호한다. 복잡한 사진 배경에서 글자를 안전하게 분리할 수 없으면 원문을 남기고 사유를 표시한다. 사진 안의 모든 배경을 완벽히 복원하는 생성형 인페인팅은 아니다.
- 좁은 OCR 상자 경계 겹침은 분할해 번호/기울어진 줄의 오검출을 줄인다. 번역문이 길면 다른 텍스트/그림/선을 침범하지 않는 빈 공간으로 확장하고, 맞는 크기가 나오면 중단한다. 시작 가장자리를 유지하며 줄바꿈·폰트 크기를 조정한다. 비어 있는 공간 확인 없이 글자 칸 전체를 덮지 않는다.
- 번역은 8영역씩 처리하고 실패한 배치는 개별 재시도한다. 이미 얻은 번역은 보존하고 미수신 결과만 재시도할 수 있다. 결과 화면은 누락/상자 겹침/배경 분리/공간 부족을 구분하고 사용자 원문 유지/번역이 원문과 같은 경우도 별도로 센다. 실패 영역 필터, 개별 번역문 복사, 전체 번역 텍스트 공유를 추가했다. 배치 실패를 번역문 부재와 혼동하지 않는다.
- 검증: 사진 번역 엔진 8개 테스트 통과(문단/열/표 선 구분, 좁은 간격·그림자 처리, 표·그림 픽셀 보존, PDF 한글 텍스트 레이어, 원문/수정 후 재합성, 실패 분류, 사용자 설명서 스크린샷의 본문 재배치). UI 2개 통과(수동 번역→재구성→PDF 공유, 긴 번역 배치 실패→문제 영역 필터→내용 유지·복사). 일반 PDF 저장 2페이지 OCR/저장 회귀 테스트 통과. 최종 iPhone unsigned 빌드 결과는 증거 폴더 로그 참조.
- 사용자 설명서 테스트는 이미 일부 번역된 스크린샷에서 문서 부분을 추출하고 남은 주요 영어 본문에 지정된 한국어 번역을 넣는 배치 검증이다. 자동 번역 모델의 번역 품질/원본 사진 전체에 대한 19→N개 개선 수치를 검증한 것은 아니다. 작은 프로그램 UI 글자의 OCR 오류, 복잡한 배경 및 정확한 원본 폰트 재현은 여전히 제한이 있다. 원본 영역이 남으면 이유와 사용 가능한 번역을 검토 화면에서 확인한다.
- 증거: `Verification/photo-translation-reflow-20261001/`. 최종 엔진 `/tmp/translation-reflow-verified.xcresult`, UI `/tmp/translation-reflow-final.xcresult`, 일반 PDF 회귀 `/tmp/translation-reflow-tests.xcresult` 내 해당 통과 테스트. 초기 설명서 겹침 실패를 재현한 뒤 수정했고 최종 엔진은 모두 통과했다.


## Photo translation quality follow-up — 2026-10-01

Selected-language + close-up OCR, word-gap column separation, mixed-script paragraph boundaries, ink-based font sizing, missing batch response retry, and source snippets added only to photo translation files. 15 tests passed; installed-model test skipped (simulator assets absent). iPhone target build succeeded. The latest user PDF regression uses six supplied translations, not a verified full automatic translation. See `Verification/photo-translation-quality-20261001/README.md` for scope and limits.

## 마케팅 검토 반영 (2026-10-07, 기준: `../마케팅 리포트/06_개발_전달사항.md`)

| 체크 id | 반영 내용 | 검증 범위 |
|---|---|---|
| trial-families | `ProFeature`에 pdf / redact / fillForm 추가, 묶음별 한도 3·3·3·3·1·1, 기기당·묶음 안 공유 | 단위 테스트 `testFamilyLimitsAndAdUnlockOncePerDay`, `testPDFAndSmartToolFamilies` 통과 |
| trial-entry | 모든 진입점(Tools 탭, 홈 Quick tools, 문서 Tools 메뉴)이 `ProTrialGate`를 거침. 무료 사용자는 결제 화면 대신 체험 화면, 체험 없는 Auto-save만 결제 화면 | UI 테스트 `testProToolFreeTriesThenUpgrade` 갱신(실행 미확인), Min 실기 빌드·실행 |
| pdf-before-pick | PDF Pro 도구는 문서 선택 전에 체험 화면 | UI 테스트 `testPDFProToolShowsFreeTryBeforeChoosingADocument` 추가(실행 미확인) |
| trial-on-success | 체험은 결과가 나왔을 때만 차감: 결과 화면(`ToolDonePage`), Office 내보내기·저장, 번역/수식 결과, 양식 저장. 열고 나가면 차감 없음 | 코드 연결. UI 테스트에서 "열고 나가기 = 3회 그대로" 확인 |
| (추가) lock-view | 체험 남음: "Try free (N left)" 주 버튼 + "Upgrade to Pro" 보조 + "Files you make with a free try are yours to keep." / 소진: "Upgrade to Pro" 주 버튼 + 보상형 광고 보조 | 실기 화면 확인 필요 |
| tools-badges | Tools 그리드 배지 "N free" / PRO / Pro 사용자 없음. 체험 차감·광고 보상 시 즉시 갱신 | 실기 화면 확인 필요 |
| me-benefits | My benefits에 6개 묶음 + No ads + Auto-save, "Scanning, PDF, text recognition and signing are always free." | 실기 화면 확인 필요 |
| paywall-ocr-slide | "Text from any page" 삭제, "Auto-save to iCloud Drive or Dropbox", "Unlimited signatures & merges" 추가, 신뢰 문구 교체 | UI 테스트에서 OCR 슬라이드 없음 확인 |
| paywall-context | `PaywallView(start:)` — 기능별 슬라이드부터 시작, 광고 링크는 "No ads"부터 | UI 테스트(Word, Compress) |
| lifetime-price | 평생 카드에 "FOUNDING PRICE · N DAYS LEFT" 리본, 정가 취소선(USD 59.99 / KRW 79,000), "Launch price until …". Me 배너에도 표시. `FoundingOffer.launchDay` 출시일 설정 필요(Debug는 출시 7일 차로 미리보기, Release는 설정 전 숨김) | 실기 화면 확인 필요 |
| home-ad-move | 홈 광고를 문서 3번째 아래(적으면 목록 끝)로 이동, 상단은 원래 스캔 카드. 카드 높이 축소(미디어 120×120) | 실기 화면 확인 필요 |
| remove-ads-link | 홈·Tools 광고 카드 아래 "Remove ads with Pro" → `PaywallView(start: .noAds)` | 실기 화면 확인 필요 |
| first-24h | 설치 후 24시간 광고 숨김(`AdTiming`, 기존 설치는 Documents 폴더 생성일 기준) | 코드 연결 |
| rewarded | 소진 화면 "Watch a short ad · 1 more use", 묶음당 하루 1회, 광고 준비 안 되면 버튼 숨김, Google 공식 테스트 단위 | 단위 테스트(하루 1회). 실제 광고 표시는 실기 확인 필요 |
| no-interstitial | 저장 후 전면 광고 계속 꺼 둠(`completionAdEnabled: false` 유지) | 기존 코드 유지 |
| third-save-card | 3번째 저장 후 홈에 1회성 "Try Pro free for 7 days" 카드(닫으면 다시 안 뜸) | 코드 연결 |
| share-filename | 공유 PDF 파일명 = 문서 제목.pdf, Creator/Producer = FoldScan (문서, 신분증, 저장 직후 공유) | 단위 테스트 `testSharedPDFNameIsCleaned` |
| review-prompt | `ReviewPrompter`: 3번째 저장, Pro 도구 결과 첫 공유, 구매 다음 날, 각 1회 | 코드 연결 |
| (추가) privacy-copy | 개인정보 화면 광고 문구를 새 배치(홈·Tools·선택형 보상 광고, 첫날 없음)로 수정 | — |
| (추가) l10n-new | 새 문구 35개를 15개 언어에 추가(복수형 포함) | 형식 지정자 검사 |

미반영/보류: StoreKit 설정의 평생 가격은 출시가 $39.99 유지(출시 한정가를 앱에서 미리 보여주기 위해; 정가 $59.99는 App Store Connect 가격 일정으로), CFBundleDisplayName(최종 이름 미정), String Catalog 전환(이미 15개 언어 .strings 운영), 분석 SDK(개인정보 라벨 영향으로 출시 전 결정), 위젯·App Intents.

테스트: 단위 테스트 9개 중 8개 통과. 실패 1개 `testUSPricesVerifiedPurchaseAndExpiration`(108행, StoreKit 만료 전파 대기)는 이번 변경과 무관한 기존 StoreKit 테스트.

## 심사 대비 (2026-10-08, 기준: `../마케팅 리포트/07_심사_위험_수정.md`)

| 체크 id / 항목 | 반영 내용 | 검증 |
|---|---|---|
| A1 개발 문구 | 설정 "About this build" → "About": `AppInfo.name` + Bundle 버전(빌드). 개발 안내 문구·테스트 광고 문장은 `#if DEBUG` 안으로 | Release UI 테스트 `ReviewScreensUITests.testReviewScreens`가 설정 화면에 "development" 없음 확인, 스크린샷 `review-shots/4-settings-bottom.png` |
| A2 링크 | `AppInfo.privacyPolicy`·`support`·`terms` 한 곳. 설정에 Privacy policy·Contact support·Terms of Use, 결제 화면 하단 Terms·Privacy(URL)·Restore purchases, PrivacyView 하단 전문 링크. 페이지 초안 `../docs/privacy.html`·`support.html`(GitHub Pages) | 단위 테스트 `testAppNameAndPublicLinksAreConfigured`(https·host 검사), 결제 화면 하단 스크린샷 |
| A3 Privacy manifest | `PrivacyInfo.xcprivacy` 추가(앱 타깃 리소스). Tracking false, 수집 없음, UserDefaults CA92.1, 파일 타임스탬프 C617.1(앱 컨테이너 안), 부팅 시간 35F9.1. 디스크 공간 API 미사용. Google Mobile Ads 13.11.0은 자체 manifest 포함 | plist 형식 검사. Archive → Privacy Report는 미실행(수동) |
| app-name | 표시 이름 FoldScan, 앱 내 이름은 Info.plist에서 읽음(`AppInfo.name`). Bundle ID `com.foldscan.app`, 상품 ID `com.foldscan.pro.monthly/yearly/lifetime`(StoreKit 설정·코드·UI 테스트) | `testAppNameAndPublicLinksAreConfigured`, Release 빌드 |
| A5 결제 표시 | 창립가 리본·취소선·남은 일수는 `FoundingOffer.applies(to:)`: 평생 상품 + 기간 안 + StoreKit 실제 가격 < 해당 통화 정가일 때만. 출시일은 `FoundingOffer.launchDay` 한 곳(nil이면 Release에서 숨김). 체험·갱신 문구는 StoreKit 값 | Release 결제 화면 스크린샷(launchDay 미설정 → 리본 없음) |
| tool-rename | Smart erase → Spot eraser (rawValue, 15개 언어, UI 테스트, 문서) | `testToolSectionsCoverEveryToolOnce`, UI 테스트 `testHubListsAllToolsAndHonestDeviceRequirements` 통과 |
| tools-sections | Tools를 Before you send / Fix a page / Turn it into / Capture more / Camera utilities로 재구성(`ToolSection.all`). Fill a form은 Before you send에 둠. Count objects 숨김 유지. Auto-save는 Me(설정)의 자동 저장 항목 | `testToolSectionsCoverEveryToolOnce`, UI 테스트 통과, 스크린샷 1–3 |
| ip-comments | 코드 주석 5곳 중립 표현 | `grep -ri camscanner ios/DocumentScanner` 0건 |
| ip-docs | `CAMSCANNER-LOCAL-TOOLS.md` → `competitor-tool-survey.md`, 추적 문서·검증 기록의 이름을 "경쟁 앱 A"/"Competitor app A"로 | 추적 파일 중 마케팅 리포트 외 0건 |
| C1 번역 | 언어 미설치 시 오류 대신 안내 화면(`TranslationLanguageGuide`, 단계별, 입력 유지). 다운로드 안 함 정책 유지. iOS 26 미만은 타일 탭 시 안내, 진입 시 체험 소모 전에 안내 | 스크린샷 `7-translation-guide.png`(DEBUG 실행 인자로 띄움, 뷰는 Release와 동일) |
| C2 AR/LiDAR | Measure(AR)·3D scan(LiDAR) 타일은 지원 기기에서만 표시 | 시뮬레이터에서 두 타일 미표시 확인 |
| C3·C4 | 보상형 광고는 로드됐을 때만 버튼 표시(유지), 체험 알림 권한은 체험 시작 후에만 요청·거절해도 영향 없음(현행 확인) | 코드 확인 |
| D 심사 메모 | `AppReviewNotes.md` (연락처 빈칸) | — |

남은 결정: 지원 이메일, GitHub Pages 게시(저장소 Settings › Pages › main /docs), AdMob 실제 ID(현재 Release는 광고 꺼짐), `FoundingOffer.launchDay`, 마케팅 버전(현재 0.1.0).

이름 변경(2026-10-08): FoldScan → **HushScan**. 표시 이름, Bundle ID `com.hushscan.app`(테스트 `.tests`/`.uitests`), 상품 ID `com.hushscan.pro.monthly/yearly/lifetime`, 문서·개인정보 페이지 반영. 마케팅 버전 1.0. 위 표의 FoldScan 표기는 당시 기록.

광고 켜기(2026-10-08): AdMob 앱 HushScan(`ca-app-pub-9921649727270589~5824656756`), 광고 단위 Home native·Tools native·Extra free use rewarded. Release는 실제 단위, Debug는 Google 데모 단위. Google 동의 메시지(UMP)가 끝나기 전에는 광고를 요청하지 않음, EEA 등에서는 설정에 "Ad privacy choices"(15개 언어). SKAdNetwork(Google) 추가. 개인정보 페이지 광고 문단 갱신. HomeAdvertisementTests를 첫 24시간 규칙에 맞게 수정(통과). CompletionAdvertisementTests 실패 2건은 전면 광고를 끈 마케팅 반영 이전부터의 것(전면 광고는 사용 안 함).

## 스크린샷 캡처 중 발견 수정 (2026-10-08, 기준: `../마케팅 리포트/09_버그수정_가격적용_프롬프트.md`)

| 항목 | 반영 내용 | 검증 |
|---|---|---|
| A1 미리보기 위치 | 원인: `ExtractRender.page`가 `getDrawingTransform`(확대 안 함)을 써서 작은 PDF 페이지가 큰 그림의 한쪽 구석에 작게 그려짐. 탐지(2000px)와 미리보기(1400px) 그림의 비율이 달라 상자가 왼쪽·위로 밀림. 명시적 배율로 수정, 미리보기·저장 모두 `Redaction.place` 한 함수 사용 | `ScreenshotFixesTests.testRenderedPageFillsThePicture`, `testSampleFormRedaction`(SSN·카드·이메일·보험번호·전화 줄 위에 상자) |
| A2 저장 크기 | 같은 원인. 이제 그림이 페이지 전체를 채우고 mediaBox는 원본과 같음. 결과는 텍스트 층 없는 이미지 PDF(가린 글자 재인식도 안 됨) | `testSampleFormRedaction`(페이지 크기 동일, PDF 텍스트·OCR에 6789/7731 없음), `review-shots/redacted-sample.pdf` |
| A3 탐지 누락 | 라벨(ID·member·policy·account·customer·subscriber·patient·계좌·회원번호·보험·고객번호·가입자·증권번호·환자번호) 뒤 숫자 4자리 이상을 "ID number" 후보로 추가(기본 켜짐, 탭해서 끔). 날짜·연도는 제외 | `testLabelledMemberNumberIsFound` |
| A4 테스트 | 단위 테스트 + UI 테스트 `ScreenshotFixesUITests.testRedactSampleForm`(DEBUG `--seed-image`로 샘플 사진을 저장 문서로 추가) | 통과 |
| B1 언어 감지 | 인식된 모든 텍스트 영역을 합쳐 `NLLanguageRecognizer`로 판정(확률 ≥ 0.6), 감지 언어로 다시 인식. 낮으면 "감지 못 함 — 언어를 골라 주세요", 번역 버튼 비활성 | `testFrenchLetterIsDetected`, UI `testTranslationDetectsFrench`(French) |
| B2 언어 이름 | `LanguageName`이 앱 언어 기준으로 표시·정렬. 한국어는 "한국어로 번역"처럼 조사 처리 | `testLanguageNamesFollowAppLanguage`, 한국어 화면 캡처 |
| C 번역 누락 | 하단 탭 "Documents", "Folders" 등 30여 개 문자열 15개 언어 추가. 칩·문서 종류·폴더 이름을 런타임에 번역. 압축 문구 키를 `%@`로. 날짜·기본 스캔 이름을 앱 언어 형식으로(`Date.appFormatted`, `ScanDocument.defaultTitle`). 홈 제목 줄바꿈, "텍스트"·"자르기" 칩 한 줄. 도구 타일 VoiceOver 라벨 번역 | `Tools/missing_strings.py`(14개 언어 모두 남은 것은 형식명·기호뿐), UI `testKoreanScreens`, `testOtherLanguagesHaveNoEnglish`(13개 언어 홈·문서·도구에 번역되지 않은 영어 원문 없음) |
| D1 단수형 | `pagesText(n)` → "1 page" / "n pages", 다른 언어는 기존 키 | `testSinglePageWording` |
| D2 날짜 순서 | 숫자 날짜가 모호하면 문서 언어(유럽어는 일/월) → 기기 지역(US 등은 월/일) 순으로 판단, 안 되면 이름에 날짜를 넣지 않음 | `testNumericDateOrder` |
| D3 서명 안내문 | 안내문을 저장 버튼 위(actions 영역)로 옮김 | 코드 확인 |
| D4 스캔 버리기 | 페이지가 있는 새 스캔에서 닫기 → "이 스캔을 버릴까요?" 확인 | 코드 확인 |
| E1 창립가 | `FoundingOffer.endDay` = 2026-12-17 한 곳. 남은 일수·리본은 이 날짜로 계산, 지나면 숨김. 리본 "FOUNDING PRICE · ENDS DEC 17"(15개 언어). 정가 USD 59.99 / KRW 79000. 정가를 아는 통화는 StoreKit 가격이 정가보다 낮을 때만 리본+취소선, 그 밖의 통화는 기간 안이면 리본과 "Launch price until Dec 17"만(취소선 없음, 08 문서 방식) | `testFoundingOfferEndsDecember17`, `testFoundingRibbonInEveryCurrency`, UI `testPaywallFoundingRibbon`(en·ko) |
| E2 StoreKit | 구독 그룹 "HushScan Pro", 참조 이름 Pro Monthly/Yearly/Lifetime, 표시 이름·설명 영어·한국어(08 문서 3절), 가족 공유 끔. 가격 $4.99 / $29.99(1주 무료) / $39.99 확인 | storekit JSON 검사, SubscriptionTests |

추가: 결제 화면 하단 갱신 안내문이 번역되지 않던 것(`Text(String)`) 수정, 한국어 결제 화면도 영어 잔존 검사에 포함.

전면 광고(completionAdEnabled)는 계속 꺼 둠. Release 아카이브 성공.

## UI 테스트 정비 (2026-10-08)

오래된 UI 테스트를 현재 화면에 맞게 고쳤다. 단위 테스트와 UI 테스트 7개 묶음(56개)이 시뮬레이터(iPhone 17 Pro, iOS 26.2)에서 통과한다. 건너뛰는 테스트는 2개: 네트워크 광고 테스트, 그리고 Release 빌드 전용인 심사 화면 캡처.

- 모든 UI 테스트는 `-app-language en`으로 실행한다. 시뮬레이터에 저장된 앱 언어와 무관해진다.
- 공통 베이스 `HushUITestCase`: 실패할 때마다 화면 요소 트리와 스크린샷을 첨부한다.
- 지연 로딩 목록(설정, 홈 문서 목록)은 스크롤해서 찾는다. 공유 시트는 시스템 언어와 무관한 `activityCollectionView`로 확인한다.
- 테스트로 찾은 앱 수정:
  - Sign & annotate: 마킹 안내 문구가 스크롤된 버튼 위에 겹치던 문제(배경 추가).
  - 큰 글씨 페이월: "Unlimited access" 고정 폭 때문에 화면 전체가 옆으로 넘치던 문제.
  - 시작 화면 문구가 앱 언어가 아닌 기기 언어로 나오던 문제.
  - Debug 빌드 설정의 "Development preview" 문구 삭제.
  - 문서 Tools 메뉴 항목 현지화.
  - 식별자 추가: `document-edit`, `tools-close`.
- 남은 실패 1건(이번 변경과 무관): `PageAdjustmentsTests.testHighResolutionPreviewPreservesExportInkAndColoredCells`. 문서 톤에서 미리보기의 글자/색이 최종 PDF보다 옅다(잉크 누락 약 26%, 허용치 초과).

## 사진 → Word/Excel/PowerPoint 정밀도 (2026-10-09)

사진 속 표를 세 형식으로 똑같이 다시 만드는 작업. 정답지와 자동 비교하는 테스트 `OfficeFidelityTests`를 만들었다(`Verification/private/samples/fidelity/`, git 제외). 샘플마다 사진·정답 JSON(셀 글자, 병합, 채우기 색, 정렬, 레터 용지 위 표 위치)이 있고 `score.py`가 세 파일을 채점한다. `summary.py`로 전체 표를 본다.

**1차 샘플 8개** — 사용자의 지점 IP 표 사진 2장(정면, 비스듬히 겹쳐 놓은 것) + 위키백과 데이터로 만든 표 3종 × 사진 2종(정면, 비스듬):
글자 99.9% · 병합 100% · 색 99.6% · 표 위치 오차 0.11인치 이내, 세 형식 모두.

**2차 샘플 6개**(지하철 노선·KBO 순위·캐나다 인구; 겹친 종이, 어두운 사진, 가로 용지 포함) — 약점이 드러남:
| 샘플 | 글자 | 원인 |
|---|---|---|
| canada 정면 (가로 용지, 파란 머리글) | 97% | 머리글의 흰 글자 윤곽이 세로줄로 잡히던 문제 → 고침 |
| canada 겹침 | 66% | 열이 더 쪼개짐(머리글 "Province / territory"의 단어 사이) |
| seoul_subway (진한 색 셀 + 흰 글자) | 67% | 첫 열이 "1호선"의 글자 사이에서 둘로 쪼개짐; 흰 글자 일부 미인식 |
| kbo (가로줄만 있는 표) | 23% | 세로줄 없는 표의 열 구분이 8열을 4열로 묶음 |

고친 것: 진한 색 셀을 비우는 단계에서 흰 글자가 낸 구멍을 닫고(dilate→erode), 셀 테두리만 남김. 1,531개 회귀 코퍼스는 변화 없음(글자 오류율 0.155→0.150, 표 지표 소폭 상승).

남은 일(우선순위 순):
1. 세로줄 없는 표(kbo)의 열 묶기 — 숫자 열이 좁을 때 글자 정렬로 열을 나누는 기준 보강.
2. 흰 글자 셀 안에서 단어 사이 간격으로 열을 쪼개는 문제(subway, canada 겹침) — 색이 같은 한 셀 안의 간격은 열 경계로 보지 않기.
3. 가로 사진의 용지 종류: 캐나다 샘플이 레터 가로(11×8.5)인데 A4 가로로 잡힘(원근 보정 뒤 비율 0.707). `physicalSize`의 가로 판정 보강.
4. 흰 글자 OCR: 진한 셀의 글자는 반전해서 한 번 더 읽기.

## 스캔 직후 변환 바 (2026-10-09)

스캔을 저장한 화면(그리고 문서 화면) 아래에 바를 추가: **PDF · Word · Excel · PPT · 이미지**.
- Word·Excel은 이 문서의 모든 페이지(30쪽까지)를 바로 읽어 확인 화면으로 들어간다. PPT는 슬라이드 방식 선택 단계로, 이미지는 기존 "이미지로 내보내기"로 간다.
- Word·Excel·PPT는 도구 탭과 같은 Office 무료 체험(3회, 파일을 만들 때 1회 차감)을 쓰고 이후 Pro. 무료 사용자에게는 왕관 표시. 이미지·PDF는 무료.
- 도구 탭에서 들어가는 기존 경로는 그대로.
- 확인 화면(Word·Excel)은 인쇄 모양 그대로의 페이지 전체를 먼저 보여주고, 탭하면 전체 화면 확대.
- UI 테스트: `ScannerFlowTests.testSavedScanOffersConversionsAndWordReviewShowsWholePage`.

## 검토 화면 리뉴얼 + 저장 시트 (2026-10-09, 목업 확정안)

- 검토 화면: 위쪽 가운데 문서 이름(탭해서 이름 변경). 도구 한 줄: 자르기·필터·조정(각각 편집기의 해당 탭으로 열림)·회전(그 자리에서 90°)·다시 찍기·더 보기. 썸네일을 길게 눌러 끌면 순서 변경. "더 보기"에 순서 편집 목록(VoiceOver용)과 PDF 옵션. 아래는 "페이지 추가"(연속 촬영) + "저장".
- "저장" → 형식 시트: 파일 이름, PDF로 저장(무료), Word·Excel·PowerPoint(무료 3회 → Pro, 다 쓰면 자물쇠와 Pro 안내), 이미지(무료), PDF 옵션. 어떤 형식이든 PDF를 먼저 보관함에 저장한 뒤 그 변환을 바로 연다(Word·Excel은 바로 읽기, 시트에서 이미 골랐으니 무료 체험 안내 화면은 건너뜀).
- 저장 후 화면의 변환 바는 시트와 겹쳐서 제거, 문서 화면의 바는 유지. 저장된 문서를 편집할 때는 예전처럼 "변경 사항 저장" 한 번.
- UI 테스트: `testSaveSheetConvertsToWordAndReviewShowsWholePage`; 기존 "Save PDF" 탭은 `savePDF(in:)`(저장 → PDF로 저장)로 바뀜.

## 시작 로고 애니메이션 끊김 수정
- 원인: 로고가 APNG 프레임을 메인 스레드 콜백으로 교체했는데, 같은 시간에 광고 SDK(UMP·MobileAds 시작·홈 광고 요청), 라이브러리 열기, 홈 첫 렌더가 메인 스레드를 막았다. 덮개가 로고가 끝나기 전에 사라질 수 있었고, 페이드 도중 앱 전체 다크→라이트 전환이 일어났다.
- 로고: `SplashAnimation`(StartupView.swift)이 Blender 장면(splash.blend)의 키프레임(`SplashMotion.swift`, anim.json에서 생성)을 CALayer + CAKeyframeAnimation으로 재생한다. 렌더 서버가 돌리므로 메인 스레드가 바빠도 프레임이 빠지지 않고, 120Hz 기기에선 120Hz(`CADisableMinimumFrameDurationOnPhone`). 동작 줄이기에선 마지막 프레임.
- 덮개: `StartupCover`가 UIKit 페이드(렌더 서버)로 사라진다. 로고가 끝까지 재생된 뒤(`SplashClock`, 최대 4초) 0.15초 쉬고 페이드.
- 페이드가 끝난 뒤에만: 라이트 모드 전환, 접근성 트리 노출, `startupCovered` 해제(홈 광고 슬롯이 이때부터 요청), 0.6초 뒤 광고 SDK 시작.
- 측정(디버그 전용): `--measure-splash`면 `SplashMetrics`가 메인 스레드 프레임 지연을 기록, `testStartupLogoHasNoHitches`가 읽는다. `testStartupLogoFrames`는 `--splash-time`으로 멈춘 프레임을 찍어 Blender 렌더와 비교(평균 픽셀 차 1.6–6/255).
- 이전 APNG(`art-splash.dataset`)는 더 이상 쓰지 않는다.

## 검토 화면: 저장 전에 형식 고르기 + 개인정보 가리기
- 저장 시트(형식 고르기)를 없애고, 저장 버튼 위에 형식 한 줄(PDF·Word·Excel·PPT·이미지)을 둔다. 기본 PDF, 마지막 선택을 기억(UI 테스트 세션별로 따로). 버튼 문구가 형식을 따른다("Save as PDF", "Convert to Word"…). Office 무료 횟수 표시, 다 쓰면 결제 화면. '페이지 추가'는 저장 왼쪽.
- 도구 줄: 자르기·필터·조정·회전·**가리기**·더 보기('다시 찍기'는 더 보기 안).
- 가리기(`RedactionEditor.swift`): 열면 이 문서의 모든 페이지에서 개인정보(주민·면허·여권·카드·계좌·전화·이메일 등)를 찾아 검은 상자로 표시. 상자 탭 = 보이게/가리기, 글자 탭 = 그 단어 가리기, 드래그 = 영역 가리기, 상자 안을 끌면 이동, 모서리를 끌면 크기 조절, 두 손가락으로 확대·이동, 실행 취소. 처음 가릴 때 무료 1회 소모(Pro 무제한).
- 저장(`PageRedaction.swift`): 페이지 편집 값(`ScanPage.redaction`)으로 저장. 회전·여백 변경은 정확히 따라감. 자르기나 톤을 바꾸면 상자는 그대로 덮은 채 저장 전에 확인 화면을 다시 연다.
- 모든 결과물에 적용: 렌더(`Imaging.render`/썸네일)에서 검게 칠하고, 글자 인식 결과와 PDF 텍스트 층·Excel·검색 텍스트에서 가린 영역의 단어를 뺀다(`visibleTextBlocks`). 가져온 텍스트 PDF 페이지도 가리면 다시 그려서 원래 글자가 남지 않는다.
- 보관함 안의 원본 사진은 다시 편집할 수 있도록 남는다(앱 밖으로 나가는 PDF·Office·이미지에는 없음).
- 테스트: `RedactionTests`(좌표 왕복, 텍스트 제거, PDF 픽셀, 회전, 가져온 PDF, 재제안 방지), UI `testHideOnReviewCoversFoundNumbersAndDraggedArea`, `testFormatRowConvertsToWordAndReviewShowsWholePage`.

## 가리기 방식 · 형식별 버튼 색 · 메가스캔 카메라
- 가리기 방식(`RedactionStyle`): 검은 상자 / 지우기(상자 바깥 테두리에서 가장 많은 색 = 종이색으로 채움) / 모자이크(글자 한 줄 높이에 3칸 정도의 큰 블록). 편집기 위 세그먼트로 고르고 마지막 선택을 기억, 문서 안 모든 페이지에 같은 방식. 어떤 방식이든 픽셀은 바뀌고 글자는 텍스트 층에서 빠진다. 편집기 미리보기와 저장 결과가 같은 그리기 함수(`RedactionPatch`)를 쓴다.
- 저장 버튼 색: PDF는 기존 파란 버튼, Word 파랑(#2B579A)·Excel 초록(#217346)·PPT 주황(#D24726)·이미지 보라(#7C3AED), 형식 줄 밑줄도 같은 색.
- 메가스캔: 원인 — '사진 찍기'가 시스템 카메라(한 장)라 한 장만 돌아오고, 2장 미만이라 첫 화면에 머물렀다. 이제 전용 연속 촬영 카메라(`MegaCamera.swift`): 찍어도 카메라에 머물고, 직전 사진의 오른쪽(또는 아래) 1/3이 흐리게 남아 겹치게 맞춘다. 방향(오른쪽/아래) 선택, 마지막 사진 되돌리기, 2~8장, '합치기 N'으로 기존 자동 정렬·합성 화면으로.
- UI 테스트 `testMegaScanCameraTakesSeveralShotsAndCombines`(시뮬레이터는 포스터 조각을 가짜 촬영).
