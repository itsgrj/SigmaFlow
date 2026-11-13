# SigmaFlow design kit

**For the coding agent.** Read this whole file before you write any UI. This project is a
Mac app that must look and behave exactly like SigmaFlow, Gokul's dictation app. Treat
everything here as rules, not suggestions. When this file and your habits disagree, this
file wins. When this project's own CLAUDE.md or AGENTS.md disagrees with it, that file wins
for this project.

Taken from SigmaFlow's code on 5 Nov 2026 (`Sources/SigmaFlow/UI/DesignSystem.swift` and
`UI/Equipment.swift`). The code is the truth; where SigmaFlow's older prose mentions IBM Plex
or square corners, that is out of date.

## Contents

1. The look in one paragraph
2. Rules
3. Project setup and assets
4. `DesignSystem.swift`, the tokens (copy as is)
5. `Components.swift`, the parts (copy as is)
6. The main window
7. Floating panels and widgets
8. Behaviour
9. Words
10. Worked example: a small timer
11. Before you say it is done

**Starting a new project, in order:** set up the package and copy the assets (§3), create
`UI/DesignSystem.swift` from §4 and `UI/Components.swift` from §5 exactly as written, then
build the window (§6) or the floating panel (§7) the app needs. Run §11 before you report
anything as finished.

---

## 1. The look in one paragraph

Dark only. The palette is Vercel's Geist dark gray scale, used as is. White is the only ink,
in three strengths. Behind the main window hangs Jacques-Louis David's *The Death of
Socrates*, in colour, under a 58% black scrim. Surfaces over it are dark glass with a 1 px
white edge at 14.5%. Every letter is **Geist Pixel Square**, a pixel face with one weight.
Code-like strings (paths, commands) use Geist Mono. Icons are **IBM Carbon**, drawn as
templates in the current ink. Controls are 32 high with 6 px corners, cards have 8, floating
panels 12. Only one colour is not grey: system green, for a live signal (a level meter, a
done tick). Blue appears only where macOS itself puts it: a switch that is on, a focus ring.
Nothing blinks, nothing bounces, nothing has a gradient, and there are no toasts. Emphasis
comes from ink strength, never from weight or colour.

---

## 2. Rules

### Platform

- macOS 26 or later, Swift 6, SwiftUI. Use AppKit only where SwiftUI can't do the job:
  panels, vibrancy, cursors.
- Dark only. Put `.preferredColorScheme(.dark)` on every window root and
  `NSAppearance(named: .darkAqua)` on every panel. There is no light mode.
- **Views must not contain literal values.** Every colour, size, radius, duration and font
  is a token in `DS`. If a view needs a number that isn't there, add a token with a short
  comment saying what it is for. Don't inline it, even once.

### Ink and type

- Text uses one of three colours: `DS.Color.ink` for what you read, `inkSecondary` for
  captions, data and labels, and `dim` for the faintest things (placeholders, timestamps,
  faint actions). There are no others.
- Fonts come from `DS.Font` only. Geist Pixel has one weight, so never use `.bold()`,
  `.fontWeight(...)`, `.italic()` or `Font.system(...)`. To make something stand out, give
  it stronger ink (ink over inkSecondary) or a bigger token.
- A section label is an `Eyebrow`: uppercase, 12, tracking 0.72, secondary ink. The
  component does the uppercasing, so write the string in normal case.
- Numbers that change (timers, counts, percentages) use `DS.Font.data` or `Readout`, which
  have monospaced digits, so nothing jitters as they tick.

### Icons

- IBM Carbon SVGs only, called by Carbon's exact file name through `CarbonIcon(name:)`.
  Never SF Symbols (`Image(systemName:)`), never emoji.
- Use the icon that is actually named for the thing: video is `video`, not `camera`. If the
  right icon isn't in `Resources/Icons`, add the real Carbon SVG (§3). Don't borrow a
  lookalike.
- A busy state is the static `circle-dash` icon, never a spinner.

### Shape and surface

- Corner radii come only from this scale: chip 4, control 6, card 8, window 11, floating
  panel 12.
- Every edge is 1 px `DS.Color.border`. Use `borderStrong` for a hovered secondary button, a
  focused field, an inline editor, or the edge of a floating panel.
- Never paint a gradient. The one gradient in the code is the mask in `scrollEdgeFade()`,
  which fades content out and paints nothing.
- Views get no drop shadows. A floating panel gets the window server's own shadow
  (`hasShadow = true`).
- Green (`DS.Color.live`) is only for a live signal or a done tick. Blue (`blue700`) is only
  for a switch that is on and a focus ring. There is no accent or brand colour, and no red
  for danger.

### Motion

- Quick and quiet: ease-out, 0.05 to 0.35 s, all from `DS.Motion`. Panels fade in over
  0.16 s and out over 0.3 s.
- No springs, no bounces, no scale pops, no pulsing. A recording dot is steady. Nothing
  blinks, ever, including when a timer finishes.

### Layout

- **No page scrolls as a whole.** On a page with tabs, the header and tab strip stay put and
  only the content under them scrolls (`PageScroll`). On a list page, the header and search
  stay put and the rows scroll inside their card (`ListPage` plus `CardScroll`).
- Every `ScrollView` gets `.scrollEdgeFade()`.
- Page insets are 24 at the top and 28 at the sides and foot. Sections sit 28 apart, prose
  is never wider than 620, and a page subtitle wraps at 560.
- Settings-like content is a `Card` of `CardRow`s: the label on the left, the control in a
  lane on the right, at most one caption line, and dividers that stop at the card's edge.
- The only button is `AppButton`, in three kinds. A screen has at most one `.inverted`
  button, for the thing the screen exists for, and many screens have none. Actions inside a
  row are `.tertiary`.
- Anything clickable gets `.handCursor()` and `hoverFill` on hover.

### Outcomes and danger

- **No toasts, banners or alerts that announce a result.** The result shows where the
  action happened, for `DS.Motion.statusHold` (1.5 s): `CopyButton` turns into Copied, and
  a `StatusLine` shows a green tick and a few words.
- Danger is shown by where things sit, not by colour. Delete is faint text at the end of a
  list (`FaintDelete`), never on a row, and never beside the main action. It always leads to
  a question: a centred card where Cancel answers Return and Esc, and Delete only becomes
  live after `DS.Motion.deleteArm` (0.5 s). After that, Undo is offered for
  `DS.Motion.undoHold` (6 s). Deleted files go to the Mac's Trash, but the UI never says
  "Trash".

---

## 3. Project setup and assets

### Where the assets come from

The SigmaFlow repo, cloned at `/Users/grj/Desktop/[ SIGMAFLOW ] /`. The folder name has
spaces and a **trailing space**, so always quote the path. It is also public at
<https://github.com/itsgrj/SigmaFlow>.

| Asset | Copy from (in the SigmaFlow repo) | Into this project | Notes |
|---|---|---|---|
| Fonts | `Resources/Fonts/GeistPixel-Square.ttf`, `GeistPixel-Circle.ttf`, `GeistMono-Regular.otf` | `Resources/Fonts/` | SIL Open Font License. Registered by `ATSApplicationFontsPath`. |
| Painting | `Resources/background-colour.jpg` (2600 by 1707) | `Resources/` | Public domain (Wikimedia Commons). Only for apps with a main window. |
| Icons | `Resources/Icons/<name>.svg` and `LICENSE-carbon-icons.txt` | `Resources/Icons/` | Copy only the icons you use, plus the licence. |

```bash
SF="/Users/grj/Desktop/[ SIGMAFLOW ] "
mkdir -p Resources/Fonts Resources/Icons
cp "$SF/Resources/Fonts/GeistPixel-Square.ttf" "$SF/Resources/Fonts/GeistPixel-Circle.ttf" \
   "$SF/Resources/Fonts/GeistMono-Regular.otf" Resources/Fonts/
cp "$SF/Resources/background-colour.jpg" Resources/
cp "$SF/Resources/Icons/LICENSE-carbon-icons.txt" Resources/Icons/
for i in add checkmark close circle-dash copy edit search settings trash-can warning; do
  cp "$SF/Resources/Icons/$i.svg" Resources/Icons/
done
```

An icon SigmaFlow doesn't have comes straight from Carbon, at the 32 px size:

```bash
curl -fsSL -o Resources/Icons/timer.svg \
  https://raw.githubusercontent.com/carbon-design-system/carbon/main/packages/icons/src/svg/32/timer.svg
```

Look the name up at <https://carbondesignsystem.com/elements/icons/library/>. If `curl`
returns 404, the name is wrong. Look it up again rather than picking a lookalike.

The app icon is the app's own. Never reuse SigmaFlow's sigma. Until Gokul supplies one, ship
without `AppIcon.icns`, and `AppIconTile` will fall back to the system's generic icon.

### Package and bundle

SwiftPM plus a Makefile, no Xcode project. This Mac has only the Command Line Tools, and
the Makefile assembles a real `.app`, which macOS needs for permissions, fonts and signing.

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppName",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "AppName",
            path: "Sources/AppName",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

Resources are **not** SwiftPM resources. The Makefile copies them into
`Contents/Resources`, and the code reads them through `Bundle.main`.

`Resources/Info.plist` must include these keys (plus the usual `CFBundleIdentifier`,
`CFBundleExecutable`, `CFBundleName`, `CFBundleShortVersionString` and
`CFBundlePackageType` `APPL`):

```xml
<key>ATSApplicationFontsPath</key>
<string>Fonts</string>
<key>LSMinimumSystemVersion</key>
<string>26.0</string>
<key>NSHighResolutionCapable</key>
<true/>
<!-- false: a Dock icon and an app menu. true: a widget-only app with no Dock icon. -->
<key>LSUIElement</key>
<false/>
```

`Makefile`. Build products and the bundle live in `~/Library/Caches`, never in the project.
Desktop and Documents sync to iCloud on this Mac, and the sync engine changes files mid-build
("input file was modified during the build") and stamps attributes that `codesign` refuses.
**Always build through `make`, never bare `swift build`.**

```make
EXEC     := AppName
SCRATCH  := $(HOME)/Library/Caches/$(EXEC)Build/scratch
STAGE    := $(HOME)/Library/Caches/$(EXEC)Build
BUNDLE   := $(STAGE)/$(EXEC).app
CONTENTS := $(BUNDLE)/Contents

## A stable signature keeps permission grants across rebuilds; ad hoc ("-") is the fallback.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep -E "Developer ID Application|SigmaFlow Dev" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build app run install clean
all: app

build:
	swift build -c debug --scratch-path "$(SCRATCH)"

app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(SCRATCH)/debug/$(EXEC)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp -R Resources/Fonts "$(CONTENTS)/Resources/Fonts"
	@cp -R Resources/Icons "$(CONTENTS)/Resources/Icons"
	@if [ -f Resources/background-colour.jpg ]; then cp Resources/background-colour.jpg "$(CONTENTS)/Resources/"; fi
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none "$(BUNDLE)"
	@codesign --verify --strict "$(BUNDLE)" && echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(EXEC).app"
	@cp -R "$(BUNDLE)" "/Applications/$(EXEC).app"
	@open "/Applications/$(EXEC).app"

clean:
	@rm -rf .build "$(STAGE)"
```

Once it builds, run `make install` yourself. Don't ask Gokul to do it. Never run the `.app`
from inside the project folder.

### Two things that look like bugs and are not

- `MainActor.assumeIsolated` asserts, it does not check. Off the main thread it crashes the
  process. Use `await MainActor.run` or `Task { @MainActor in ... }`. The only safe place
  for it is an AppKit completion handler that is documented to run on the main thread.
- Don't change `@State` inside a `Canvas` drawing closure. Keep per-frame physics in a plain
  reference type the view holds (see `VUMeter` in §5).

---

## 4. `DesignSystem.swift`, the tokens

Copy this file as it is. The SigmaFlow-only tokens are left out. The names match
SigmaFlow's, except where a SigmaFlow name was about dictation: `reading` is SigmaFlow's
`transcript`, `live` is `meterGreen`, `floating` is `hud`.

```swift
import SwiftUI

/// The design system, taken from SigmaFlow. Geist as the foundation, a native Mac frame.
/// Vercel's dark gray scale is the whole palette. Geist Pixel is the only text face; Geist
/// Mono carries code-like strings. Dark only. Radius 8 on cards, 6 on controls. Nothing blinks.
///
/// Every colour, size, radius and duration a view needs is a token here. Views must not
/// contain literal values; if a number is missing, add the token.
enum DS {

    // MARK: - Color

    enum Color {
        // Geist dark scale, read from the stylesheet vercel.com ships.
        static let bg100 = swatch(0x0A0A0A)
        static let bg200 = swatch(0x000000)
        static let gray100 = swatch(0x1A1A1A)
        static let gray200 = swatch(0x1F1F1F)
        static let gray300 = swatch(0x292929)
        static let gray400 = swatch(0x2E2E2E)
        static let gray500 = swatch(0x454545)
        static let gray600 = swatch(0x878787)
        static let gray700 = swatch(0x8F8F8F)
        static let gray800 = swatch(0x7D7D7D)
        static let gray900 = swatch(0xA1A1A1)
        static let gray1000 = swatch(0xEDEDED)
        /// Where macOS itself would put blue: a toggle's on state, a focus ring.
        static let blue700 = swatch(0x0071F6)

        /// Every 1 px edge.
        static let border = SwiftUI.Color.white.opacity(0.145)
        /// A stronger edge: the focused field, the hovered button, a floating panel.
        static let borderStrong = SwiftUI.Color.white.opacity(0.20)
        /// Control fill: buttons, popups, fields, key chips.
        static let controlFill = SwiftUI.Color.white.opacity(0.06)
        /// Hover on anything clickable.
        static let hoverFill = SwiftUI.Color.white.opacity(0.08)
        /// The selected sidebar row, a hovered path part.
        static let selectedFill = SwiftUI.Color.white.opacity(0.10)

        /// Card surface over the painting.
        static let glass = SwiftUI.Color(.sRGB, red: 10/255, green: 10/255, blue: 10/255, opacity: 0.72)
        /// Sidebar over the painting (vibrancy in code, this colour laid over it).
        static let rail = SwiftUI.Color.black.opacity(0.55)
        /// A floating panel: real glass, with a blur behind it.
        static let floatingGlass = SwiftUI.Color(.sRGB, red: 16/255, green: 16/255, blue: 16/255, opacity: 0.62)
        /// A recessed footer inside a card.
        static let footer = SwiftUI.Color.black.opacity(0.35)
        /// The editor row at the head of a list card: a shade lighter than the card.
        static let editorFill = SwiftUI.Color.white.opacity(0.03)
        /// An unlit gauge block, and the track of a progress or countdown line.
        static let gaugeOff = SwiftUI.Color.white.opacity(0.14)
        /// The ring of a radio mark that is not chosen.
        static let radioOff = SwiftUI.Color.white.opacity(0.35)
        /// Laid over the painting so the surfaces read.
        static let paintingScrim = SwiftUI.Color.black.opacity(0.58)
        /// Over the page while a question (delete?) is open, and the question's own card.
        static let questionVeil = SwiftUI.Color.black.opacity(0.55)
        static let questionFill = swatch(0x111111)
        /// The tick box: its edge while empty, its fill.
        static let tickEdge = SwiftUI.Color.white.opacity(0.45)
        static let tickFill = SwiftUI.Color.black.opacity(0.35)

        // Text
        static let ink = gray1000
        static let inkSecondary = gray900
        static let dim = gray700
        static let placeholder = gray600
        /// Label on the inverted button.
        static let inkOnInverted = bg100

        /// The one colour: a live signal (a level meter, a done tick).
        static let live = swatch(0x32D74B)
        static let liveOff = SwiftUI.Color.white.opacity(0.18)

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(
                .sRGB,
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }

    // MARK: - Material

    enum Material {
        /// How far a scrolled list fades out at an edge that has more beyond it.
        static let scrollFade: CGFloat = 40
        /// The sidebar column.
        static let sidebarWidth: CGFloat = 220
        /// The main window: opens at this size, never shrinks below the minimum.
        static let windowWidth: CGFloat = 1160
        static let windowHeight: CGFloat = 760
        static let windowMinWidth: CGFloat = 980
        static let windowMinHeight: CGFloat = 620
        /// Room for the traffic lights at the top of the sidebar.
        static let titleBarClearance: CGFloat = 52
        /// A sidebar item.
        static let navRowHeight: CGFloat = 38
        /// The search box at the head of a list page.
        static let searchWidth: CGFloat = 360
        /// A row inside a card, without a caption.
        static let cardRowHeight: CGFloat = 52
        /// The underline under the open tab.
        static let tabUnderline: CGFloat = 2
        /// A radio mark and its dot.
        static let radioSize: CGFloat = 16
        static let radioDot: CGFloat = 8
        static let radioStroke: CGFloat = 1.5
        /// A progress line.
        static let progressWidth: CGFloat = 92
        static let progressHeight: CGFloat = 2
        /// Five-block gauges.
        static let gaugeBlocks: Int = 5
        static let gaugeBlockWidth: CGFloat = 14
        static let gaugeBlockHeight: CGFloat = 4
        static let gaugeBlockGap: CGFloat = 3
        static let gaugeLabelWidth: CGFloat = 68
        /// The tick box.
        static let tickSize: CGFloat = 16
        static let tickMark: CGFloat = 12
        /// Faint actions at the end of a list (delete, the path bar).
        static let faintOpacity: Double = 0.75
        /// The app icon beside the wordmark.
        static let logoSize: CGFloat = 28
        /// A floating panel: its width, where a passing one sits above the Dock, and how far a
        /// lasting one sits in from the screen's corner.
        static let floatingWidth: CGFloat = 440
        static let floatingBottomInset: CGFloat = 96
        static let floatingCornerInset: CGFloat = 14
        /// The delete question.
        static let questionWidth: CGFloat = 360
        static let questionPad: CGFloat = 20

        // Level meter: round dots that fill left to right.
        static let meterSegments: Int = 14
        static let meterSegmentGap: CGFloat = 3
        static let meterDotSize: CGFloat = 5
    }

    // MARK: - Controls

    /// Geist's form sizes: 32 for a control, 36 for a prominent one, 40 for a hero.
    enum Control {
        static let height: CGFloat = 32
        static let heightProminent: CGFloat = 36
        static let heightHero: CGFloat = 40
        static let padX: CGFloat = 12
        /// A quiet (tertiary) button sits a little tighter.
        static let padXQuiet: CGFloat = 10
        /// A compact button, for a floating panel's row of several.
        static let heightCompact: CGFloat = 26
        static let padXCompact: CGFloat = 8
        static let iconGapCompact: CGFloat = 6
        static let iconSize: CGFloat = 16
        /// Sidebar item icons sit a touch smaller than button icons.
        static let navIconSize: CGFloat = 15
        static let iconGap: CGFloat = 8
        static let fieldHeight: CGFloat = 32
        static let fieldPadX: CGFloat = 12
        static let fieldPadY: CGFloat = 8
        /// A multi-line input never starts shorter than this.
        static let fieldMinHeight: CGFloat = 64
        /// A popup in a card row; the wide one holds a long label.
        static let popupWidth: CGFloat = 200
        static let popupWidthWide: CGFloat = 240
        static let iconSizeSmall: CGFloat = 14
        static let iconSizeTiny: CGFloat = 12
        /// The control lane at the right edge of a card row is at least this wide.
        static let laneMinWidth: CGFloat = 32
        /// The glyph at the head of a floating panel's status row, and its dot.
        static let statusGlyph: CGFloat = 12
        static let statusDot: CGFloat = 8
        /// The dot beside a sidebar item while something there is live.
        static let liveDot: CGFloat = 6
    }

    // MARK: - Type

    /// Geist Pixel is the only text face. The Square shape is the base; the Circle shape is
    /// a texture accent used in one place only, the second half of the wordmark. Geist Mono
    /// carries code-like strings: paths, commands. All ship in Resources/Fonts under the OFL
    /// and register through ATSApplicationFontsPath.
    ///
    /// Pixel has a single weight, so emphasis reads through ink, never through weight.
    enum Font {
        private static let pixel = "GeistPixel-Square"
        private static let pixelAccent = "GeistPixel-Circle"
        private static let monoFace = "GeistMono-Regular"

        /// A page title.
        static let title = pixelFont(22)
        /// The app's name in the sidebar head, and its accent half.
        static let wordmark = pixelFont(28)
        static let wordmarkAccent = SwiftUI.Font.custom(pixelAccent, size: 28)
        /// Section labels, uppercase through `Eyebrow`.
        static let eyebrow = pixelFont(12)
        static let eyebrowTracking: CGFloat = 0.72
        /// Rows, controls, buttons.
        static let body = pixelFont(14)
        /// One line under a row, in secondary ink.
        static let caption = pixelFont(13)
        /// File names, counts, timers.
        static let data = pixelFont(13).monospacedDigit()
        /// Words a person reads at length: a list row's text, a floating panel's message.
        static let reading = pixelFont(15)
        /// A tile's name.
        static let tileTitle = pixelFont(20)
        /// Gauge labels, uppercase at the call site.
        static let micro = pixelFont(11)
        static let microTracking: CGFloat = 0.44
        /// A large readout, and the one big number a screen exists to show.
        static let readoutLarge = pixelFont(22).monospacedDigit()
        static let display = pixelFont(40).monospacedDigit()
        /// The one sentence at the head of a card of figures.
        static let sentence = pixelFont(18)
        /// A setup window's step title.
        static let stepTitle = pixelFont(26)
        /// Commands and paths, and the small counter inside a text box.
        static let mono = SwiftUI.Font.custom(monoFace, size: 12)
        static let monoSmall = SwiftUI.Font.custom(monoFace, size: 11)

        private static func pixelFont(_ size: CGFloat) -> SwiftUI.Font {
            .custom(pixel, size: size)
        }
    }

    // MARK: - Spacing

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 32
        static let section: CGFloat = 56
        /// Page content: 24 at the top, 28 at the sides and the foot.
        static let pageTop: CGFloat = 24
        static let pageSide: CGFloat = 28
        static let pageBottom: CGFloat = pageSide
        /// Between one section (eyebrow plus card) and the next.
        static let sectionGap: CGFloat = 28
        /// Eyebrow to its card.
        static let eyebrowGap: CGFloat = 8
        /// Inside a card row.
        static let rowPadX: CGFloat = 16
        static let rowPadY: CGFloat = 12
        /// Between label and caption in a row.
        static let captionGap: CGFloat = 2
        /// Prose never runs wider than this.
        static let measure: CGFloat = 620
        /// Sidebar list inset, and the gap between items.
        static let navInset: CGFloat = 10
        static let navGap: CGFloat = 8
        /// Inside a sidebar item: side inset, and icon to label.
        static let navItemPadX: CGFloat = 12
        static let navItemGap: CGFloat = 12
        /// The wordmark block: 6 above, 20 below, 20 at the sides; icon to name.
        static let wordmarkTop: CGFloat = 6
        static let wordmarkBottom: CGFloat = 20
        static let wordmarkSide: CGFloat = 20
        static let wordmarkLogoGap: CGFloat = 10
        /// The version line at the foot of the sidebar.
        static let versionPadY: CGFloat = 14
        /// Title to subtitle in a page header; the subtitle wraps at about 65 characters.
        static let headerGap: CGFloat = 8
        static let subtitleMeasure: CGFloat = 560
        /// Tabs in a strip, and a tab label to its underline.
        static let tabGap: CGFloat = 24
        static let tabLabelGap: CGFloat = 10
        /// Inside a tile, and between tiles.
        static let tilePad: CGFloat = 20
        static let tileGap: CGFloat = 16
        /// The editor row at the head of a list card.
        static let editorPad: CGFloat = 16
        static let editorGap: CGFloat = 12
        /// Eyebrow to the field under it.
        static let fieldLabelGap: CGFloat = 6
        /// The empty state inside a card: 48 above and below.
        static let emptyPadY: CGFloat = 48
        /// A day label above its rows: 12 above, 8 below.
        static let dayLabelTop: CGFloat = 12
        static let dayLabelBottom: CGFloat = 8
        /// A floating panel's inset: 18 across, 14 down.
        static let floatingPadX: CGFloat = 18
        static let floatingPadY: CGFloat = 14
    }

    // MARK: - Radius

    /// Geist: 6 on controls, 8 on cards. The window and floating panels are a little rounder.
    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let window: CGFloat = 11
        static let floating: CGFloat = 12
        /// The app icon's corners as a share of its width, the Dock's proportion.
        static let appIconCorner: CGFloat = 0.225
    }

    // MARK: - Border

    enum Border {
        static let hairline: CGFloat = 1
        /// The hollow dot of something paused.
        static let pausedRing: CGFloat = 1.5
        /// Controls that can't act yet.
        static let disabledOpacity: Double = 0.35
        /// A line that fills or drains (a countdown, a notice's time left).
        static let bar: CGFloat = 2
        /// The dashed edge of a place to drop a file.
        static let dropDash: [CGFloat] = [4, 3]
    }

    // MARK: - Elevation

    enum Shadow {
        /// Under a floating panel, as drawn. The window server draws it, shaped to the card,
        /// so no view applies this directly.
        static let floating = Spec(color: .black.opacity(0.55), radius: 32, x: 0, y: 12)
        static let window = Spec(color: .black.opacity(0.45), radius: 24, x: 0, y: 10)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Motion

    /// Quick and quiet. Nothing blinks, nothing bounces.
    enum Motion {
        static let press = Animation.easeOut(duration: 0.05)
        static let release = Animation.easeOut(duration: 0.08)
        static let panel = Animation.easeInOut(duration: 0.15)
        static let fade = Animation.easeOut(duration: 0.22)
        /// A list scrolling to follow something.
        static let follow = Animation.easeInOut(duration: 0.35)
        /// A floating panel arriving and leaving.
        static let fadeIn: TimeInterval = 0.16
        static let fadeOut: TimeInterval = 0.3
        /// How long a status line ("Copied") stays before it fades.
        static let statusHold: TimeInterval = 1.5
        /// Deleting: how long Delete stays dim after the question opens, and how long Undo is offered.
        static let deleteArm: TimeInterval = 0.5
        static let undoHold: TimeInterval = 6
        /// Typing in a search box: exact matches at once, slower work after this pause.
        static let searchPause: TimeInterval = 0.25
        /// A floating panel growing: the window glides up on this ease-out.
        static let grow: TimeInterval = 0.26
        static let growCurve: (Float, Float, Float, Float) = (0.22, 1, 0.36, 1)
        /// The level meter rising and draining.
        static let meterAttack: TimeInterval = 0.12
        static let meterRelease: TimeInterval = 0.30
    }
}
```

---

## 5. `Components.swift`, the parts

Copy this file as it is. Pages are built from these parts, and new parts are built the same
way: tokens only, and each component carries its own chrome so a call site can't style it
halfway.

```swift
import AppKit
import SwiftUI

// MARK: - Icons

/// IBM Carbon icons from Resources/Icons, drawn as template images so they take the
/// surrounding foreground colour. The name is Carbon's own file name: `trash-can`,
/// `text--align--left`. A missing file draws nothing and is reported once.
struct CarbonIcon: View {
    let name: String
    var size: CGFloat = DS.Control.iconSize

    var body: some View {
        if let image = CarbonIconCache.image(named: name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

@MainActor
enum CarbonIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard !missing.contains(name) else { return nil }
        guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("Icons", isDirectory: true)
                .appendingPathComponent("\(name).svg"),
              let image = NSImage(contentsOf: url)
        else {
            missing.insert(name)
            print("Carbon icon missing: \(name).svg")
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 32, height: 32)
        cache[name] = image
        return image
    }

    /// For AppKit call sites (a menu bar item) that need a sized NSImage.
    static func nsImage(named name: String, size: CGFloat) -> NSImage? {
        guard let source = image(named: name), let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        copy.isTemplate = true
        return copy
    }
}

// MARK: - Ground

/// The main window's ground: the Death of Socrates in colour, scaled to fill, under a dark
/// scrim so the glass surfaces read. Falls back to near-black if the file is missing.
struct BackgroundImage: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "background-colour", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geo in
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(DS.Color.paintingScrim)
            } else {
                DS.Color.bg100
            }
        }
        .ignoresSafeArea()
    }
}

/// Native vibrancy for the sidebar: whatever is behind blurs through, pinned dark.
/// `DS.Color.rail` is the tint laid over it.
struct RailGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Pages

/// A page with tabs: the header and the tab strip stay put, and only what is under the
/// strip scrolls. No page scrolls as a whole.
struct PageScroll<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
                header
            }
            .padding(.top, DS.Space.pageTop)
            .padding(.horizontal, DS.Space.pageSide)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
                    content
                }
                .padding(.top, DS.Space.sectionGap)
                .padding(.horizontal, DS.Space.pageSide)
                .padding(.bottom, DS.Space.pageBottom)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollEdgeFade()
        }
    }
}

/// A list page: the header, the search and the card's head stay put, and only the rows
/// scroll, inside their card (`CardScroll`).
struct ListPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sectionGap) {
            content
        }
        .padding(.top, DS.Space.pageTop)
        .padding(.horizontal, DS.Space.pageSide)
        .padding(.bottom, DS.Space.pageBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The rows of a list card, scrolling inside it: as tall as the rows, never taller than
/// the room left.
struct CardScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollEdgeFade()
        .frame(maxHeight: height > 0 ? height : nil)
    }
}

/// Content fades out over `scrollFade` at an edge with more beyond it, and shows plainly
/// where it ends, so a list never looks cut off. A mask on the content, not a painted gradient.
private struct ScrollEdgeFade: ViewModifier {
    private struct Edges: Equatable {
        var top = false
        var bottom = false
    }

    @State private var edges = Edges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geo in
                Edges(
                    top: geo.visibleRect.minY > 1,
                    bottom: geo.visibleRect.maxY < geo.contentSize.height - 1)
            } action: { _, new in
                withAnimation(DS.Motion.panel) { edges = new }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: DS.Material.scrollFade)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: DS.Material.scrollFade)
                }
            }
    }
}

extension View {
    func scrollEdgeFade() -> some View { modifier(ScrollEdgeFade()) }

    /// The pointing-hand cursor over anything clickable.
    func handCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// The head of every page: the title, one subtitle wrapped at about 65 characters, and at
/// most one instrument at the right.
struct PageHeader<Instrument: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var instrument: Instrument

    init(_ title: String, subtitle: String, @ViewBuilder instrument: () -> Instrument = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.instrument = instrument()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.headerGap) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(subtitle)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Space.subtitleMeasure, alignment: .leading)
            }
            Spacer(minLength: 0)
            instrument
        }
        .frame(maxWidth: .infinity)
    }
}

/// Tabs under the header: labels, a 2 px underline under the open one, a rule beneath.
struct TabStrip<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.tabGap) {
                ForEach(tabs, id: \.0) { tab, label in
                    let isOpen = tab == selection
                    Button {
                        withAnimation(DS.Motion.panel) { selection = tab }
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.tabLabelGap) {
                            Text(label)
                                .font(DS.Font.body)
                                .foregroundStyle(isOpen ? DS.Color.ink : DS.Color.inkSecondary)
                            Rectangle()
                                .fill(isOpen ? DS.Color.ink : Color.clear)
                                .frame(height: DS.Material.tabUnderline)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
            CardDivider()
        }
    }
}

// MARK: - Labels

/// A section label: 12, uppercase, tracked, secondary ink. Uppercasing happens here so a
/// label can never be half-styled.
struct Eyebrow: View {
    let text: String
    var color: Color = DS.Color.inkSecondary

    init(_ text: String, color: Color = DS.Color.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(color)
    }
}

/// One caption line under a row's label. Never two.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: DS.Space.measure, alignment: .leading)
    }
}

/// An inline keyboard chip: `Right ⌥`.
struct KeyChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

/// A monospaced-digit readout: timers, counts.
struct Readout: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(large ? DS.Font.readoutLarge : DS.Font.data)
            .foregroundStyle(DS.Color.ink)
    }
}

/// An uppercase word in a thin frame: ACTIVE.
struct TagChip: View {
    let text: String

    var body: some View {
        Eyebrow(text)
            .padding(.horizontal, DS.Space.fieldLabelGap)
            .padding(.vertical, DS.Space.hair)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Brand

/// The app's own icon as a rounded tile with a thin edge (on black, a black icon would vanish).
struct AppIconTile: View {
    var size: CGFloat = DS.Material.logoSize

    private static let artwork: NSImage = Bundle.main.image(forResource: "AppIcon")
        ?? NSApplication.shared.applicationIconImage

    var body: some View {
        let radius = size * DS.Radius.appIconCorner
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.borderStrong, lineWidth: DS.Border.hairline))
            .accessibilityHidden(true)
    }
}

/// The wordmark: the icon tile, then the name as one word, the first part in the Square
/// shape and the second in the Circle shape ("Sigma" + "flow"). A one-part name passes
/// `accent: ""`.
struct Wordmark: View {
    let base: String
    var accent: String = ""

    var body: some View {
        HStack(spacing: DS.Space.wordmarkLogoGap) {
            AppIconTile()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(base).font(DS.Font.wordmark)
                if !accent.isEmpty { Text(accent).font(DS.Font.wordmarkAccent) }
            }
        }
        .foregroundStyle(DS.Color.ink)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(base + accent)
    }
}

// MARK: - Buttons

/// The one button. Three kinds, one height, one font, so any two line up in a row.
///
/// - `secondary`: control fill with a border. The everyday button.
/// - `inverted`: light fill, dark label. At most one per screen, for the action the screen
///   exists for. Many screens have none.
/// - `tertiary`: no fill, secondary ink, fill on hover. Actions inside a row.
///
/// Danger reads through placement, never through colour.
struct AppButton: View {
    enum Kind { case inverted, secondary, tertiary }

    let title: String
    var kind: Kind = .tertiary
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isEnabled = true
    /// Pins the width so a column of buttons lines up across rows.
    var fixedWidth: CGFloat? = nil
    /// The icon faint, the button still live: a switch that is off.
    var iconDimmed = false
    /// Smaller all round, for a floating panel's row of several.
    var compact = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? DS.Control.iconGapCompact : DS.Control.iconGap) {
                if let icon {
                    CarbonIcon(name: icon, size: compact ? DS.Control.iconSizeSmall : DS.Control.iconSize)
                        .opacity(iconDimmed ? DS.Border.disabledOpacity : 1)
                }
                // An icon-only button passes an empty title: no text, no stray gap.
                if !title.isEmpty { Text(title).font(compact ? DS.Font.caption : DS.Font.body) }
                if let trailingIcon {
                    CarbonIcon(name: trailingIcon, size: compact ? DS.Control.iconSizeSmall : DS.Control.iconSize)
                }
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, compact ? DS.Control.padXCompact : kind == .tertiary ? DS.Control.padXQuiet : DS.Control.padX)
            .frame(width: fixedWidth, height: compact ? DS.Control.heightCompact : DS.Control.height)
            .background(fillColor, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(isHovering ? DS.Color.borderStrong : DS.Color.border, lineWidth: DS.Border.hairline)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Border.disabledOpacity)
        .onHover { isHovering = $0 }
        .handCursor()
    }

    private var labelColor: Color {
        switch kind {
        case .inverted: DS.Color.inkOnInverted
        case .secondary: DS.Color.ink
        case .tertiary: isHovering ? DS.Color.ink : DS.Color.inkSecondary
        }
    }

    private var fillColor: Color {
        switch kind {
        case .inverted: isHovering ? DS.Color.gray900 : DS.Color.gray1000
        case .secondary: isHovering ? DS.Color.hoverFill : DS.Color.controlFill
        case .tertiary: isHovering ? DS.Color.hoverFill : .clear
        }
    }
}

/// A Copy button that turns into "Copied" with a tick for `statusHold`, then back. No toast.
struct CopyButton: View {
    let text: String
    var title: String = "Copy"
    var kind: AppButton.Kind = .tertiary

    @State private var didCopy = false

    var body: some View {
        AppButton(title: didCopy ? "Copied" : title, kind: kind, icon: didCopy ? "checkmark" : "copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(DS.Motion.statusHold))
                didCopy = false
            }
        }
    }
}

/// The way in to deleting: faint text with a small bin at the very end of a list, never on a
/// row. Every press goes on to a question.
struct FaintDelete: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: DS.Space.tight + DS.Space.hair) {
                    CarbonIcon(name: "trash-can", size: DS.Control.iconSizeTiny)
                    Text(title).font(DS.Font.micro)
                }
                .foregroundStyle(isHovering ? DS.Color.inkSecondary : DS.Color.dim)
                .opacity(isHovering ? 1 : DS.Material.faintOpacity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .handCursor()
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.roomy)
        .overlay(alignment: .top) { CardDivider() }
    }
}

// MARK: - Cards and rows

/// A section's surface: glass, a 1 px border, radius 8. Rows inside are divided by
/// `CardDivider`s that stop at the card's edge.
struct Card<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .background(DS.Color.glass, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}

/// A card's footer bar: a hint at the left, at most two buttons at the right.
struct CardFooter<Actions: View>: View {
    let hint: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            Text(hint)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            HStack(spacing: DS.Space.snug) { actions }
        }
        .padding(.horizontal, DS.Space.rowPadX)
        .padding(.vertical, DS.Space.rowPadY)
        .background(DS.Color.footer)
        .overlay(alignment: .top) { CardDivider() }
    }
}

/// A 1 px line between rows, inside the card.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(DS.Color.border).frame(height: DS.Border.hairline)
    }
}

/// An eyebrow over its card: one section of a page. (Not `Section`: that is SwiftUI's.)
struct PageSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.eyebrowGap) {
            Eyebrow(title)
            content
        }
    }
}

/// One row in a card: label, optional caption under it, optional data in secondary ink,
/// and the control in a lane at the right edge. 52 high without a caption.
struct CardRow<Control: View>: View {
    let label: String
    var caption: String? = nil
    var data: String? = nil
    var isLast = false
    @ViewBuilder var control: Control

    init(_ label: String, caption: String? = nil, data: String? = nil, isLast: Bool = false,
         @ViewBuilder control: () -> Control = { EmptyView() }) {
        self.label = label
        self.caption = caption
        self.data = data
        self.isLast = isLast
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.roomy) {
                VStack(alignment: .leading, spacing: DS.Space.captionGap) {
                    Text(label)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                    if let caption { Caption(caption) }
                }
                .padding(.vertical, DS.Space.rowPadY)
                Spacer(minLength: 0)
                if let data {
                    Text(data)
                        .font(DS.Font.data)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .textSelection(.enabled)
                }
                control
                    .frame(minWidth: DS.Control.laneMinWidth, alignment: .trailing)
            }
            .padding(.horizontal, DS.Space.rowPadX)
            .frame(minHeight: DS.Material.cardRowHeight)
            if !isLast { CardDivider() }
        }
    }
}

/// A row whose control is a native switch, tinted the one blue.
struct ToggleRow: View {
    let label: String
    var caption: String? = nil
    @Binding var isOn: Bool
    var isEnabled = true
    var isLast = false

    var body: some View {
        CardRow(label, caption: caption, isLast: isLast) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(DS.Color.blue700)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : DS.Border.disabledOpacity)
    }
}

/// The empty body of a list card: a line in ink, a centred caption, at most one button.
struct EmptyCardBody<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    init(_ title: String, detail: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        VStack(spacing: DS.Space.roomy) {
            Text(title)
                .font(DS.Font.reading)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Space.subtitleMeasure)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.emptyPadY)
        .padding(.horizontal, DS.Space.wide)
    }
}

/// The editor at the head of a list card: a shade lighter than the rows.
struct EditorRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.editorGap) {
            content
        }
        .padding(DS.Space.editorPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.editorFill)
    }
}

/// A short uppercase label above the rows of one day inside a list card.
struct DayLabel: View {
    let text: String

    var body: some View {
        Eyebrow(text)
            .padding(.horizontal, DS.Space.rowPadX)
            .padding(.top, DS.Space.dayLabelTop)
            .padding(.bottom, DS.Space.dayLabelBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Fields

/// A single-line input: control fill, border, radius 6, 32 high.
struct FormField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Control.fieldPadX)
            .frame(height: DS.Control.fieldHeight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .onSubmit(onSubmit)
    }
}

/// A multi-line input with the same chrome, never shorter than `fieldMinHeight`.
struct TextArea: View {
    let prompt: String
    @Binding var text: String
    var minHeight: CGFloat = DS.Control.fieldMinHeight
    var maxHeight: CGFloat? = nil

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, DS.Control.fieldPadX - DS.Space.tight)
            .padding(.vertical, DS.Control.fieldPadY)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.placeholder)
                        .padding(.horizontal, DS.Control.fieldPadX)
                        .padding(.vertical, DS.Control.fieldPadY)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// An eyebrow over a field.
struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.fieldLabelGap) {
            Eyebrow(label)
            field
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The search box at the head of a list page: a magnifier, the field, a clear button.
struct SearchBox: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            CarbonIcon(name: "search", size: DS.Control.iconSizeSmall)
                .foregroundStyle(DS.Color.dim)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    CarbonIcon(name: "close", size: DS.Control.iconSizeTiny)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Control.fieldPadX)
        .frame(width: DS.Material.searchWidth, height: DS.Control.fieldHeight)
        .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Choosing

/// The two small chevrons at the right end of a popup.
struct PopupChevrons: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 5, y: 6.5))
            path.addLine(to: CGPoint(x: 8, y: 3.5))
            path.addLine(to: CGPoint(x: 11, y: 6.5))
            path.move(to: CGPoint(x: 5, y: 9.5))
            path.addLine(to: CGPoint(x: 8, y: 12.5))
            path.addLine(to: CGPoint(x: 11, y: 9.5))
        }
        .stroke(DS.Color.dim, style: StrokeStyle(lineWidth: DS.Material.radioStroke, lineCap: .round, lineJoin: .round))
        .frame(width: DS.Control.iconSize, height: DS.Control.iconSize)
    }
}

/// The popup: the current choice in a control-fill button with chevrons, the options in a
/// menu under it. Drawn by the app, not AppKit, so it reads like the rest of the page.
struct PopupButton<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(Selection, String)]
    var width: CGFloat = DS.Control.popupWidth

    private var currentLabel: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: DS.Space.snug) {
                Text(currentLabel)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                PopupChevrons()
            }
            .padding(.leading, DS.Control.padX)
            .padding(.trailing, DS.Control.padXQuiet)
            .frame(width: width, height: DS.Control.height)
            .background(DS.Color.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border, lineWidth: DS.Border.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .handCursor()
    }
}

/// A radio mark for a pick-one list: a ring, and a dot when chosen.
struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? DS.Color.ink : DS.Color.radioOff, lineWidth: DS.Material.radioStroke)
            if isOn {
                Circle()
                    .fill(DS.Color.ink)
                    .frame(width: DS.Material.radioDot, height: DS.Material.radioDot)
            }
        }
        .frame(width: DS.Material.radioSize, height: DS.Material.radioSize)
    }
}

/// A tick box, white with a dark check when on.
struct TickBox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.chip)
            .fill(isOn ? DS.Color.ink : DS.Color.tickFill)
            .overlay {
                if isOn {
                    CarbonIcon(name: "checkmark", size: DS.Material.tickMark)
                        .foregroundStyle(DS.Color.inkOnInverted)
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.tickEdge, lineWidth: DS.Border.hairline)
                }
            }
            .frame(width: DS.Material.tickSize, height: DS.Material.tickSize)
    }
}

// MARK: - Status and instruments

/// The result of an action, where the action was: a green tick and a few words. Replaces
/// toasts. The caller shows it for `DS.Motion.statusHold`.
struct StatusLine: View {
    let text: String
    var icon: String = "checkmark"

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            CarbonIcon(name: icon, size: DS.Control.iconSize - DS.Space.hair)
                .foregroundStyle(DS.Color.live)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(height: DS.Control.height)
    }
}

/// The glyph at the head of a floating panel's status row: a steady dot (live), a hollow
/// ring (paused), or a Carbon mark. Never animated.
struct StatusGlyph: View {
    enum Kind { case dot, paused, busy, done, warning }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .dot:
                Circle().fill(DS.Color.ink)
                    .frame(width: DS.Control.statusDot, height: DS.Control.statusDot)
            case .paused:
                Circle().strokeBorder(DS.Color.inkSecondary, lineWidth: DS.Border.pausedRing)
                    .frame(width: DS.Control.statusDot, height: DS.Control.statusDot)
            case .busy: CarbonIcon(name: "circle-dash", size: DS.Control.statusGlyph)
            case .done: CarbonIcon(name: "checkmark", size: DS.Control.statusGlyph)
            case .warning: CarbonIcon(name: "warning", size: DS.Control.statusGlyph)
            }
        }
        .foregroundStyle(DS.Color.ink)
        .frame(width: DS.Control.statusGlyph, height: DS.Control.statusGlyph)
    }
}

/// A thin progress line with the percentage beside it.
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        let clamped = max(0, min(1, fraction))
        HStack(spacing: DS.Space.navInset) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.Material.progressHeight / 2).fill(DS.Color.gaugeOff)
                RoundedRectangle(cornerRadius: DS.Material.progressHeight / 2)
                    .fill(DS.Color.ink)
                    .frame(width: DS.Material.progressWidth * CGFloat(clamped))
            }
            .frame(width: DS.Material.progressWidth, height: DS.Material.progressHeight)
            Text("\(Int((clamped * 100).rounded()))%")
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.ink)
        }
    }
}

/// A 2 px line along the foot of a floating card that runs down as time passes: full when
/// the time starts, empty when it ends. Ink over the gauge track.
struct TimeLeftLine: View {
    /// 1 at the start, 0 at the end.
    let remaining: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.Color.gaugeOff)
                Rectangle().fill(DS.Color.ink)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, remaining))))
            }
        }
        .frame(height: DS.Border.bar)
    }
}

/// Five blocks with a label.
struct GaugeLine: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: DS.Space.navInset) {
            Text(label.uppercased())
                .font(DS.Font.micro)
                .tracking(DS.Font.microTracking)
                .foregroundStyle(DS.Color.dim)
                .frame(width: DS.Material.gaugeLabelWidth, alignment: .leading)
            HStack(spacing: DS.Material.gaugeBlockGap) {
                ForEach(0..<DS.Material.gaugeBlocks, id: \.self) { index in
                    Rectangle()
                        .fill(index < value ? DS.Color.ink : DS.Color.gaugeOff)
                        .frame(width: DS.Material.gaugeBlockWidth, height: DS.Material.gaugeBlockHeight)
                }
            }
        }
    }
}

/// A level meter: round dots that fill left to right in the one colour, damped so it rises
/// and drains smoothly. The damping lives in a plain reference type on purpose: it advances
/// inside the Canvas closure, and SwiftUI state changed during drawing is undefined behaviour.
struct LevelMeter: View {
    /// 0...1.
    let level: Float
    var isActive: Bool
    var segments = DS.Material.meterSegments

    @State private var movement = Damper()

    private final class Damper {
        var position: Double = 0
    }

    static func naturalWidth(segments: Int = DS.Material.meterSegments) -> CGFloat {
        CGFloat(segments) * (DS.Material.meterDotSize + DS.Material.meterSegmentGap) - DS.Material.meterSegmentGap
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                advance()
                let dot = DS.Material.meterDotSize
                let lit = Int((movement.position * Double(segments)).rounded())
                for index in 0..<segments {
                    let x = CGFloat(index) * (dot + DS.Material.meterSegmentGap)
                    let rect = CGRect(x: x, y: (size.height - dot) / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(index < lit ? DS.Color.live : DS.Color.liveOff))
                }
            }
        }
        .frame(width: Self.naturalWidth(segments: segments), height: DS.Material.meterDotSize * 2)
    }

    private func advance() {
        let target = isActive ? Double(min(max(level, 0), 1)) : 0
        let time = target > movement.position ? DS.Motion.meterAttack : DS.Motion.meterRelease
        let step = 1.0 / 30.0 / time
        let delta = target - movement.position
        movement.position = min(max(movement.position + min(max(delta, -step), step), 0), 1)
    }
}
```

---

## 6. The main window

Use a `Window`, not a `WindowGroup`: the app has one front window, and ⌘N shouldn't make a
second copy. There is no title bar, so the traffic lights float over the sidebar.

```swift
@main
struct AppNameApp: App {
    var body: some Scene {
        Window("AppName", id: "main") {
            MainWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DS.Material.windowWidth, height: DS.Material.windowHeight)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
```

The shell: a 220 pt sidebar on vibrancy with the wordmark, Carbon-iconed pages and the
version at its foot, then the page on the painting. Add a page by adding a `Page` case and
nothing else. Remember the last open page (`@AppStorage`).

```swift
struct MainWindow: View {
    enum Page: String, CaseIterable, Identifiable {
        case today, history, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .today: "Today"; case .history: "History"; case .settings: "Settings" }
        }
        /// IBM Carbon icon names.
        var icon: String {
            switch self { case .today: "timer"; case .history: "text--align--left"; case .settings: "settings" }
        }
    }

    @AppStorage("lastPage") private var lastPage = Page.today.rawValue
    private var page: Page { Page(rawValue: lastPage) ?? .today }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            // The page gets exactly the width beside the sidebar. A page too wide for the
            // window runs off the right instead of shoving the sidebar off the left.
            GeometryReader { geo in
                Group {
                    switch page {
                    case .today: TodayPage()
                    case .history: HistoryPage()
                    case .settings: SettingsPage()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .background { BackgroundImage() }
        .frame(minWidth: DS.Material.windowMinWidth, minHeight: DS.Material.windowMinHeight)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: DS.Material.titleBarClearance)
            Wordmark(base: "Onigiri")
                .padding(.horizontal, DS.Space.wordmarkSide)
                .padding(.top, DS.Space.wordmarkTop)
                .padding(.bottom, DS.Space.wordmarkBottom)
            VStack(spacing: DS.Space.navGap) {
                ForEach(Page.allCases) { navItem($0) }
            }
            .padding(.horizontal, DS.Space.navInset)
            Spacer()
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                .font(DS.Font.data)
                .foregroundStyle(DS.Color.dim)
                .padding(.horizontal, DS.Space.wordmarkSide)
                .padding(.vertical, DS.Space.versionPadY)
        }
        .frame(width: DS.Material.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background { RailGlass(material: .sidebar).overlay(DS.Color.rail) }
        .focusEffectDisabled()
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Color.border).frame(width: DS.Border.hairline)
        }
    }

    private func navItem(_ candidate: Page) -> some View {
        let isActive = page == candidate
        return Button {
            withAnimation(DS.Motion.panel) { lastPage = candidate.rawValue }
        } label: {
            HStack(spacing: DS.Space.navItemGap) {
                CarbonIcon(name: candidate.icon, size: DS.Control.navIconSize)
                    .foregroundStyle(isActive ? DS.Color.ink : DS.Color.inkSecondary)
                Text(candidate.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
            }
            .padding(.horizontal, DS.Space.navItemPadX)
            .frame(height: DS.Material.navRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DS.Color.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}
```

A settings page, as SigmaFlow builds them:

```swift
struct SettingsPage: View {
    enum Tab { case general, sounds }
    @State private var tab = Tab.general
    @AppStorage("startAtLogin") private var startAtLogin = false

    var body: some View {
        PageScroll {
            PageHeader("Settings", subtitle: "How Onigiri counts down and tells you it’s time.")
            TabStrip(tabs: [(.general, "General"), (.sounds, "Sounds")], selection: $tab)
        } content: {
            PageSection("Start") {
                Card {
                    ToggleRow(label: "Open at login", isOn: $startAtLogin)
                    CardRow("Shortcut", isLast: true) { KeyChip(text: "⌃⌥T") }
                }
            }
        }
    }
}
```

A small app with only a widget and a few settings doesn't need the sidebar. Its settings
window is still a `Window` with `.hiddenTitleBar` and the painting behind it, laid out with
`PageScroll`.

---

## 7. Floating panels and widgets

Anything that floats over other apps (an overlay, a widget, a prompt) is an `NSPanel` whose
content view is real glass. Panels share these rules:

- **It never becomes key.** Use `.nonactivatingPanel` and `canBecomeKey == false`. The app
  in front keeps the keyboard, so clicking the widget never steals focus from what the
  person is typing in.
- Use `.statusBar` level and `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, so it
  shows on every Space and over full-screen apps.
- The glass is an `NSVisualEffectView` (`.hudWindow`, behind-window) as the panel's
  **content view**, rounded with `maskImage`. A SwiftUI clip can't round a behind-window
  blur: the corners show as light squares. The `floatingGlass` tint and the `borderStrong`
  1 px edge are drawn in AppKit on that view too.
- Size is `floatingWidth` (440) and the inset is 18 across, 14 down. A narrower widget is
  fine, but its width is a token.
- Placement: something passing (a prompt, a notice) sits centred above the Dock, its bottom
  edge `floatingBottomInset` (96) up, and grows upward. Something that stays (a widget)
  sits in the top-right corner, `floatingCornerInset` (14) in, and can be dragged by its
  status row. Remember where it was left.
- It fades in over 0.16 s and out over 0.3 s. Nothing else moves.
- **The status row grammar:** a `StatusGlyph`, an `Eyebrow` label in ink (REC, PAUSED,
  DONE), a `Readout` timer, an optional `LevelMeter`, a spacer, then compact `AppButton`s.
  No hint text in any state.
- Time running out is a `TimeLeftLine` along the card's foot, and it holds while the pointer
  is on the card.

```swift
/// The card surface for every floating panel: the desktop blurred behind, the tint and 1 px
/// edge over it, cut to the floating radius. The hosting view's ideal size drives the window.
@MainActor
enum GlassCard {
    static func install<Content: View>(_ hosting: NSHostingView<Content>, in panel: NSPanel,
                                       radius: CGFloat = DS.Radius.floating) {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.maskImage = cornerMask(radius: radius)
        panel.contentView = glass

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(DS.Color.floatingGlass).cgColor
        tint.layer?.borderColor = NSColor(DS.Color.borderStrong).cgColor
        tint.layer?.borderWidth = DS.Border.hairline
        tint.layer?.cornerRadius = radius
        tint.layer?.cornerCurve = .circular
        tint.layer?.masksToBounds = true
        tint.frame = glass.bounds
        tint.autoresizingMask = [.width, .height]
        glass.addSubview(tint)

        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            hosting.setContentHuggingPriority(.required, for: axis)
            hosting.setContentCompressionResistancePriority(.required, for: axis)
        }
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    /// A stretchable rounded mask: the corners stay at `radius`, the middle stretches.
    private static func cornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A floating card that takes clicks but never the keyboard.
@MainActor
final class FloatingPanel: NSPanel {
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.Material.floatingWidth, height: DS.Control.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true  // the window server's shadow, shaped to the card
        appearance = NSAppearance(named: .darkAqua)
        GlassCard.install(NSHostingView(rootView: content.environment(\.colorScheme, .dark)), in: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The top-right corner of the screen under the pointer.
    func placeInCorner() {
        layoutIfNeeded()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let inset = DS.Material.floatingCornerInset
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - inset, y: visible.maxY - frame.height - inset))
        invalidateShadow()
    }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = DS.Motion.fadeIn; animator().alphaValue = 1 }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Motion.fadeOut
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.orderOut(nil) }
        }
    }

    /// Called by the status row's drag gesture. Reads the mouse's place on screen, not the
    /// gesture's, because the gesture's own space moves with the window it is moving.
    func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended {
            dragStart = nil
            NSCursor.openHand.set()
            return
        }
        NSCursor.closedHand.set()
        guard let start = dragStart else {
            dragStart = (mouse, frame.origin)
            return
        }
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }
}
```

The view is made before the panel, so it gets a closure that reaches the panel once it
exists:

```swift
@MainActor final class PanelRef { weak var panel: FloatingPanel? }

let ref = PanelRef()
let panel = FloatingPanel(content: TimerCard(onDrag: { ended in ref.panel?.drag(ended: ended) }))
ref.panel = panel
panel.placeInCorner()
panel.present()
```

Inside the card, the draggable part of the status row leaves the buttons out, so they stay
buttons:

```swift
struct TimerCard: View {
    let onDrag: @MainActor (_ ended: Bool) -> Void

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                StatusGlyph(kind: .dot)
                Eyebrow("Focus", color: DS.Color.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onDrag(false) }
                .onEnded { _ in onDrag(true) })
            AppButton(title: "Pause", kind: .secondary, icon: "pause", compact: true) {}
        }
        .padding(.horizontal, DS.Space.floatingPadX)
        .padding(.vertical, DS.Space.floatingPadY)
        .frame(width: DS.Material.floatingWidth)
    }
}
```

Two things that look like bugs:

- `NSCursor.set()` does nothing in an app that isn't in front, and a non-activating panel's
  app usually isn't. SigmaFlow works around this with a private SkyLight switch. Without
  it, everything works but the cursor doesn't change. That is acceptable, so don't chase it.
- SwiftUI's `.onHover` doesn't fire while the app isn't in front. To hold a timer while the
  pointer is on the card, use an `NSTrackingArea` with `.activeAlways` on the hosting view.

A menu bar item, when the app has one, is secondary: a Carbon glyph through
`CarbonIconCache.nsImage(named:size:)` in a `MenuBarExtra`, and a short menu. The glyph is
filled while something is live.

---

## 8. Behaviour

- Esc cancels or closes whatever is open. Return confirms, except in a delete question,
  where Return means Cancel.
- Remember what the person left: the last page, the open tab, where a widget was dragged,
  the window size.
- Something that is counting down or waiting for an answer stops while the pointer is on it.
- A switch that can't act yet is shown at `disabledOpacity` (0.35), with a caption saying
  what turns it on. Never hide it.
- Something that needs a permission asks at the moment it is first needed, not at launch.
- The person's data lives in ordinary files they can open without the app (Markdown, JSON),
  in a folder under their home folder, not in Documents or Desktop, which sync to iCloud.
  A hand edit to those files shows up in the app.
- Nothing is a modal alert except the delete question.
- If the app synthesises a key press, it never sends a key the person didn't ask for.

---

## 9. Words

SigmaFlow is written the way tryvoiceink.com is written.

1. **Say what the person gets, not what the app does inside.** Never name a model, a file
   format or a mechanism.
2. **Two short sentences: you do this, the app does that.** "Speak naturally. SigmaFlow
   writes it for you." The person acts in the first sentence; the app does the work in the
   second.
3. **The app does the work, by name.** "Onigiri keeps time from up here", not "the timer
   is displayed".
4. **Plain, everyday nouns.** "Mail, Slack, Notes, anywhere you type." Never
   "application", "input field", "engine".
5. **Show it, with real-sounding people.** When a feature changes something, show the
   before and after instead of describing it. Use made-up names (Maya, Northwind), never
   real colleagues or customers.
6. **Feature names say what it does for you:** a verb, then the result.
7. **Short, confident, warm.** "It’s yours." No hedging ("may", "should", "try to"), no
   exclamation marks, no jokes.
8. **Privacy is a promise, said once, where it matters.** "Your recordings stay yours."
   Say it on the screen where the person makes that choice, and nowhere else.
9. **Small badges are three or four words.**

And always:

- **No em dashes and no middle dots, anywhere:** UI, comments people see, README,
  mockups. Use a colon, a comma or a full stop instead.
- Use sentence case for titles and buttons ("Start timer", "Open at login"). Uppercase
  comes only from `Eyebrow` and `TagChip`.
- Write contractions with a curly apostrophe: you’re, it’s, don’t, couldn’t.
- App pages stay lean: titles and buttons, plus a line only when the person can act on it.
  No how-it-works lines, no privacy lines, no consent lines. A setup window is the one place
  where a step carries a line or two under its title.

---

## 10. Worked example: a small timer

This shows how the rules apply to a countdown widget. It is an illustration, not a spec.
What the timer actually does is the user's design.

- **The widget** is a `FloatingPanel` in the top-right corner, `DS.Material.timerWidth`
  wide (add the token, say 300), inset 18 by 14. Its row: `StatusGlyph(.dot)` and the
  eyebrow FOCUS in ink, a spacer, then compact buttons Pause (`pause`) and Stop (`stop`),
  both `.secondary`. Under it, the time left in `DS.Font.display` (Pixel 40, monospaced
  digits) in ink, then a `TimeLeftLine` along the foot. While paused, the glyph becomes the
  hollow ring, the eyebrow reads PAUSED, and the digits drop to `inkSecondary`. Nothing
  blinks.
- **When it ends**, the glyph becomes the done tick, the eyebrow reads DONE, and the digits
  read 00:00. The card stays until it is clicked or Esc is pressed. It doesn't flash,
  bounce or turn red. A sound, if there is one, plays once.
- **A character or illustration** (an onigiri, say) is the user's own art. Draw it as white
  line art in `ink` on the glass, with no colour fills, and never as an emoji. If it fills
  as time passes, it fills in `ink` over `gaugeOff`, like the line.
- **Starting it**: a global shortcut shown as a `KeyChip` in Settings, and a `MenuBarExtra`
  with the Carbon `timer` glyph, filled while a timer runs.
- **Settings** is a small `Window` with the painting, `PageScroll`, `PageHeader("Settings",
  subtitle: "How Onigiri counts down and tells you it’s time.")`, and a `Card` of
  `CardRow`s with `PopupButton`s and switches.
- **History**, if there is one: a `ListPage` with `SearchBox`, a `Card` with `DayLabel`s
  and rows inside `CardScroll`, and `FaintDelete` at the very end.

---

## 11. Before you say it is done

Run these from the project root. The first two lines also catch harmless arithmetic, like
`opacity(isOn ? 1 : 0)` or `size * 2`; read each hit, and any other number is a missing
token. The rest should print nothing.

```bash
# Literal numbers and colours in views (tokens only)
grep -rnE "\.(padding|frame|font|opacity|cornerRadius|spacing)\([^)]*[0-9]" Sources --include=*.swift | grep -v DesignSystem.swift
grep -rnE "Color\((red|white|\.sRGB)|Color\.(red|blue|green|orange|yellow|purple|pink|gray)\b|#[0-9A-Fa-f]{6}" Sources --include=*.swift | grep -v DesignSystem.swift
# Weight, system fonts, SF Symbols
grep -rnE "\.bold\(|\.fontWeight|\.italic\(|Font\.system|\.system\(size|Image\(systemName" Sources --include=*.swift
# Em dashes and middle dots (written as bytes so this file carries neither)
grep -rn "$(printf '\342\200\224')\|$(printf '\302\267')" Sources Resources README.md 2>/dev/null
# Exclamation marks in user-facing strings
grep -rnE "\"[^\"]*! ?\"" Sources --include=*.swift
# Every icon the code names exists
for n in $(grep -rhoE 'CarbonIcon\(name: "[^"]+"|icon: "[^"]+"' Sources | sed -E 's/.*"(.*)"/\1/' | sort -u); do
  [ -f "Resources/Icons/$n.svg" ] || echo "missing icon: $n"; done
```

Then:

1. `make install` builds and launches without errors, and the window or panel shows in
   Geist Pixel. If you see San Francisco, the fonts didn't register: check
   `ATSApplicationFontsPath` and that `Contents/Resources/Fonts` exists in the bundle.
2. Look at it. The shell can't record the screen, so add a developer flag that draws each
   window through SwiftUI's `ImageRenderer` into a PNG (SigmaFlow's is `--snapshot-dir DIR
   --pages a,b`), then read the PNGs. Compare against §1. Text fields and switches come out
   as a yellow stand-in in that renderer, and that is expected.
3. Click the widget while typing in another app: the other app must keep the cursor.
4. Read every string on screen against §9.
