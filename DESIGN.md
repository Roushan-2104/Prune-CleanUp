---
name: Declutter
description: A careful librarian's weeding round for a full phone, on catalog-card paper; only stamped items leave.
colors:
  stamp: "#5B3C8C"
  stamp-tint: "#EFEBF6"
  on-stamp: "#FFFFFF"
  rule: "#C8382E"
  ink: "#2B2A27"
  muted: "#6B6862"
  paper: "#FBFAF6"
  desk: "#F3F1EB"
  blank: "#ECE8DE"
  line: "#DDD8CC"
  ruling: "#E7EDF4"
typography:
  display:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.5px"
  headline:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    letterSpacing: "-0.3px"
  title-lg:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 700
  title:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 700
    letterSpacing: "-0.2px"
  title-sm:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 600
  subhead:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
  lede:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.5
  body:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.4
  button:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
  label:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  caption:
    fontFamily: "Segoe UI, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  fact:
    fontFamily: "Consolas, ui-monospace, monospace"
    fontSize: "12.5px"
    fontWeight: 400
    lineHeight: 1.35
  fact-bold:
    fontFamily: "Consolas, ui-monospace, monospace"
    fontSize: "12.5px"
    fontWeight: 700
    lineHeight: 1.35
  stamp:
    fontFamily: "Consolas, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 700
    letterSpacing: "1.6px"
rounded:
  hairline: "2px"
  card: "3px"
  panel: "4px"
  control: "6px"
spacing:
  xxs: "4px"
  xs: "6px"
  sm: "8px"
  card: "10px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  gutter: "28px"
  section: "36px"
  page: "40px"
components:
  button-clean:
    backgroundColor: "{colors.stamp}"
    textColor: "{colors.on-stamp}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    padding: "16px 20px"
  button-clean-disabled:
    backgroundColor: "{colors.line}"
    textColor: "{colors.muted}"
  button-outline-ink:
    textColor: "{colors.ink}"
    typography: "{typography.button}"
    padding: "14px 18px"
  tick-box:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.card}"
    size: "22px"
  tick-box-on:
    backgroundColor: "{colors.stamp}"
    textColor: "{colors.on-stamp}"
  remove-stamp:
    textColor: "{colors.stamp}"
    typography: "{typography.stamp}"
    rounded: "{rounded.hairline}"
    padding: "1px 6px"
  card:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.card}"
    padding: "10px"
    width: "230px"
    height: "268px"
  slip:
    backgroundColor: "{colors.paper}"
    padding: "12px 16px 14px"
  slip-row:
    typography: "{typography.fact}"
    textColor: "{colors.ink}"
    padding: "6px 0"
  capacity-bar:
    backgroundColor: "{colors.line}"
    rounded: "{rounded.hairline}"
    height: "10px"
  rail-entry:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.panel}"
    padding: "9px 12px"
  rail-entry-active:
    backgroundColor: "{colors.blank}"
  top-bar:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    padding: "0 24px"
    height: "68px"
  decision-panel:
    backgroundColor: "{colors.desk}"
    rounded: "{rounded.panel}"
    padding: "12px"
  decision-panel-on:
    backgroundColor: "{colors.stamp-tint}"
    textColor: "{colors.stamp}"
  tooltip:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.panel}"
---

# Design System: Declutter

## Overview

**Creative North Star: "The Librarian's Weeding Round"**

Removing things from a phone is treated as a librarian weeding a collection: every suggestion is a catalog card with a typed reason, a fuller slip sits behind it on demand, and only cards pressed with the violet REMOVE stamp leave. The ground is a pale desk; cards, rail and panels are cream catalog stock edged with a thin buff line; type is ink. The world refuses the generic phone-cleaner grid of bright blue checkmarks, rounded tiles and alarm-red warnings. Nothing is playful and nothing is hidden: the picture and the proof are always one glance away.

Density is high but calm. A big-screen review shows a rail of groups, a grid of cards and a large focused item at once, held together by one small typed size for every fact, ink for anything that is navigation or focus, and violet reserved for exactly one meaning. The interface face (Segoe UI) speaks in sentences; the typed face (Consolas) records facts: sizes, dates, reasons, evidence.

The theme is light only, on purpose. Photos are judged on paper, the way a printed contact sheet is judged, and a dark ground would change how sharpness and colour read.

**Key Characteristics:**
- Catalog-card paper on a pale desk, ink type, no shadows.
- A red top rule marks every card and slip; it is a material mark, never a warning.
- Violet stamp-pad ink means "will be removed" and nothing else.
- Facts are typed at one size (12.5px Consolas); rank comes from weight and ink.
- Small, nearly square corners (2-6px); flat, edged surfaces.
- Light theme only.

## Colors

A paper-and-ink palette with two inks of meaning: red for the card's printed rule, violet for the removal stamp.

### Primary
- **Stamp-Pad Violet** (#5B3C8C): the only colour of removal. It fills a ticked tick box, draws the REMOVE stamp, fills the Clean button, colours the picked share of the storage bar and the "picked" figure beside it, and frames the copy being removed in the detail panel.
- **Stamp Wash** (#EFEBF6): the pale violet ground of the detail panel's decision strip when the item is ticked for removal.
- **On Stamp** (#FFFFFF): text and check marks on violet.

### Secondary
- **Catalog Red Rule** (#C8382E): the printed red line across the top of every card (3px) and slip (2px), and the line under the top bar (2px). It is part of the stationery, not a signal.

### Neutral
- **Ink** (#2B2A27): all primary text, the used part of the storage bar, the focused card's 2px border, the kept original's frame, the active rail bar, outlined secondary buttons, tooltips.
- **Faded Ink** (#6B6862): secondary text, typed sizes and dates, rail headings, unticked tick-box edges (5:1 on paper).
- **Catalog Stock** (#FBFAF6): cards, slips, rail, detail panel, top bar, dialogs.
- **Desk** (#F3F1EB): the ground behind everything; the unticked decision strip.
- **Empty Frame** (#ECE8DE): picture frames before a thumbnail loads; the selected rail entry.
- **Buff Edge** (#DDD8CC): 1px edges of cards, panels and dividers; the empty track of the storage bar; disabled buttons.
- **Blue Ruling** (#E7EDF4): the faint 1px line under each row inside a slip, as on ruled index stock.

### Named Rules

**The One Ink of Removal Rule.** Violet (#5B3C8C) appears only where something will be removed: selection, the REMOVE stamp, the Clean button, the picked part of the storage bar. If an element does not mean "this leaves the phone", it is not violet.

**The Ink Leads Rule.** Focus, the active navigation item and the kept original use ink, never violet. The focused card gets a 2px ink border; the active rail entry gets an ink bar and the Empty Frame ground.

**The Printed Rule Rule.** The red rule (#C8382E) is printed on every card and slip and is never used for warnings, errors, progress or data bars. Size bars in the rail are ink or faded ink, because red reads as danger in a deletion app.

**The Paper Only Rule.** Light theme only. Photos are judged on paper; there is no dark variant.

## Typography

**Interface Font:** Segoe UI (Windows system font; fallback system-ui, sans-serif)
**Typed Font:** Consolas (Windows system font; fallback ui-monospace, monospace)

**Character:** Segoe UI carries the conversation in plain sentences and firm bold headings; Consolas is the typewriter on the catalog card, recording what is known about each item. Both are system fonts, so nothing is bundled. Open decision: Courier Prime was considered for the typed voice but is not bundled; the shipped typed face is Consolas.

### Hierarchy
- **Display** (700, 30px, 1.15, -0.5px): the home headline only, "You can free X GB".
- **Headline** (700, 24px, -0.3px): the open group's name at the top of the review grid.
- **Title Large** (700, 20px): the title of a connection guide slip ("Plug in your Android phone").
- **Title** (700, 18px): the Declutter wordmark in the top bar (-0.2px) and section headings on home ("For you to check").
- **Title Small** (600, 16px): the focused item's file name in the detail panel; the empty-detail prompt.
- **Subhead** (600-700, 15px): sub-group headers ("Nikhil · WhatsApp", "Keeping IMG_2041.jpg"), slip headings ("The pick: 1,204 items"). "How we know" sits at 14px 700.
- **Lede** (400, 15px, 1.5, faded ink): the explanatory paragraph under the display line, max 640px wide.
- **Body** (400, 14px, 1.4): sentences, group names in slips and the rail, numbered guide steps.
- **Button** (600, 14px): filled buttons. Text buttons use **Label** (600, 13px).
- **Caption** (400, 12px, faded ink): top-bar meta, folder paths, footnotes; rail headings at 600.
- **Fact** (Consolas 400, 12.5px, 1.35): every typed fact about an item: reason, size, date, count, evidence. **Fact Bold** (700) labels the left column of a slip row.
- **Stamp** (Consolas 700, 12px, 1.6px tracking, uppercase): the REMOVE stamp only.

### Named Rules

**The One Fact Size Rule.** Every item fact is typed at 12.5px Consolas. A card's reason, its size and date, a slip's evidence and the rail's counts share one size; rank comes from weight (700 vs 400) and ink (ink vs faded ink), never from size.

**The Sentence and Typewriter Rule.** Sentences are set in Segoe UI; facts are typed in Consolas. A slip row switches to Segoe UI only when its value is a sentence (guide steps), never for a figure.

## Layout

A fixed desktop frame for a large window, mouse and keyboard first.

- **Top bar:** 68px tall across every screen, 24px side padding: wordmark, read-only note, phone model, a storage bar up to 520px wide with its caption, then the screen's main action at the far right.
- **Review, three panes:** a left rail at 19% of the window (230-290px), the open group in the remaining space, and a detail panel at 28% (340-440px). Panels are separated by 1px Buff Edge lines, not gaps. The side panels scale so a 1280px-wide laptop still shows two to three card columns.
- **Card grid:** cards target 230px wide and are exactly 268px tall, 16px apart in both directions, inside a 28px gutter. The column count is derived from the width and is the same count the arrow keys step through, so up and down move straight.
- **Home:** a single centred column, max 880px, padded 36px top and 40px sides; prose capped at 640px; 24px between headline block and the pick slip, 36px between major sections.
- **Rhythm:** spacing steps of 4, 6, 8, 10, 12, 16, 24, 28, 36 and 40px. Card interiors use 10px; slips 12-16px; panels 22px.

**The Fixed Cells Rule.** Card facts sit in fixed positions (reason on one line, size left and date right below it) and slip rows use a fixed label column (130px by default), so the eye scans down a column of facts like a timetable.

## Elevation & Depth

Flat. There are no shadows in the system. Depth comes from material layering: cream Catalog Stock (#FBFAF6) surfaces sit on the slightly darker Desk (#F3F1EB), edged by a 1px Buff Edge line, with the red rule printed across the top. State is shown with borders and fills (2px ink focus border, Empty Frame selected ground, violet stamp), never by lifting. The only lifted surface is the Clean confirmation dialog, which keeps Material's default dialog elevation.

**The Flat Stationery Rule.** Cards and slips are paper on a desk: edged, never floating. Show state with ink, fills and the stamp, not shadow.

## Shapes

Nearly square stationery. Corners are 2px for the stamp, the storage bar and picture frames inside cards; 3px for cards, tick boxes and checkboxes; 4px for rail entries, the decision strip, the detail picture frames and tooltips; 6px for filled buttons and dialogs. Edges are 1px Buff Edge lines; the red rule is a straight full-width band across the top edge. The REMOVE stamp is the one rotated form, set 8 degrees askew like a hand-pressed stamp.

Pictures are clipped to their frame with `cover` fit. Card thumbnails crop from the top, because screenshots carry what matters at the top (the chat name, "Payment Successful").

## Components

### Buttons
Quiet and firm; the one coloured button is the one that removes.
- **Shape:** gently squared corners (6px).
- **Clean (primary):** Stamp-Pad Violet fill, white 14px 600 label, 16px x 20px padding, leading delete icon at 18px. The label carries the amount, "Clean 2.6 GB…"; with nothing picked it reads "Nothing picked" and turns Buff Edge.
- **Outlined ink (secondary):** ink text and a 1px ink outline, 14px x 18px padding, used for Play video / Play audio and "Open in its usual app". Deliberately not violet.
- **Text buttons:** 13px 600 labels for group actions ("Tick all (Ctrl+A)", "Tick these", "Untick all").

### Tick box
A small violet square when ticked. 22px square, 3px corners, 1.5px border: faded ink on paper when off, violet fill with a white 16px check when on, 120ms transition. Its accessible label reads "Will be removed" or "Kept". It sits top-right on each card picture (6px inset).

### REMOVE stamp
The violet word REMOVE in the Stamp style, inside a 1.5px violet border (90% opacity) on a paper ground at 85% opacity, 2px corners, rotated -8 degrees. It appears only on ticked cards, pinned to the bottom-left corner of the picture (8px from the left, 10px from the bottom), never over the content the user reads to decide.

### Cards
- **Corner Style:** 3px.
- **Background:** Catalog Stock with a 1px Buff Edge border; 2px ink border when focused.
- **Top rule:** a 3px Catalog Red band across the full top edge.
- **Internal Padding:** 10px. A 180px picture frame, then one typed reason line (Fact, single line, ellipsis), then size and date in Fact faded ink.
- **Shadow Strategy:** none (see Elevation & Depth).

### Slips
The catalog slip: Catalog Stock with a 2px red top rule and 1px Buff Edge sides and bottom, padded 12px 16px 14px (wider on home). Rows inside are ruled with a 1px Blue Ruling line beneath each; each row has a bold typed label column (130px) and a typed value that can be selected and copied. Used for "How we know", the pick on home, "For you to check", keyboard help and connection guides.

### Storage bar
One 10px bar with 2px corners: Buff Edge track, used space in ink, and the share the current pick would free in violet at the end of the used part, sliding over 260ms (ease-out cubic) as ticks change. Under it, a 12px caption: "X free · Y picked · Z free after", with "Y picked" in violet 600.

### Navigation (review rail)
Group entries on Catalog Stock, 9px x 12px padding, 4px corners. Each shows the group name (Body; 600 when active), its size typed in faded ink, a 3px size bar scaled by the square root of its share (ink when active, faded ink at 45% otherwise; omitted under 5%), and a typed count, "12 of 40 picked". The active entry takes the Empty Frame ground. Entries are split under two 12px 600 faded-ink headings, "Sure to remove" and "For you to check".

### Top bar
68px Catalog Stock band with a 2px red rule along its bottom edge, carrying the wordmark, a lock icon with "Read-only" (with an explanatory tooltip), the phone model in faded ink, the storage bar and the screen's main action.

### Detail panel
The focused item at large size on Catalog Stock. When it is a copy, the kept original and the copy are stacked full width (not side by side, so near-identical photos stay large enough to compare): the kept one framed in 2px ink under "Keeping", the copy framed in 2px violet under "Removing this copy" when ticked. Below, a decision strip (4px corners, 12px padding) on Desk, or Stamp Wash when ticked, with the tick box and "Will be removed (Space to keep)". Then the "How we know" slip.

### Tooltip
Ink ground, Catalog Stock 12px text, 4px corners.

## Do's and Don'ts

### Do:
- **Do** reserve Stamp-Pad Violet (#5B3C8C) for removal only: ticked boxes, the REMOVE stamp, the Clean button, the picked part of the storage bar.
- **Do** show focus and the active navigation item in ink (#2B2A27): a 2px ink border on the focused card, an ink bar on the active rail entry.
- **Do** print the red rule (#C8382E) across the top of every card (3px) and slip (2px).
- **Do** type every item fact at 12.5px Consolas and rank facts by weight and ink, not size.
- **Do** crop card thumbnails from the top.
- **Do** keep the REMOVE stamp in the bottom-left corner of the picture.
- **Do** keep surfaces flat: paper on desk, 1px Buff Edge lines, no shadows.

### Don't:
- **Don't** use violet for focus, hover, navigation selection, progress, links or neutral actions.
- **Don't** use the red rule colour for warnings, errors, progress or data bars.
- **Don't** add a dark theme; photos are judged on paper.
- **Don't** place the stamp, or anything else, over the part of a picture the user reads to decide.
- **Don't** introduce a second fact size or set figures in the interface face.
- **Don't** use rounded tiles, bright blue checkmarks or other generic phone-cleaner styling.
