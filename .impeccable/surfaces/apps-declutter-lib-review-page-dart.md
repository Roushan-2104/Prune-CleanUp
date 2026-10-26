---
version: 1
slug: "apps-declutter-lib-review-page-dart"
primary_target: "apps/declutter/lib/review_page.dart"
related_targets: ["apps/declutter/lib/home_page.dart"]
---

# Review and home (Declutter desktop)

Mode: Operate. Users open the app with a full phone, see one safe pick ("You can free X GB", sure items only), glance through it group by group, adjust, and clean. Must keep: side-by-side kept vs copy, "How we know", keyboard shortcuts (arrows, Space, Ctrl+A, Esc), in-app video playback. Must not feel too empty, hide the proof, or feel playful. Each item shows its picture plus one short reason.

## Direction contract

THESIS: Removing things is a careful librarian's weeding round: every item carries a slip with its reason and only stamped items leave. Refuses the generic cleaner grid of blue checkmarks and rounded tiles.

OWN-WORLD: Catalog-card stock (#FBFAF6) on a pale desk ground (#F3F1EB), ink #2B2A27, a red top rule (#C8382E) on every card and slip, violet stamp-pad ink (#5B3C8C) for selection and the Clean action, faint blue ruling (#E7EDF4) inside slips. Segoe UI for the interface, a typed monospace for facts and reasons.

STORY: The user sees how much the safe pick frees, trusts it because each item shows its picture, one typed reason and a full slip on demand, unticks anything doubtful, and cleans.

FIRST VIEWPORT: Top bar: Declutter, phone, storage bar whose violet hatched part is the pick, "Clean 2.6 GB…". Left rail: SURE TO REMOVE and FOR YOU TO CHECK groups with sizes and a size bar. Middle: open group, sub-groups by person/app, 4-column grid of cards (picture, typed reason, size and date cells), ticked cards stamped REMOVE. Right: the focused item large, its kept copy beside it, HOW WE KNOW slip.

FORM: Library weeding slip, candidate 6 of 7; raises: one text size for item facts (timetable), live capacity bar (j-card), rail bars sized by space (tab board), fixed fact cells (split-flap). seed:6dccefc648e8fd9b

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
