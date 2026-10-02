# Scan quality and live detection — 2026-09-29

The supplied app PDF included the desk/mouse/lap around the page. Two defects caused this: the 45% minimum crop threshold discarded a smaller sheet, and segmentation sometimes confidently selected a large polygon including the desk. Increasing brightness alone did not fix those defects.

## Capture and boundaries

- A throttled `AVCaptureVideoDataOutput` pipeline analyzes portrait video frames off the UI thread. A native preview-layer quadrilateral marks the detected sheet. The layer conversion handles aspect-fill framing; still photographs are detected independently because video and photo fields of view can differ.
- Manual capture is available. Opt-in Auto waits for a steady sheet, latches after capture, and requires the page to leave view before it can automatically capture another. Page counts change only after durable image/index saving.
- Permission-pending close, background changes, partial setup failures, photo errors, camera interruptions and retry are handled. The duplicate latch survives background/resume.
- Vision segmentation and rectangle candidates are ranked by paper interior and across-edge evidence. A supported sheet can occupy about 15% of the frame; an unsupported internal table remains subject to conservative rejection. Confidence alone is not trusted.
- Pages without reliable edges require an explicit four-corner crop confirmation before saving. Cancel preserves the draft. Existing documents can be reprocessed through Edit page → Auto scan → Apply → Save changes.

## Processing

Four-corner perspective correction removes surroundings geometrically. Illumination is estimated from neutral paper samples and interpolated across large colored regions. Blue/yellow cells are excluded from the paper reference, and a saturation-aware tone curve avoids clipping colored fills to white. Original comparison and adjustable cleanup strength remain available.

Document/monochrome processing also corrects residual skew and perspective from a verified printed grid. At least five supported rulings and a large rectangle are required; edges may now be tilted up to 25° with bounded convergence. Output size and the homography denominator across the whole photograph constrain expansion and prevent folds. The transform preserves the whole page and handwriting outside the table; an unruled rectangle is not sufficient evidence. Without a verified grid, four or more consistent, distributed text baselines can guide a rigid rotation up to 18°, without language recognition. Sparse or conflicting text is left alone. Dark-ink contrast and restrained sharpening strengthen text strokes. Colored cells are protected from the illumination reference.

New camera/photos default to Document mode; PDF import defaults to Original. Previews, OCR and PDF generation use the shared processor. Originals and existing exported PDFs are not silently replaced.

## Evidence and limits

The latest `BEFEE178-BAFA-4522-AF94-9B995913ED6F.pdf` and CamScanner JPG were captured under the same viewpoint/conditions according to the user. Its embedded image is 1573×2113; the table remains trapezoidal, blank paper has a blue shadow, and the PDF has no selectable text. The revised local comparison uses that supplied image and the shared app processor. It straightens the grid, reduces paper shadow and strengthens ink while retaining lower handwriting. This is evidence of improvement on this sample, not proof of identical quality on all documents. The app retains original camera photos; the comparison can only use pixels embedded in the supplied export.

Ordinary Save PDF now runs on-device OCR on the final corrected image and adds a real invisible Unicode text layer. Word positions use the exact image rectangle fitted into the PDF, including margins. English/Korean selection, coordinate alignment and unchanged visible PDF pixels are covered by PDFKit tests. Metadata and the new PDF commit together; failed export leaves the previously saved PDF intact. OCR versioning invalidates old coordinates when the processing pipeline changes. Basic selectable PDF text is free; Pro provides whole-document text sharing.

`Tools/EmbeddedPDFImage.swift` extracts a single opaque RGB photo with its ICC profile from an image-only PDF when supported. The comparison tool falls back to rendering the page for other PDFs. Private generated files under `Verification/scan-quality-sample` are ignored by Git.

Camera preview alignment, autofocus/exposure, processing latency, automatic capture timing and interruption recovery need physical iPhone validation. Synthetic state/coordinate tests and simulator UI tests do not prove hardware behavior. Low-contrast backgrounds, occlusion, hard shadows, curved pages and pale marks can still need manual adjustments. No claim of universal CamScanner parity is made.

## Verification

42 tests passed on Xcode 26.2 / iOS 26.2 / iPhone 17 Pro simulator: 39 unit/integration and 3 UI. These include automatic OCR in ordinary save, Korean/English spatial PDF selection, OCR cache migration, blank-page status, safe replacement, preserved PDF pixels, grid alignment, thin ink and pale colored marks. The latest local sample has 937 selectable characters and 113/113 selectable word positions. See `Verification/test-results.txt`.

Build the local comparison tool from this directory:

```sh
swiftc DocumentScanner/Models.swift DocumentScanner/DocumentProcessing.swift DocumentScanner/DocumentClarity.swift DocumentScanner/TextRecognition.swift DocumentScanner/PDFTextLayer.swift Tools/EmbeddedPDFImage.swift Tools/CheckScanQuality.swift -o /tmp/check-scan-quality
/tmp/check-scan-quality /absolute/path/input.pdf /absolute/path/output-directory /absolute/path/reference.jpg
```

The reference-image argument is optional. Output is local and uses the same processing code as the app; it does not replace a real iPhone capture test.

## Strong clarity and multilingual correction — previous increment

The latest `26AEDDFA-D438-4893-912E-D9CD75163248.pdf` embeds a 1713×2288 scan. Its text layer has 923 characters but only 9 Hangul syllables. Korean strings such as 몬트리올 and 토론토 are Latin/digit gibberish, while the few correctly recognized Korean strings are selectable. The root cause is primarily recognition language/model priority, not a general lack of Korean PDF fonts. Native full-resolution export was retained; a smaller cropped scan must not be compared to the pixel count of an earlier full-scene photo as proof of downsampling.

`TextRecognition` queries all supported identifiers, performs script-specific passes (including separate Chinese preferences), weighs document script evidence/confidence, and removes overlapping duplicate readings. Latin/CJK runs and brackets receive separate geometry so Korean inside `Toronto(토론토)` is positioned independently of Latin font widths. [Apple's recognition language documentation](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlanguages) describes the array as a priority list. English-first and Korean-first passes were also compared on this exact image. Recognition remains limited to the models the OS provides, not every world language.

`PDFTextLayer` uses a static Arabic system font to avoid contextual-glyph Unicode aliases. Indic text is invisibly encoded in logical scalar order so pre-base vowel shaping does not reverse copied characters. The visible page stays the photographed scan. Tests separately cover OCR on seven scripts and Unicode PDF selection on twelve scripts; encoding support is not a claim of OCR support for the same languages.

`DocumentClarity` estimates neighboring paper/ink luminance, darkens confident ink, constrains sharpening to local bounds and smooths low-contrast surfaces. Colored fills and faint pencil have guards. Extended/negative Core Image values are clipped before clarity analysis to preserve black in monochrome mode. Orientation normalization now retains pixel dimensions even for UIImage scale >1.

47 tests passed (44 unit/integration, 3 UI). On the actual sample, Korean text increased from 9 to 68 syllables; 24/24 Korean regions and 178/178 text regions are selectable. See private `Verification/scan-quality-sample/strong-multilingual` for the final PDF, full comparison, enlarged detail and report. This validates the supplied export, not a fresh physical iPhone capture or universal quality parity. Some OCR spelling/codes can still be wrong; original pixel detail lost before this export is not reconstructed.


## Digital-white paper cleanup — 2026-09-29

The supplied `7B7196E9-EFC9-408F-B90A-D64AC36250D2.pdf` contains a 1510×2003 image with warm upper paper and a blue lower-left shadow. `DocumentProcessing` now separates paper confidence from the illumination surface and removes small remaining casts only in bright, supported paper regions. Printed grids keep conservative color protection. Broad edge gradients work with or without a printed table; bounded pale artwork is not automatically treated as illumination. Unclipped paper samples prevent perspective correction's white canvas from masking a narrow edge shadow. This exclusion requires spatial cast evidence, so ordinary gray ink on white paper is not used as the paper reference.

Document and Mono modes use the revised illumination estimate. Original mode and saved source photographs remain unchanged. The renderer is shared by previews, OCR and PDF export. OCR processing revision 4 refreshes older text when an existing document is saved again.

The actual-sample comparison is in private `Verification/scan-quality-sample/digital-white/`. In fixed blank-paper sample rectangles, upper-paper mean sRGB changed from (244.6, 238.6, 228.6) to (254.3, 254.2, 254.1); lower-left paper changed from (227.5, 238.5, 249.5) to (253.9, 253.9, 253.9). Pixels with every channel ≥250 increased to 98.9% and 98.7% respectively. These measurements exclude printed cells and page-edge geometry and are not whole-page accuracy scores. The table colors and lower handwriting remain visible; a thin photographed edge and small traces near that edge are deliberately not treated as arbitrary deletable content.

The regenerated PDF has 943 selectable characters, 68 Hangul syllables, and 24/24 Korean regions selecting correctly at their image positions. The exact-region checker matches 177/178 overall regions, so perfect selection across all regions is not claimed. These are local shared-code checks of the supplied export; physical iPhone capture still needs verification. Color/illumination separation remains heuristic: a colored sheet or artwork touching page edges may require Original mode or a lower Scan strength.

Added regressions cover warm paper versus pale yellow artwork, a gradient along only one page edge with retained colored grid content, and gray ink versus artificial white-canvas samples. See `Verification/test-results.txt` for the final test run.

Final verification: **50 tests passed** (47 unit/integration, 3 UI), zero failures, in `/private/tmp/scanner-digital-paper-verified-tests.log`.


## Per-page manual adjustments and immediate capture review

After capture, the app shows the default processed result before returning to the camera. Original / Document / Black & white tone, brightness, contrast, sharpness and cleanup strength are adjustable per page. Original tone can receive manual adjustments; Compare original bypasses them temporarily. Manual settings are stored separately from source pixels and used by preview, OCR and PDF export. Close preserves the page and edits and returns to the camera; Add page also rearms automatic capture; Done opens document review/save.

Preview now completes processing at original resolution, exactly as export does, then resizes only the finished image to a maximum 1800-pixel longest side. Geometry and paper analysis are cached as an unquantized graph independently of Cleanup strength; the finished tone uses an extended-linear RGBAh cache before full-resolution manual adjustments. This replaces the thumbnail-first/8-bit-intermediate path that could wash out thin strokes and colors. One running request and one replaceable pending request present completed frames during dragging. Only the initial empty preview shows a progress indicator. The final setting must finish before Done/Apply is enabled. Export and OCR stay unchanged, so this preview correction does not change OCR revision 5.

The prior full suite passed 56 tests (51 unit/integration and 5 UI). New regressions cover continuous/coalesced preview requests, canceled stale results, preview resolution/cache reuse, more oblique grids, text-only skew and sparse-text rejection. The camera input for UI flows is synthetic; hardware behavior and interaction latency still need a physical iPhone. See `Verification/test-results.txt` for the latest result and `Verification/capture-review/automatic-review.png` for the layout.

Latest result: 62 distinct scenarios passed across the full suite and a targeted rerun, with two test-only expectation fixes documented in `Verification/test-results.txt`. The local supplied-PDF comparison at `Verification/scan-quality-sample/perspective-preview/` retains the table colors, lower handwriting, digital-white paper and 68 Hangul syllables; 24/24 Korean regions and 177/178 overall word regions select at their expected image positions.

## Preview / PDF consistency correction

The supplied `BDA3376E…pdf` has a 1594×2156 sRGB scan, while `IMG_3664.PNG` shows whitened breaks through some table text in review. Thumbnail-first analysis and intermediate 8-bit conversion differed from the PDF pipeline. The preview now shares original-resolution decoding and filter order, caches the finished tone in extended-linear RGBAh, and applies manual adjustments before its final display resize. The exported PDF processing is unchanged.

12 targeted preview/PDF/UI tests passed. A new 2400×3200 colored-table fixture with fine Korean/English and faint outside text checks default and cropped/rotated edited previews against finished export pixels at equal display size, with strict ink/color retention bounds. A separate nine-combination float-cache stress check using the supplied PDF image had a maximum RGB difference of two 8-bit levels. That input was already exported, so it establishes cache precision rather than an exact original-camera reproduction. See `Verification/preview-fidelity-results.txt` for scope and remaining physical-device performance limits.

## Residual desk/edge strip removal — 2026-10-01

The supplied `8FC0E67F-437B-4C0D-9864-70708987A7BA.pdf` (1406×2041 embedded scan) kept a dark desk strip on the left (~1% of the width), the bottom (~0.6%) and a 2–3 px brown strip along part of the top. The pale gray band at the top of that cover is **printed design and must be kept**. Vision's document-segmentation corners come from a coarse mask and often sit a few pixels outside the sheet; perspective correction turns that error into a strip along the page edge.

`DocumentProcessing.prepare` now calls `removeResidualEdges` right after perspective correction (only for a real crop, not `.full`, and not for ID crops, which use `IdentityBackground`). Analysis runs at up to 1600 px so 2–3 px strips are visible. Each side is split into 16 segments; a segment counts only when its outermost line is clearly not paper — luminance below 60% of the nearby paper, or saturation 0.15 above it — the band ends within 4.5% of the page, and the boundary is a sharp step. A pale neutral band (printed gray/tinted design) is paper-like and is never removed; gradual shading and printing that does not touch the edge are left alone. A side is trimmed only with ≥3 supporting segments and no more unresolved than supported ones; the second-deepest supported segment sets the depth (+1 analysis pixel). It runs before illumination analysis, so Original/Document/B&W, preview, OCR and export share the same geometry.

Known limits: a dark or strongly colored band printed to the page edge (≤4.5% deep) can still be cropped; a light gray desk that resembles paper is not detected. The source photograph is never modified; manual Trim margins still applies afterwards.

`PDFExport.textProcessingVersion` is 7 and the thumbnail cache key is `thumbnail-v3`, so OCR coordinates and thumbnails refresh for existing pages. Tests: `testDeskStripBeyondDetectedCornersIsRemoved`, `testPrintingNearAnAccuratePaperEdgeIsNotTrimmed`, `testPrintedGrayBandAtPageEdgeIsKeptWhileDeskIsRemoved`, `testGradualShadingIsNotTreatedAsResidualEdge`. A Python prototype of the same rule on the supplied PDF trimmed top 0.19% (brown strip only, gray band kept), bottom 0.62%, left 0.91%, right 0; this does not replace building and running the Xcode tests.
