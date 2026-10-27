# SigmaFlow design spec, 1.0

One page. Every screen in the app obeys it. Where the current app disagrees with this
document, the app is wrong. The canvas is the other half of the spec:
<https://app.paper.design/file/01M4HEZY7264F9RNZXHN3NCQZB>. Board 05B is the reference
rendering, 08 holds the wordmark, 09 the page template, 10 the control inventory, 12 the HUD.

Decided with Gokul on 10 October 2026: Geist as the foundation, a native Mac frame, the
Death of Socrates in colour behind translucent surfaces, Geist Pixel for all type, dark only.

## 1. What the app is

A push-to-talk dictation tool. The window exists to find what you said and to change how
the app behaves. It is not where work happens, so it must be quiet, fast to scan and never
need reading.

## 2. The ground

**Foundation: Geist.** Vercel's design system supplies every value below. They were read
from the stylesheet vercel.com ships, not from memory. **Frame: native.** macOS owns the
window, the traffic lights, the sidebar column, the menu bar, pickers and scrollbars.
Geist dresses what sits inside. A Mac app that copies a web dashboard reads as Electron;
this one must not.

**Appearance: dark only.** The painting wants it.

### Colour

Geist's dark gray scale, verbatim. Grays are the whole palette; blue appears only where
macOS itself would put it (the on state of a toggle, a focus ring).

| Token | Value | Use |
|---|---|---|
| `bg100` | `#0A0A0A` | window ground where the painting is not |
| `bg200` | `#000000` | recessed footers |
| `gray100` | `#1A1A1A` | hover on a sidebar row |
| `gray200` | `#1F1F1F` | selected sidebar row |
| `gray300` | `#292929` | — |
| `gray400` | `#2E2E2E` | control fill |
| `gray500` | `#454545` | off toggle track, disabled edge |
| `gray600` | `#878787` | placeholder |
| `gray700` | `#8F8F8F` | tertiary text, chevrons |
| `gray800` | `#7D7D7D` | — |
| `gray900` | `#A1A1A1` | secondary text, captions, eyebrows |
| `gray1000` | `#EDEDED` | primary text, the inverted button |
| `blue700` | `#0071F6` | toggle on, focus ring |
| `border` | `rgba(255,255,255,0.145)` | every 1 px edge |
| `glass` | `rgba(10,10,10,0.72)` | card surface over the painting |
| `rail` | `rgba(0,0,0,0.55)` | sidebar and toolbar over the painting (vibrancy in code) |
| `meterGreen` | `#32D74B` | the live audio meter, unchanged |

### The painting

The Death of Socrates, in colour, darkened to about 58 percent black, scaled to fill the
window behind everything. Cards sit on `glass`, the sidebar and toolbar on `rail`, so the
painting reads clearly in the gutters and faintly through the surfaces. The black and white
render in `Resources/background.jpg` today is retired; the colour source replaces it.

### Shape and material

Radius 8 on cards and the window, 6 on controls, per Geist. Edges are 1 px `border`; there
are no filled dividers that run past a container. No shadows inside the window. No
gradients, nothing blinks. Hover is a fill, never a colour change.

### Type

**Geist Pixel for everything**, the variable file, axis `ELSH` at 100 as the base shape.
`ELSH` 50, the dotted shape, is a texture accent and appears in exactly one place: the
second half of the wordmark. Geist Mono carries code-like strings only (paths, commands).
No other face. Font files ship in the bundle under the OFL as Plex does today.

| Style | Size / line | Use |
|---|---|---|
| `title` | 22 / 28 | the toolbar title |
| `wordmark` | 28 / 32 | Sigma at ELSH 100, flow at ELSH 50 |
| `eyebrow` | 12 / 16, tracking 0.06em, uppercase | section labels |
| `body` | 14 / 20 | rows, controls, buttons (weight 500 on buttons) |
| `caption` | 13 / 18 | one line under a row, `gray900` |
| `data` | 13 / 18 | file names, counts, timers, in `gray900` |
| `mono` | 12 / 16, Geist Mono | commands and paths |

Form heights are Geist's: 32 for controls, 36 for a prominent control, 40 for a hero.

### What leaves

The hardware tokens (screws, vents, lamps, grain, needle sweep), `BrushedPanel`, `Well`,
`DeckWindow`, `Screw`, `Vents`, `Lamp`, the Toast, the full-bleed `listBleed` hairline,
IBM Plex, the Carbon icons (replaced by Geist's icon set, same monochrome template
treatment), the block ASCII wordmark, the sharp-corner rule, the solid black sidebar, and
every middle dot in the interface.

## 3. The page

Every page is the same shape.

```text
┌ sidebar 220 ┬──────────────────────────────────────────────────┐
│ ● ● ●       │  Title                              [instrument]  │  toolbar 52, rail
│ Sigmaflow   │──────────────────────────────────────────────────│
│ nav         │  EYEBROW                                          │
│             │  ┌ card ────────────────────────────────────────┐ │  scrolls
│             │  │ row                                          │ │
│             │  │ row                                          │ │
│             │  └──────────────────────────────────────────────┘ │
│             │  EYEBROW                                          │
│ 1.0.0       │  ┌ card ────────────────────────────────────────┐ │
└─────────────┴──────────────────────────────────────────────────┘
```

- **Sidebar** 220 wide on `rail`: traffic lights, the wordmark, seven items (icon plus
  label, 30 high, radius 6, selected on `gray200`), the version at the foot read from the
  bundle. Nothing else.
- **Title row**: the page title in `title` at the left, the instrument slot at the right,
  at the top of the page content, scrolling with it. No bar, no line under it (Gokul,
  10 Oct 2026: a pinned bar read as a second window chrome). The slot holds at most one
  live thing: the recording meter and timer on Transcriptions, the recording strip on
  Meetings, nothing elsewhere.
- **One scroll model.** The whole page scrolls as one. No page nests a second scroller.
- **Secondary controls go under, not beside.** A refresh lives as the last item of the
  popup it refreshes; a connection status sits on the line under the field and its
  button; sound pickers sit under the switch that enables them, aligned to its lane.
- **Every row has a caption** unless its label is the whole story.
- **Sections** open with an eyebrow and hold one card. A card is a `glass` surface with a
  1 px `border`, radius 8, rows divided by 1 px `border` lines that stop at the card's edge.
- **Rows** are 52 high without a caption and grow to fit one caption line with one. Label
  left, data in `data` to the right of it, the control in a fixed lane at the right edge.
- **Width.** Page padding 28 top and sides, 40 at the foot. Prose caps at 620.

### The HUD

What appears while the key is held. Board 12 is the reference. A card 440 wide on real
glass: `rgba(16,16,16,0.62)` over a 24 px blur of whatever is behind it, 1 px `border`,
radius 12, anchored above the Dock and growing upward from a fixed bottom edge. It never
takes focus. Nothing blinks. No painting: it sits on someone else's screen.

- **Status row**: a glyph, a label in `eyebrow`, the timer in `data`, the meter. The glyph
  is a steady dot for REC, a lock for LOCKED (hands-free, after a double-tap), and the
  Carbon `circle-dash` ring, static, for PROCESSING. No hint text in any state; the way
  out of a lock is the hotkey, any key, or Esc, and the user knows it.
- **Words** in `body` at 15 / 22 under the status row, in `gray1000` while listening, in
  `gray900` while processing. The Minimal overlay setting hides the words and keeps the row.
- **Correction notice**, the same card at the same inset (18 across, 14 down): ADDING TO
  DICTIONARY in `eyebrow` and `gray900`, the misheard word struck through, an arrow, the
  fix, a 2 px `dim` bar filling from the left over about three seconds, and one button,
  Not now, centred on the text block at the right. The pointer over the card holds the bar.
  When the bar is full the rule is added and the label flips to ADDED TO DICTIONARY in
  `gray1000`, no mark before it, with an Undo; it holds about two seconds and fades. The
  bar's room stays after it goes, so the card never changes height. Not now removes the
  card at once and adds nothing. Picked 16 Oct 2026 (docs/mockups/correction-notice.html,
  1A 2B 3A 4C 5B, the bar counting up).

Decision, 10 October 2026: **silence is yes.** This reverses the September change that made
the notice ask first. It is deliberate, and it is bearable because the rule is visible (the
LEARNED tag), reversible (Undo, ⌥⌫, Delete all learned) and the bar holds under the pointer.
`CLAUDE.md`'s invariant on `CorrectionLearner` is rewritten when the code changes.

## 4. Copy budget

- No sentence inside the app longer than one line at 620 px.
- A row may carry one caption under its label, in `caption`. Never two lines.
- Anything longer is not a caption. It moves to Help (one page, reached from the Help
  menu) or is cut.
- Empty states are one sentence and, where there is one, the action.
- No marketing voice. No "just", no "simply", no reassurance about privacy on every page.
  Privacy is stated once, in Settings, under Your data.
- No middle dots anywhere. Separate facts with space and tone.

## 5. The controls, and only these

| Control | Spec | Replaces |
|---|---|---|
| **Button, secondary** | `gray400` fill, `border`, `gray1000` label, 32 high, radius 6. The everyday button. | ghost `AppButton` |
| **Button, inverted** | `gray1000` fill, `bg100` label. At most one per page, for the action the page exists for (Export, Start recording). Many pages have none. | primary `AppButton` |
| **Button, tertiary** | no fill, `gray900` label, fill on hover. Row actions. | link `AppButton` |
| **Popup** | native `NSPopUpButton` look: 32 high, `gray400` fill, `border`, up-down chevron in `gray700`. Picks one of N. | `RadioOption`, `ProviderCard`, `EngineChoice`, `SegmentRow`, the Option-key buttons, Models' Use |
| **Toggle** | native switch look: 28 by 16, `blue700` on, `gray500` off. | `CheckOption`, `RuleToggle` |
| **Field** | 32 high, `gray400` fill, `border`, radius 6, placeholder `gray600`. Multi-line grows from 64. | the five ad-hoc field chromes |
| **Card row** | the row described in section 3. Actions sit in the control lane as tertiary buttons. | `ListRow` and every bespoke row |
| **Editor row** | a card row that expands in place to hold fields and a secondary plus a tertiary button. Adding opens it at the top of the list, editing opens it under the row. | the Styles full-page editor, the Dictionary and Snippets top forms, the meeting-type editor |
| **Status line** | `caption` in `gray900` with a 14 px checkmark, appears where the action was, fades after 1.4 s. | Toast, `CopiedLabel`, the outcome boxes |
| **Key chip** | `mono` on `gray400`, `border`, radius 4. | keep |
| **Eyebrow**, **Readout**, **VUMeter** | as in section 2; the meter keeps its green. | keep |

Resolved from the review of board 03: a button never sits closer than 12 px to a divider
or a field edge; dividers never run past their container; row heights are fixed, not
content-driven; the inverted button is rare and gray is the default.

Meter bars with percentages on Models are gone. A model row carries three facts in
`data`: languages, size, live or on release.

## 6. Where settings live

Everything that is a setting is on Settings. A page may show a link to the setting it
depends on; it does not host the control.

```text
Settings
  DICTATION     Push-to-talk key, Microphone, Overlay,
                Clean up, Smart cleanup, Sound, Pause media, Learn from corrections
  REWRITING     Engine popup, key field with Test connection under it
  MEETINGS      Engine popup, Sarvam key and Tamil script under it
  CONNECTIONS   Claude Desktop, Claude Code, helper path
  YOUR DATA     the manifest card, Import and Export in its footer
```

- Models stays its own page: it is a catalog with downloads, not a setting.
- Styles, Dictionary, Snippets lose their engine and learning controls and gain one
  line each: "Engine: Claude. Change in Settings."
- `⌘,` opens the main window on Settings. The separate Settings scene is deleted.
- Settings save on change, as every Mac preferences pane does. There is no Save button.

## 7. The wordmark

`Sigmaflow` set in Geist Pixel at 28 px, `Sigma` at ELSH 100, `flow` at ELSH 50, in
`gray1000`, in the sidebar head under the traffic lights. The product is written
**SigmaFlow** everywhere it appears in a sentence. The mark is a drawing of the name and
sets it as one word; the two halves are told apart by texture, not by a capital.

## 8. Tokens

`DS` is the only source of a number. The 117 literal paddings and frames in `UI/` become
tokens or go. `DS` is rebuilt around the names in section 2 and the sizes in sections 3
and 5; the Paper file carries the same names.

## 9. Scope for 1.0

Meetings ships behind a flag, off by default. It is built for one team, used 16 times,
and carries half the UI's literal values. It comes back when it is generic.

## 10. Order of work

1. Boards 09 and 10 on Paper, approved there.
2. Fonts, the colour painting and Geist icons into Resources. `DS` rebuilt. The Controls
   file, so every later page has parts to use.
3. Settings, then Transcriptions, Dictionary, Snippets, Styles, Models, in that order,
   each mocked on Paper before it is built.
4. Sidebar and wordmark, `⌘,`, Help page.
5. Onboarding, notarization, updates. Plumbing, after the design pass.
