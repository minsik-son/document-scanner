# Document Scanner — native iOS development build

English-first SwiftUI app, minimum iOS 18. Independent of the unrelated `../../ios` project. Scope and verification are tracked in `IMPLEMENTATION-STATUS.md`; this is not an App Store release.

## Run

1. Open `DocumentScanner.xcodeproj` in Xcode 26.2 or newer and choose the DocumentScanner scheme.
2. Run on an iPhone or simulator. Real camera/biometric/printer verification requires hardware.
3. The existing development team is preserved in `project.yml`. The Xcode StoreKit configuration simulates purchases without billing a card.
4. Regenerate the project with `xcodegen generate` after adding files or editing project.yml. Xcode resolves the pinned Google Mobile Ads package for the home test-ad slot.

## Implemented workflows

- Offline camera with live document edges, manual/optional automatic capture, duplicate suppression, flash, recent-page thumbnail, denied-permission settings/photo-import actions and durable page saves.
- Capture → automatically processed review → per-page tone/brightness/contrast/sharpness/cleanup → Add page or Done. Cancel discards only that new shot; enlarged-view Close leaves edits intact. Originals remain immutable.
- Shared full-resolution processing for preview, OCR and PDF, cached smooth adjustments, perspective/grid/text alignment, shadow/paper cleanup preserving colored ink, crop corners with a magnifier and VoiceOver movement actions, full-screen pinch/pan/double-tap zoom.
- Page add/retake/duplicate/reorder/delete, Undo/Redo, accessible earlier/later actions, last-page confirmation, explicit all-page appearance application for scans. Camera edits of existing documents use a separate recovery draft; Cancel leaves the saved document and PDF unchanged.
- Date-based name fallback, folder, A4/Letter/Original, margins and landscape. Native PDF pages fitted to a common sheet retain vector text and transformed links; form flattening is explained before changes.
- Ordered multi-file imports with per-file password/error/retry, coordinated file-provider downloads and independent copies. Native PDF text/vector/link pages are preserved through ordinary merge/reorder/rotation; image edits explicitly warn about rasterization. Import currently accepts 1–100 pages per PDF; Photos accepts up to 50 selections.
- Automatic on-device multilingual OCR with selectable Unicode text in free PDF exports. Per-page text correction, TXT export, body/title search and matching-page navigation. Completed OCR work is cached for interrupted exports; cancellation cannot commit a partial replacement PDF.
- Pro tools: merge, split and page extraction as new copies; compression presets with actual before/after size; password-protected export copies; editable signature/text/pen/highlight objects, optional reusable signatures. All-page TXT sharing is also Pro. Basic image export with page ranges/JPEG/PNG/resolution and system printing are free.
- Home list/grid, folders/favorites, both-direction native swipe Trash actions, Settings-only unfinished scans, recoverable Trash with 30-day retention and confirmation for permanent deletion.
- Streaming unencrypted backups with header and per-asset SHA-256 validation, rollback on failure, skip/keep-both conflicts, transfer timestamp, opt-in reusable signature inclusion. Version-1 JSON backups remain readable; new version-2 archives avoid the former 200 MB source-assets buffer limit.
- App lock through LocalAuthentication (Face ID/Touch ID/device passcode), covering windows/sheets while locked and hiding app-switcher content. Actual hardware authentication/privacy timing is a release gate.
- StoreKit 2 verified purchase/restore/expiry/renewal-off/billing-grace status. US test products are $4.99 monthly and $29.99 yearly in one group; UI prices come from StoreKit. Existing documents stay usable after expiry; no unverified extra seven-day entitlement is granted.

## Persistence, security and limitations

The atomic versioned `library.json` index is committed after unique protected assets are written. Failed writes leave existing records/PDFs intact. Edits to saved documents stage camera additions separately and replace the PDF/index only after successful completion. Interrupted drafts remain recoverable. Unreferenced UUID image/PDF files older than 24 hours are cleaned on app launch; current/referenced assets are retained. OCR caches are excluded from device backups and removed with permanent document deletion.

Restoration validates a staging archive and then appends newly named files and records without overwriting the library. New files are rolled back on failure. Version-2 archives contain magic, header length, a JSON manifest/asset table, SHA-256 header digest and streamed assets. Checksums detect corruption; they are not encryption or sender authentication. Saved reusable signatures are excluded unless opted in; signatures already placed in documents are retained. Legacy JSON import has a 280 MB encoded-file safety limit. Large-library memory/thermal performance and main-thread final restore commits still require profiling.

PDF password export verifies a locked output and successful password unlock before sharing. The platform writer supports 8–32 printable ASCII characters in this implementation; unsupported passwords are rejected, never silently exported unprotected. External PDF-viewer encryption/selection compatibility remains a release gate. Imported form editing, certificate signatures and secure redaction are not provided. Local Office export supports page-separated editable Word text, reviewed Excel cell grids (including iOS 26 table/merge recognition and a labeled OCR fallback), and image or text slides. Office screens separate input, review/output choice, creation and sharing. Layout changes/annotations may flatten PDF forms with notice; original imported assets stay in the library/backup.

OCR covers the languages exposed by the installed Vision engine, not every world language. Current tests include Korean/mixed text and several other scripts; handwriting, complex reading order, curved pages, severe blur and glare have no perfect-recovery guarantee. No pixels or text are generated by an external AI service.

No account or document server. Debug builds include Google AdMob test ads for Free users on home and at eligible saved-document completion transitions. No scan, document name or OCR content is passed to the advertising module. Google may process device/network/ad interaction data; this is separate from document processing. App data can be included in Apple's device backup according to device settings. Local save messages do not claim cloud backup. Shared temporary files are cleaned after transfer or expiry.

## Home native video test ads

- Official sample App ID: `ca-app-pub-3940256099942544~1458002511`. Official native video test unit: `ca-app-pub-3940256099942544/2521693316`. These never monetize and require no publisher account.
- Run a Debug build online with a Free StoreKit account. The home introduction remains visible while loading and on failure/offline. The SDK media view starts muted and includes Ad attribution, AdChoices and the advertiser's CTA. A video fill is not guaranteed; image ads are displayed in the same slot when returned.
- Advertising waits for verified entitlement resolution. Pro, locked/background states, covered home, and offscreen slots do not request/display ads. Camera, review, PDFs and tools continue offline. Scrolling/navigation retains a loaded ad for up to 55 minutes. Only visibility/playback changes; Pro, lock and completion suppression clear the cache. A failed request is throttled for 60 seconds. Loading starts only after home is visible and scrolling has been idle for two seconds. The introduction and ad reserve the same height to avoid scroll jumps.
- Automated UI tests disable advertising by default. For an isolated manual SDK check, launch with `--ui-test-session <unique-id> --seed-saved --test-native-ad-sdk`. No private documents are needed.
- Release builds intentionally do not initialize or request ads. Before live release: register the real AdMob app/native/interstitial units, implement UMP consent and required privacy-options entry before SDK startup, configure current SKAdNetwork entries, complete SDK/App Store privacy disclosures and publish the privacy policy. Test consent denied, no fill, purchase/restore, background, small screens and physical-device playback. Do not switch sample IDs alone and treat it as production-ready.

References: [native ads](https://developers.google.com/admob/ios/native/advanced), [test units](https://developers.google.com/admob/ios/test-ads), [consent](https://developers.google.com/admob/ios/privacy).

## Saved-document completion test ads

- Official interstitial test unit: `ca-app-pub-3940256099942544/4411468910`. Uses the same Debug-only SDK/entitlement gates as native ads. No revenue or live ad requests.
- Placement: a home-origin scan/import/resumed draft must finish writing its PDF successfully, then the user taps Done on the saved screen to return home. Share, camera, editing, cancellations, failed saves, document viewing and tools do not trigger an interstitial.
- First completion exempt. Opportunities are completion 4, 7, 10, …; at least 600 seconds between actual presentations, maximum two per local calendar day. Counters persist across launches. A missed opportunity is consumed, never deferred to interrupt home later.
- Only an already loaded ad younger than 55 minutes may present. Never wait on network at Done; load/no-fill/presentation failures immediately continue home. Pro, unresolved entitlements, offline, inactive and locked states are rechecked at Done.
- After presentation, the home native slot stays on the introduction card until the next document task starts. SDK owns the interstitial dismissal UI and duration.
- Unit tests cover frequency, persistence, eligibility changes, late loading, cancellation, presentation failure and suppression. The first-save UI flow checks that saved confirmation precedes Done and home returns immediately. Isolated UI-test sessions use a separate preferences suite for counters.

Verification: 10 focused unit tests and the first-save UI test passed; the unsigned iPhone build passed. An isolated simulator session seeded at three completions displayed the official SDK interstitial after Save PDF → Done, persisted completion 4 / presentation 1, and returned to home with its introduction card. Screenshots: `verification/completion-interstitial-test-ad.png`, `verification/home-after-completion-ad.png`.

Reference: [Google interstitial integration](https://developers.google.com/admob/ios/interstitial).

## Launch and home scrolling

Library index decoding and startup file maintenance run off the UI actor, before publishing the store, so maintenance cannot race an import/edit. Corrupt/newer libraries skip cleanup and preserve their files. Saved home rows use the actual saved PDF for thumbnails instead of repeating photo enhancement. Draft thumbnails use the full-quality renderer on a serial background actor. Final thumbnails are cached in bounded memory and a disposable, backup-excluded disk folder; page appearance and source file metadata invalidate the cache. Startup trims disk thumbnails to 64 MB. Export and editor quality are unchanged. Verification (2026-10-01): 33 focused unit tests and two UI flows passed across targeted runs. The SDK scroll flow dismisses the validator link, asserts real upward movement, then checks the same ad object and request count of one after three scroll cycles. Saved-PDF thumbnails bypass photo processing; cache tests cover memory/disk reuse and source/appearance invalidation. The unsigned iPhone build passed. Physical-device frame-time and cold-start profiling remain release checks.

## Release gates

- Physical iPhone capture/auto-edge alignment, focus/low-light, app lock, background interruption, VoiceOver and Dynamic Type on small/older devices.
- 50–100-page performance/thermal/memory benchmarks, large libraries and file-provider failure tests.
- External viewers, encrypted-PDF readers and a real AirPrint printer.
- Real App Store Connect products, billing retry/grace/refund/offline/cross-device Sandbox scenarios; local StoreKit tests are not production billing validation.
- Final name/icon/bundle identity, public privacy policy and developer support/contact, App Store metadata, signing/distribution and TestFlight.
- Remaining roadmap: fax, cloud collaboration/sync, tags, fully automatic arbitrary book dewarping, target-size compression and later UI translations. The local Office/ID/book/tool subset below is now implemented with stated limits.

## Verification

Run `xcodebuild test -project DocumentScanner.xcodeproj -scheme DocumentScanner -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO` or Xcode Test. Unit/integration tests cover persistence failures, backup corruption/legacy compatibility, PDF text/links/passwords, image/OCR quality, compression, annotations, page transforms and StoreKit. UI tests cover review/save/reopen, swipe Trash/recovery, zoom, canceled captures, page history/body search/OCR correction, Pro extraction/annotation and saved-document retake/cancel.

UI fixtures and simulated capture exist only in DEBUG with explicit isolated `--ui-test-session UUID` arguments; normal launch never seeds examples or bypasses the camera. See `Verification/prd-implementation-results.txt` for the final current verification record. Historical results below describe earlier increments and do not supersede the current audit.

### Paper-cleanup verification — previous increment, 2026-09-29

Xcode 26.2 / iOS 26.2 / iPhone 17 Pro simulator: **50 tests passed** (47 unit/integration and 3 UI), zero failures. Final run: `/private/tmp/scanner-digital-paper-verified-tests.log`. Tests cover automatic OCR save, mixed English/Korean selection inside parentheses, seven-script OCR, twelve-script PDF Unicode selection, hidden-text pixel equality, strong stroke contrast, paper whitening, pale colors/gray ink, monochrome black preservation and full-pixel photo orientation. See `Verification/test-results.txt`.

Document mode now estimates paper illumination separately from printed color and removes remaining warm/cool paper casts. Broad shadows can be recognized along a single page edge and on pages without tables. Artificial white borders are excluded from the paper estimate only when spatial shadow evidence supports it; gray ink, colored table cells and bounded pale marks have guards. Originals remain unchanged and Scan strength remains adjustable.

The latest actual supplied PDF (`7B7196E9…`) was reprocessed using the app's shared renderer/OCR/PDF text layer. In the measured top and lower-left blank-paper rectangles, near-white pixels increased to 98.9% and 98.7%; table colors and handwriting remain visible. This is a sampled paper measurement, not a whole-page quality score. The output retains 68 Hangul syllables with 24/24 Korean regions selectable; the exact-region checker matches 177/178 overall regions, so universal selection accuracy is not claimed. The private comparison, PDF and measurements are in `Verification/scan-quality-sample/digital-white`.

OCR queries all language identifiers supported by the device, runs separate script-priority passes and merges readings. Settings → Supported languages shows the installed engine's coverage. This does not claim recognition of every world language; additional engines/models are needed for languages absent from Vision. Invisible PDF text uses script-appropriate system font mapping, including logical-order Indic encoding for correct copying.

Run the updated Xcode project on the iPhone to use these changes. Existing app documents can be regenerated in Document mode with Edit → Save changes. Imported PDFs default to Original and need Document mode selected to apply enhancement. OCR cache revision 4 refreshes older text. Physical iPhone capture, external viewers and broad document benchmarks remain to be verified. Current developer-team selection is retained in `project.yml`.


### Capture review and page adjustments — 2026-09-29

`CameraView` pauses capture after durable original-image storage and presents the shared page editor with a processed preview. Automatic capture and foregrounding do not bypass review. Add page saves only the current page's settings before restarting the camera and rearming automatic capture; Done returns to document review/save. Cancel removes the current capture from the manifest before deleting its unreferenced image, then returns to the camera without rearming automatic capture for the same sheet. It remains available even if preview generation fails. A failed cancellation write retains the page and pixels and keeps the editor open with an error. Full-screen zoom Close only dismisses the viewer and retains the current edit.

Tone offers Original / Document / Black & white. Brightness, contrast, sharpness and cleanup controls affect the current page; new pages start from automatic defaults. Reset adjustments preserves crop/rotation. Compare original temporarily bypasses tone and manual adjustments. Confirmed settings survive relaunch without rewriting the source JPEG. Old libraries decode with neutral manual adjustments.

A serial preview renderer now uses the same full-resolution source decoder and processing order as PDF export. Geometry/paper analysis stays in an unquantized Core Image graph; the finished full-resolution tone is cached in extended-linear half-float RGBA so brightness/contrast/sharpness can reuse it without early 8-bit clipping. Only the completed, manually adjusted image is resized to a maximum 1800-pixel longest side for display. A single in-flight render and replaceable latest request still show completed frames during dragging, without waiting for the gesture to stop or covering an existing image with an updating indicator. Canceled results cannot replace a newer page. Export and OCR are unchanged; this fixes the former thumbnail-first preview path, which could wash out fine ink.

The simulator's camera-flow test uses a synthetic capture only with a valid, isolated `--ui-test-session` plus `--simulate-camera` in DEBUG. Production builds always use AVCapture. This verifies navigation, draft persistence and export; actual iPhone camera stop/resume and interaction responsiveness still require hardware validation. Screenshot: `Verification/capture-review/automatic-review.png`.

Previous verification: **56 tests passed** (51 unit/integration, 5 UI), zero failures, in `/private/tmp/scanner-review-flow-final.log`. See `Verification/test-results.txt` for the latest run. UI scenarios cover Add page, Done, Close returning to camera, recapture and relaunch recovery; tracker tests check that explicit Add page starts a new stable hold while ordinary background resume retains duplicate protection.

Document and Black & white modes now straighten larger verified ruled grids, with bounded whole-page perspective transforms that retain content outside the table. Where no grid is found, at least four consistent text baselines can guide a rotation up to 18°. Sparse or conflicting text does not trigger a guessed rotation; severe perspective and curved pages can still need manual cropping. Original mode bypasses this residual alignment. OCR processing revision 5 rebuilds text positions when saving older scans.

Latest verification: all **62 distinct scenarios** passed across the full run and a targeted rerun (57 unit/integration, 5 UI). Two test expectations were corrected without further production changes; the targeted rerun passed 7/7. Logs and scope are recorded in `Verification/test-results.txt`. The supplied-PDF check still has 24/24 Korean regions selectable and 177/178 overall word regions; artifacts are in private `Verification/scan-quality-sample/perspective-preview/`.

### Home deletion and unfinished scans — 2026-09-29

Home document rows use native List swipe actions on both edges. No trash icon is exposed at rest. Release a partial swipe to keep the trash action open, reverse the swipe to close it, or finish a full swipe / tap the trash icon to move the document directly to Trash. Unfinished scans in Settings retain their explicit Cancel / Move to Trash confirmation. Restore remains in Settings → Trash. Continue your scan cards have been removed entirely from Home; captured unfinished pages can be resumed or trashed in Settings → Unfinished scans. Completely empty sessions are reused and cleaned after dismissal/import, while page-bearing drafts and PDFs remain untouched. Home navigation is disabled during import to keep the active import session safe.

Previous button/confirmation implementation: **27 targeted scenarios passed** across the initial and final runs: 16 library tests, 4 PDF-export tests and 7 UI flows. The initial native confirmation popover omitted a visible Cancel button; explicit alerts fixed it, and both saved-document and unfinished-scan delete/restore flows passed in the final run. See `Verification/library-results.txt` and `/private/tmp/scanner-trash-verified-tests.log`. The suite uses isolated DEBUG fixtures and did not delete user documents.

### Preview fidelity — 2026-09-29

The screenshot supplied with `BDA3376E…pdf` showed pale/broken ink in review while the exported PDF retained the strokes. The preview previously resized the source before nonlinear paper/ink processing and inserted 8-bit snapshots before later filters. It now performs the same original-resolution pipeline as export and downsamples only completed output. Floating-point tone caching preserves adjustment responsiveness without premature clipping; no per-slider updating overlay has been restored.

**12 targeted tests passed**, zero failures, including a 2400×3200 fine-text/color-table comparison against export at the same display size, cropped/rotated manual edits, cache reuse, continuous frame coalescing, cancellation, PDF text and capture review. See `Verification/preview-fidelity-results.txt`. Original capture pixels were not available in the attachment, so supplied-PDF stress checks do not claim an exact recreation of the original camera session. Physical iPhone frame timing and memory still require profiling; full-resolution processing retains one page's cache and is more expensive than the previous reduced-resolution path.

### Home swipe deletion — 2026-09-29

Three targeted UI scenarios passed; the two gesture scenarios also passed again after assigning the action an explicit red tint. Verified idle hidden actions, partial reveal and reverse cancellation on both edges, tap deletion, both full-swipe deletions, recovery with the saved PDF intact, and empty-state Settings navigation. Screenshots and test details are in `Verification/home-swipe/` and `Verification/home-swipe-results.txt`. This supersedes the former Home trash icon / confirmation flow. Physical iPhone gesture feel still needs validation.

### Enlarged scan preview — 2026-09-29

Nine targeted scenarios passed (eight adjustment/rendering tests and one UI flow). Capture → edit brightness → open full-screen → pinch in/out → pan → double-tap reset → Close preserves the edit, and Add page still returns to capture. Full-detail rendering matches export dimensions/pixels and reuses the existing prepared cache; raster replacement preserves the current zoom and position. See `Verification/enlarged-preview-results.txt` and `Verification/enlarged-preview.png`. Physical-device performance and VoiceOver gestures remain unverified.

### Canceling a captured page — 2026-09-29

The previous capture-review Close action retained its page as a draft. It is now Cancel: reject only the current new shot, return to the camera, and preserve previously accepted pages. The camera count says No pages yet / 1 page added / N pages added. Full-screen viewer Close still returns to editing without rejecting the page. Cancellation commits the metadata removal before deleting an unreferenced original; failure keeps the page and pixels for retry. Empty sessions follow existing cleanup.

All 22 targeted tests passed (19 library and 3 UI), including cancel/retake/relaunch, existing-page/PDF preservation, write-failure safety, full-screen zoom and normal Add page/Done/export. See `Verification/cancel-capture-results.txt`. Physical iPhone timing remains unverified.


### Margin trimming — 2026-09-29

Page review/edit now includes **Trim margins**. Adjust Top/Bottom/Left/Right independently in 0.1% steps, use 1%/2%/5% presets, inspect the selected area or trimmed result, Apply/Cancel or Reset. Trimming is an optional per-page recipe applied after perspective and tone processing; source images/PDFs are unchanged. Preview, full-resolution zoom, OCR and PDF export use the same cropped area. Rotating a page rotates its trim edges; changing the perspective crop resets trim for the new coordinate frame. Tone reset does not undo trim.

Native PDF trimming retains vector text and maps links into the kept rectangle; interactive forms may be flattened and the UI says so. Export paper layout is separate: choose **Original** paper and **None** margins for the trimmed aspect ratio without added paper borders. A4/Letter may add white space to preserve their aspect ratio. Presets are explicit user actions; the app does not automatically remove handwriting/barcodes near page edges. Existing annotations should be reviewed after changing page geometry.

See `Verification/margins-results.txt` for targeted tests. Old documents without an edgeTrim field retain their previous appearance.


### Focused page editor — 2026-09-29

Review scan and Edit page share three tool tabs: **Crop**, **Tone**, **Adjust**. Only the selected panel is shown. Tone opens by default; Crop contains Page edges, Trim margins, Auto scan and Rotate. Adjust uses a parameter menu and one live slider, with Reset adjustments below. Original comparison sits over the preview, separate from the tap-to-enlarge action. Add page / Done remain fixed at the bottom of capture review. Processing, export and stored edit recipes are unchanged.

See `Verification/editor-cleanup-results.txt` for UI validation.


### Local document tools — 2026-09-29

Eight additions use on-device processing with no new backend or external AI calls: ID front/back capture and one-sheet layout, watermark, timestamp, PDF to long PNG, QR generation/reading, whiteboard capture preset, slide capture preset, and screenshot stitching. Home → Tools opens QR and screenshot stitching. Document → Tools opens the four output tools. Camera → Scan mode selects the capture purpose.

All generated PDFs are previewed before saving a separate library copy. Watermarks accept text or a logo and preserve PDF text/links; form fields are flattened. Identity layout uses tightly cropped source pages with no export-paper padding. Timestamp labels are editable and not certified capture times. QR read results never open links automatically. Screenshots need ordered selection, optional header/footer trimming, and seam confirmation. Long PNGs split at 10,000 pixels and have a total pixel budget rather than allocating one unbounded image.

CamScanner observations and scope: `../CAMSCANNER-LOCAL-TOOLS.md`. Validation: `Verification/local-tools-results.txt`. Real camera/QR capture, glare-heavy whiteboards, photographed slides, physical print dimensions and low-memory devices require device validation. Source picker items stored only in iCloud may need an OS download; local inputs process offline.


### Remaining local tools — 2026-09-30

Home → Tools and Document → Tools → More offline tools expose fourteen additional tools: Word, Excel, PowerPoint, installed-language translation, book split/curve adjustment, ID photo, plain-background erase, colored-mark cleanup, photo restoration, two-dimensional mega scan, assisted counting, AR measurement, LiDAR mesh scan and arithmetic calculation. Generated output is separate from the source. Photos, library pages and editable text are accepted where relevant.

DOCX/XLSX/PPTX are actual OOXML ZIP packages without macros, external links or executable spreadsheet formulas. XLSX uses inline strings to retain leading zeroes and avoid formula interpretation. PPTX offers image fidelity or editable text, not a reconstruction of every original shape/table. Image edits save new PDF copies; book/erase/mark/mega outputs rebuild the OCR layer. A failed OCR pass is reported and can be retried from Text. Results can be enlarged with native pinch zoom.

Strict offline translation uses iOS 26's installed-source TranslationSession and never prepares/downloads languages. Other tools retain the iOS 18 minimum. 3D capture requires supported LiDAR; it exports an untextured OBJ surface mesh. AR measurement is approximate. Book curve correction is a manual cylindrical model; erase interpolates nearby paper colors; restoration is denoise/contrast/sharpen; counting finds separated contrast components with manual corrections. None of these claims general generative AI reconstruction or complete CamScanner parity.

Acceptance walkthrough and limitations: `../OFFLINE-TOOLS-ACCEPTANCE.md`. Validation: `Verification/all-offline-results.txt`. The device-only capture/model paths still require testing on the user's iPhone. This build has not been installed on the physical phone automatically.


### Visible home tools entry — 2026-09-30

A full-width **Tools** card appears directly below Home search, in both empty and populated libraries. It opens the offline tools list in one tap; QR and screenshot stitching are included in its Quick utilities section. The ambiguous ellipsis entry has been removed. Document-specific tool entry remains unchanged. Validation: `Verification/home-tools-visible-results.txt`.
