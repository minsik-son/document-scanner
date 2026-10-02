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
