# Tool design system

Every tool screen in the app uses this one template. A new screen or a
change to an existing one must follow it. Code lives in `ToolKit.swift`
(tokens, buttons, page scaffold) and `ImageToolFlows.swift` (step flow).

## Mockups

`../design/system/`: `0-foundations.png` (tokens and parts) and one board per tool type: `1-photo-tools`, `2-document-tools`, `3-converters`, `4-camera-tools`, `5-editors`. New screens copy the board of their type.

## 1. Principle: one page, one job (Toss style)

- A page answers one question ("Which language?", "Which size do you need?").
- One large title, at most one line of explanation, one main control or
  picture, one primary button at the bottom.
- Anything secondary (crop, edit, copy text) is a chip, never a second big
  button or a block of explanation.
- No gradient header cards, no long footnotes. If a warning matters, it is
  one row (icon + one sentence), tappable when it leads somewhere.

## 2. Flow: every tool has the same steps

| Step | Page | Component |
|---|---|---|
| 1 | Intro + source: what the tool does, where the input comes from | `PhotoSourcePage` (photos) or a document choice page, with `ToolHero` art |
| 2…n | One decision per page (options, adjust, review) | `ToolPage` |
| last-1 | Result preview with the main action | `ToolPage` + `CTAButtonStyle` |
| last | Done: what happened, share/next | `ToolDonePage` / `PhotoToolDone` |

- Pages are wrapped in `StepStack` (slide transition) and the flow uses
  `.stepChrome(step:forward:last:work:)` for the back button, busy overlay
  and cancel. No tool builds its own navigation bar, toolbar back button
  or progress row.
- Long work shows `BusyOverlay` through `ToolWork.run("…")`. Errors use
  `ToastMessage` on the page (`work.message`).

## 3. Page anatomy (`ToolPage`)

- Background: white (`TK.paper`). Content max width 640, side padding 24.
- Title: `ToolTitle`, 26 pt bold, `TK.grey900`. Subtitle: 17 pt, `TK.grey600`, one sentence.
- Vertical spacing between blocks: 24.
- Bottom bar (`actions`): pinned, padding 20, primary `CTAButtonStyle`
  (56 pt, radius 16, `TK.blue`), optional `SecondaryCTAStyle` above it.
- Navigation bar: inline, no title text (the page title is the title).
  The only top-right item allowed is Close on the first page of a modal tool.

## 4. Components

| Need | Use |
|---|---|
| Pick one of several options | `OptionCard` (radius 18, `TK.grey50`, blue when selected) |
| Big tappable row (source, setting that opens a list) | `ChoiceRow` |
| Secondary action / small toggle | `ChipStyle` (capsule, 40 pt) |
| Section heading inside a page | `SectionLabel` (15 pt semibold, `TK.grey600`) |
| Slider | `ToolSlider` |
| Image result | `ImageStage` / `BeforeAfterView` |
| Info card / grouped block | `TK.grey50` fill, radius 20 |
| Warning row | `TK.orangeSoft` fill, radius 16, orange icon, one sentence |
| Privacy note | `Label("Processed on this iPhone", systemImage: "lock.shield")`, 13 pt `TK.grey500` |
| List picker (languages, countries) | Sheet with `.medium/.large` detents and search |

## 5. Tokens (only these)

- Colours: `TK.blue / blueDeep / blueSoft`, `TK.teal(Soft)`, `TK.orange(Soft)`, `TK.red(Soft)`, `TK.grey50…grey900`, `TK.paper`.
- Type: 26 bold title, 22 bold key value, 17 semibold body-strong, 17 regular body, 15 semibold chip/label, 13 caption.
- Radii: 16 buttons/warnings, 18 option cards, 20 info cards, 28 hero art.
- Not allowed in tool screens: `Design.*` colours, `PrimaryButton()`,
  `OfficeHeaderPalette` gradients, system `Picker(.menu)` for main choices,
  `.navigationTitle` text, custom bottom `.regularMaterial` bars.

## 6. Checklist before committing a tool screen

1. Built from `ToolPage` inside `StepStack` + `.stepChrome`.
2. Each page has one question and one primary button.
3. The main control is visible without scrolling on an iPhone 15/16/17.
4. Only `TK` tokens and the components above.
5. Done page uses `ToolDonePage` / `PhotoToolDone`.

## 7. Current status (2026-10-05)

Follows the system:
- Photo tools in `ImageToolFlows.swift`: Book pages, ID photo, Spot eraser, Remove colored marks, Restore photo, Mega scan, Count objects.
- PDF tools in `PDFToolFlows.swift`: Merge, Split, Extract, Reorder, Compress, Protect, Export images, Print, Watermark, Timestamp, Long image.
- Photo translation, Word / Excel export, PowerPoint export, Math scan, ID card layout, Sign & annotate (+ signature), Measure / 3D scan, OCR text editor, Excel/Word cell editors, Trim margins.

Remaining exceptions: the tools hub ("All tools") and a few modal pickers (`Review text areas`, `Choose pages`) keep a system nav title on purpose; they are sheets, not tool pages.

Real-app screenshots of the migrated screens: `Verification/private/design-shots/` (made by `designShot` in the UI tests; not in git).
