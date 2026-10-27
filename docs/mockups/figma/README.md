# Figma generators for SigmaFlow 1.0

The screens in the Figma file "SigmaFlow 1.0" (key TX8R9zWm5H3YS9WaqO3JBJ) are drawn by these two scripts
through the Figma MCP `use_figma` tool, not by hand.

- `prelude.js`: tokens, helpers (AL, T, card, row, footer, button, switcher, gauges, windowFrame, note, stateStrip).
  A copy lives in the file as a hidden, locked text node named `__prelude__` on Page 1 (node 23:2, parked at x -3000).
  Keep the node and this file identical; patch both when changing a helper.
- `screens.js`: one `screen_*` function per window. Also stored in the file as hidden text node `__screens__`
  (node 33:2). `windowFrame` reuses the frame whose name starts with the same number, so redrawing keeps node ids
  and the comment pins attached.

To redraw a screen: read nodes 23:2 and 33:2, then evaluate `pre.characters + scr.characters + "screen_x(X); return ids;"`
with an AsyncFunction. Both files must stay free of backticks, backslashes and `${` because
the screen source is pasted into a template literal.

screens.js is over the 50,000-character limit of one `use_figma` script, so it goes into node 33:2 in two pieces
(set the first, `insertCharacters` the second at the end). Compare length and a hash of the node with the file afterwards.

Since 11 Oct 2026 the file is drawn from the app on main, not from earlier mockups: each window was compared with the
app's own `--snapshot-dir` render, and every state the code can reach (empty, no match, editing, disabled, confirm, Copied,
download progress and failure, outcomes) sits as a "state …" strip under its window with a note. Sample words stand in
for real dictations; settings and install states match Gokul's Mac (Right ⌘, Claude Desktop connected, Cohere installed).

Text is created in Geist Mono (Geist Pixel cannot be loaded from scripts). After a redraw, in the Figma desktop app:
select one word, ⌘/ "Select all with same font", pick Geist Pixel Square; the wordmark's "flow" layers are Geist Mono
Light, swap those to Geist Pixel Circle.

Canvas, 1300 apart: 20 Transcriptions @0, 21 Dictionary @1300, 22 Snippets @2600, 23 Styles default styles @3900,
23B Styles custom styles @5200, 23C Styles custom styles first visit @6500, 24 Models English only @7800, 24B Models Multilingual
@9100, 27 Settings Dictation @10400, 27B Connections @11700, 27C Your data @13000, 28 HUD @14300.
28 is a 1560-wide board, not a window: every overlay and correction-notice state, cards bottom-aligned, with the
DS.Motion timings in a note beside each strip (`screen_hud`). The Overlay tiles on 27 reuse the same card at 80%.
Backlog row, y 2600: 20B Insights A numbers @0, 20C Insights B story @1300, 20D Insights C habits @2600. The Insights
tab is not in 1.0; Gokul leans to B with A's streak calendar. Meetings (25, 26) were deleted from the file on 10 Oct 2026 at Gokul's request.
