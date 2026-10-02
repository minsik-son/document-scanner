# Claude용 디자인 프롬프트

사용 방법: 이 파일의 아래 영어 프롬프트를 복사하고 같은 폴더의 PRD.md를 Claude에 첨부한다. 이 파일만 전달해도 주요 범위는 포함되어 있다. 실제 화면 언어는 영어다. 설명·디자인 근거는 한국어로 요청한다.

---

You are the lead product designer for an offline-first iPhone document scanner. Create a polished, high-fidelity interactive design prototype using the attached PRD, informed by Toss's published product and UX principles.

The outcome should be an app someone can understand through use: capture paper, check the pages, save a useful PDF, and continue with document tasks. Strongly reference Toss's clarity, hierarchy, plain language, and purposeful feedback while creating an original scanner identity.

## 1. Source of truth and delivery

Read the attached PRD before designing. Preserve its version 1.0 scope and free/Pro boundaries. Use the defaults below if a decision remains open. Do not ask for visual preferences before producing a coherent first proposal. Note assumptions separately.

Create the actual interactive prototype, not just a design essay, landing page, mood board, or set of disconnected screens. In an artifact/code environment, React and CSS are appropriate for the preview; the production app will be native iOS. Simulate camera capture, OCR, file processing, printing, and StoreKit purchases using fixture data. Clearly disclose these simulations in the designer notes, outside the product UI. Do not call a simulated operation production-ready or execute real purchases or uploads.

All product UI must be English. Explain design decisions in Korean after the prototype. The final brand is undecided: use “Document Scanner” only where a temporary product label is necessary; home should simply say “Documents.”

## 2. What “Toss-inspired simplicity” means here

Apply these practical rules throughout the prototype:

- Remove unnecessary decisions. Provide usable document names and export defaults so saving does not require typing or understanding PDF settings.
- Give each screen a clear purpose and visual priority. Multiple useful controls can exist, but the main action should be obvious.
- Match tools to context. Show a document's tools when that document is open or selected. Keep the home screen focused on documents and starting a scan.
- Reveal advanced settings when requested without making basic tasks require more screens. A settings row can expand in place; every field does not need a separate page.
- Make labels predict the immediate result of tapping. If a button opens save settings, do not imply the file is already being saved.
- Preserve continuity. Closing a purchase sheet, canceling sharing, or returning from editing must preserve the user's document and current position.
- Give immediate input feedback and honest task progress. Do not simulate certainty about storage, backups, or purchase success.
- Help people recover where a problem occurs. Use a clear next action and only state causes or preservation status that are known.

These are design applications to this product. Do not invent official Toss metrics, exact design tokens, or claims that this prototype has been usability-tested.

## 3. Visual direction

Use a light theme, strong typography hierarchy, generous but purposeful spacing, crisp document previews, and one restrained blue action accent. The atmosphere should be calm, capable, approachable, and trustworthy.

Use a system font such as SF Pro when available, with platform-safe fallbacks. Define reusable design tokens. Suggested starting values for our own design, not official Toss specifications:

- Canvas: white; secondary surfaces: a very light neutral gray.
- Primary text: near black; secondary text: a readable neutral gray.
- Accent: an original accessible blue. Reserve its strongest use for actions and selection.
- Spacing scale: 4, 8, 12, 16, 24, 32 points.
- Horizontal margins: approximately 20–24 points.
- Screen titles: approximately 28–32 points; body: 16–17 points.
- Primary buttons: approximately 52–56 points tall, comfortable corners, clear pressed/loading/disabled states.
- Touch areas: at least 44 × 44 points; text expansion can increase component height.

Use list rows, alignment, and spacing instead of putting everything in floating cards. Let a paper document actually look like paper. Show realistic page thumbnails rather than repeating generic file icons.

Camera and document-editing views may use darker surrounding surfaces if that improves contrast. Preserve the same hierarchy and interaction language.

Avoid a marketing hero, finance-dashboard imitation, tool tiles filling the home screen, excessive glass effects, decorative gradients, mascot-heavy onboarding, permanent upgrade banners, and repetitive success celebrations. Do not copy Toss logos, proprietary graphics, or exact screens.

## 4. Product contract

- iPhone first; use a roughly 390-point-wide baseline and support 375–430-point widths, safe areas, and larger text.
- No account required for core tasks.
- Capture, enhancement, local OCR, library access, and PDF creation work offline.
- Local files must already be available; cloud-only imports may require downloading.
- Preserve original images and edits. Save captured pages progressively; show saved status only after persistence succeeds.
- Basic PDF and image exports have no watermark.
- Existing documents remain accessible and exportable after a subscription expires.
- No ads or surprise purchase interruptions in capture/save flows.
- No proprietary cloud sync, public document links, fax, Office-format reconstruction, or AI chat in version 1.0.
- Sharing and printing use iOS-style system flows. Handing a file to another app is not proof that someone received it.
- Design for later localization. Avoid embedded image text, fixed-width English labels, and truncation of important prices or actions.

## 5. Feature access and pricing

FREE:
- Scan, crop, rotate, basic enhancement.
- Add, reorder, retake, duplicate, and delete pages within a document.
- Standard PDF/image saving, sharing, and printing without a watermark.
- Image/PDF imports, folders, favorites, title search.
- Single-page text extraction and copying.
- Trash/recovery, backup export/import, and app lock.
- Access to previously generated searchable content and completed Pro results after expiration.

PRO:
- Batch OCR and new searchable PDF creation.
- Merge separate documents, split a document, extract page ranges.
- Add/edit signatures, text annotations, pen, and highlighter.
- PDF compression presets and password-protected exports.

Both subscription plans unlock exactly the same Pro features:
- Monthly: US$4.99/month.
- Annual: US$29.99/year.
- Annual equivalent: about US$2.50/month; approximately 50% savings versus 12 monthly payments.

Show the annual total and billing period more prominently than its monthly equivalent. Use the US storefront for this prototype; production pricing will be localized by StoreKit. Do not invent a trial or future features. Include auto-renewal disclosure, an immediately visible close button, Restore purchases, Terms, Privacy, and Manage subscription where appropriate.

A Pro marker appears before a restricted action is attempted. Closing the purchase sheet preserves the draft. Existing exported results are not retroactively altered. Backup and recovery are not paywalled.

## 6. Connected screens

S01 — Documents
- A clean title, search, recent documents, folders/favorites, and a dominant “Scan document” action.
- Secondary “Import” and access to settings.
- Use realistic fixtures: Apartment lease (4 pages), Coffee receipt (1 page), Biology notes (6 pages).
- Add a helpful first-use empty state without mandatory onboarding.
- A recovered draft appears only when relevant: “Continue your scan.”
- Do not show permanent storage anxiety banners or a giant feature grid.

S02 — Scan
- Large camera preview with visible page edges.
- Capture, Auto/manual, Flash, Import, saved-page count, thumbnail, and “Review pages.”
- Small capture-to-thumbnail feedback clarifies which page was added.
- Distinguish captured, saving, and saved states without overwhelming the user.
- Camera-denied state offers “Import photos” and “Open Settings.”

S03 — Review
- Large page preview and a clear page strip.
- Easy access to Crop, Rotate, Enhance; additional page management remains discoverable.
- Original / Document / Black & white options; show which page or all pages an edit affects.
- Reorder via drag and an accessible move control.
- Main action “Continue” opens save settings. This is an intentional wording refinement to the PRD: “Save PDF” should be reserved for the action that actually writes the file.

S04 — Save PDF
- Suggested editable name; saving must work without typing.
- Useful defaults for folder, page size, and margins.
- Paper choices include A4, US Letter, Original; show current choice without requiring an answer.
- Put advanced options under “More options.”
- Searchable PDF is clearly marked Pro and explained as enabling text search and copying.
- Primary “Save PDF.” Show estimated size as estimated; replace with actual size only when known.

S05 — Saved
- Concise confirmation: “Saved on this iPhone.”
- Document preview, actual page count, “Share PDF,” and “Done.”
- No automatic paywall. No claim that the document is backed up.

S06 — Document detail
- Comfortable page viewer and “Share PDF” as the main action.
- Access to Edit pages, Extract text, Sign, and More tools.
- Rename, Move, Favorite, Save images, Print, and Delete are available in predictable places.
- Signing opens a focused editor with draw/import, placement, resize, undo, and save-copy feedback. Do not claim identity certification or legally verified signatures.

S07 — Text and search
- Readable extracted text, Copy text, Edit, Save TXT.
- Batch processing state shows the current page and retry for failed pages.
- Search results include a contextual excerpt and the matching page.
- Distinguish image-only documents, text extraction, and searchable PDFs.

S08 — Document tools
- A named, grouped menu for Merge, Split, Extract pages, Compress PDF, Set password, and Print.
- Design a clear input/preview/confirmation flow for each version 1.0 tool. Use reusable sheets without making all tools identical when their decisions differ.
- Merge/split create new documents; make preserved originals clear.
- Compression choices: Balanced, Smaller file, Higher quality, with a legible before/after preview.
- Password protection is for the exported copy; it is different from app lock.
- A black annotation is not secure redaction. Do not add unsupported redaction claims.

S09 — Pro
- Contextual heading based on the selected feature, then a short benefit list.
- Two clear plan choices, selected price repeated at the purchase action.
- Close returns to the same draft and page.
- Include purchase pending/failure/restoration states; a dismissed purchase is not success.
- Expired subscribers can still open and export existing documents.

S10 — Settings
- Subscription, App lock, Backup & restore, Trash, Privacy, Contact support.
- No fake account profile or login requirement.

S11 — Backup & restore
- Export backup, Import backup, and last backup-file creation time.
- Explain local storage and external backup at this point of relevance.
- File creation or handoff is not verified cloud synchronization.
- Version 1 backup archives are not independently password-encrypted. Make that clear before export; do not imply PDF passwords protect the whole archive.
- Restore previews the document count and handles duplicates without overwriting the library.

S12 — Trash
- Restore and Delete permanently, with retention information.
- Undo for ordinary deletion; explicit confirmation for irreversible deletion.

## 7. Copy, errors, and motion

Use friendly, natural English, sentence case, and action-specific labels. Avoid unexplained jargon and redundant descriptions. Financial and data-loss information must remain precise.

Useful patterns:
- “Extract text” rather than “Execute OCR.”
- “Choose pages” rather than “Configure extraction range.”
- “PDF couldn't be created” with a known reason and “Try again.”
- “Your 3 saved pages are here” only when those 3 pages are verified as saved.
- “Connect to restore your purchase” only for that network-dependent operation, not for normal scanning.

Show errors close to the affected task. Use a persistent message for a blocked save, not a disappearing toast. Do not tell users to reinstall a local-storage app as a generic recovery step.

Animate to explain capture, selection, page reordering, and transitions. Use short consistent motion and respect reduced motion. No artificial waiting to make the app look sophisticated. Prototype progress can be simulated, but document that clearly in the preview notes.

## 8. Prototype requirements and review

Deliver:
1. A consistent token and component set with relevant interaction states.
2. All version 1.0 screen groups above, with the primary scan-to-PDF journey fully clickable.
3. Connected imports, document tools, subscription dismissal, backup, and recovery flows.
4. An external preview/debug control for switching Free/Pro/Expired and error fixtures. Keep this out of the product navigation.
5. A short Korean rationale mapping specific screen decisions to the underlying design principles.
6. A clear list of simulated capabilities and open product decisions.

Include empty library, no search results, camera denial, interrupted scan, low storage, OCR partial failure, purchase pending/failure, expired subscription, and damaged backup examples. Preserve state when navigating back.

Perform a design self-review before presenting:
- Can a new user find scanning immediately?
- Can someone save a standard PDF without typing, subscribing, or learning technical settings?
- Does each primary button accurately describe its immediate action?
- Are important tools discoverable without crowding home?
- Are billing totals, local storage, and backup status unambiguous?
- Does closing an upsell preserve the user's work?
- Do small screens, large text, keyboard focus, and screen-reader labels remain usable?
- Are all required version 1.0 features represented without introducing deferred cloud/fax/Office/AI features?

Use these official references as background if browsing is available:
- Product principles: https://toss.im/tossfeed/article/tossproductprinciples
- UX writing: https://toss.tech/article/21022
- Error guidance: https://toss.tech/article/how-to-write-error-message
- Purposeful interaction: https://toss.tech/article/interaction

The attached PRD is the product scope; the instructions above translate that scope into a design brief. Start creating the prototype now.
