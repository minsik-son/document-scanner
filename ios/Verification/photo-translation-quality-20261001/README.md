# Photo translation quality — 2026-10-01

This task changes photo translation only: selected-language OCR (plus target-script recognition on mixed pages), overlapping close-up recognition, separation of distant OCR words into columns, script-aware paragraph grouping, ink-derived font size, retry of missing responses in successful translation batches, and a source-image snippet in the area editor.

## Verified

- 12 photo translation unit tests passed, including selected English/Korean OCR, separation of an adjacent screenshot label, and stable font size despite oversized OCR boxes.
- Ordinary PDF save/text persistence regression passed.
- 2 photo translation UI tests passed: manual correction → preview → PDF sharing; unplaced translation → filtered review → copy.
- iPhone target build passed (unsigned; not installed on a phone).
- Source: supplied `1-Partially translated document.pdf`; embedded image extracted at 1423 × 2056 pixels. Six remaining English body regions were reconstructed with explicitly supplied Korean translations. All six fit without compositor rejection. Image inspected visually.
- An already Korean body line was previously grouped with adjacent English; it now remains separate. Known English/Korean text is not selected from unrelated Arabic/Thai OCR passes.

## Limits

- The six-body-region test also passed under the previous compositor when supplied translations were injected. It does not prove that all omissions in the exported PDF were caused by compositor rejection. The PDF does not contain the app's per-region error diagnostics or original pre-translation image.
- English/Korean Apple Translation models were not installed in the simulator. The live translation test was explicitly skipped without downloading models. Automatic translation semantics, including incorrect short labels/password values, are not verified as fixed.
- The sample was already partially translated; existing mistranslations, old font sizes and original text removed by that earlier export cannot be recovered from it. The test output is a reconstruction diagnostic, not a completed automatic translation deliverable.
- Language OCR changes apply to future scans and rereading the selected language, not automatically to existing saved PDFs.
- Some tiny screenshot labels remain imperfect OCR. The close-up pass is bounded; it does not promise all-language or pixel-perfect layout reconstruction.
- Separate concurrent edits were detected in DocumentProcessing, PDFExport and PageThumbnailCache; this task did not write or revert them. See scope-check.json.

Results: `/tmp/translation-quality-final.xcresult`. 15 passing tests, one explicit model-availability skip. Device log included.

## 2026-10-01 — fixes from "1-Partially translated document 2.pdf" (not yet built or run)

Observed: garbled OCR of small/gray print ("Bark up your cutter…"), screenshot labels turned into invented sentences
("저는 니나가 죽는 것을…"), list items split line by line ("…PC POST 프로세 / 스)."), headings mistranslated
("Restore" → "되돌리다"), circled numerals read as I/Q/@/1, Korean wrapped mid-word.

Changes:
- OCR runs on the geometry/illumination-corrected image before the paper-white tone curve and sharpening (`TranslationScan.reading`).
- `TextBlock.confidence` is carried into `TranslationRegion.confidence`. `TranslationQuality.review` keeps tiny (<11 px or <45% of body),
  low-confidence (<0.5) or misspelled (≥1/3 of ordinary words, UITextChecker) areas in the original (`unclear`), shown as a count;
  the user can still translate them in Review.
- `TranslationParagraphs.splitMarker`: leading •/①/"1." — or a square single glyph I/l/Q/@/O/digit followed by a gap — stays as pixels
  (`isMarker`, not in the text layer); item text starts after it, so indented continuation lines join the item.
- `TranslationGlossary` (en→ko exact whole-area matches) for headings/UI labels: Backup→백업, Restore→복원, Password→비밀번호, …
- Korean translations wrap between words (U+2060 joiners during layout only; removed from the PDF text layer).
Tests added in PhotoTranslationTests (marker/indent grouping, pronoun "I", unclear text, glossary, Korean wrapping).
