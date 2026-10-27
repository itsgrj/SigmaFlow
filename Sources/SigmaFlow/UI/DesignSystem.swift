import SwiftUI

/// The design system for SigmaFlow 1.0. See docs/DESIGN-SPEC.md; the Paper canvas linked
/// there is the other half of this file.
///
/// Direction, decided 10 October 2026: **Geist as the foundation, a native Mac frame.**
/// Vercel's dark gray scale, verbatim, is the whole palette. The Death of Socrates sits in
/// colour behind translucent surfaces. Geist Pixel is the only text face; Geist Mono carries
/// code-like strings. Dark only. Radius 8 on cards, 6 on controls. Nothing blinks.
///
/// Every colour, size, radius and duration a view needs is a token here. Views must not
/// contain literal values; if a number is missing, add the token.
///
/// Names from the earlier monochrome system are kept below as aliases so the views that
/// have not yet been rebuilt still compile. Each alias says which token it now means; new
/// code uses the new names. The aliases go when the last page is rebuilt.
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
        /// A stronger edge: the focused field, the outlined confirm button.
        static let borderStrong = SwiftUI.Color.white.opacity(0.20)
        /// Control fill: buttons, popups, fields, key chips.
        static let controlFill = SwiftUI.Color.white.opacity(0.06)
        /// Hover on anything clickable, and the selected sidebar row.
        static let hoverFill = SwiftUI.Color.white.opacity(0.08)
        static let selectedFill = SwiftUI.Color.white.opacity(0.10)

        /// Card surface over the painting.
        static let glass = SwiftUI.Color(.sRGB, red: 10/255, green: 10/255, blue: 10/255, opacity: 0.72)
        /// Sidebar and toolbar over the painting (vibrancy in code, this colour as fallback).
        static let rail = SwiftUI.Color.black.opacity(0.55)
        /// The HUD card: real glass, with a blur behind it.
        static let hudGlass = SwiftUI.Color(.sRGB, red: 16/255, green: 16/255, blue: 16/255, opacity: 0.62)
        /// A recessed footer inside a card.
        static let footer = SwiftUI.Color.black.opacity(0.35)
        /// The editor row at the head of a list card, the engine row that is chosen, and
        /// the tile being edited: a shade lighter than the card, not a control.
        static let editorFill = SwiftUI.Color.white.opacity(0.03)
        /// The selected tile on the Styles page.
        static let tileSelectedFill = SwiftUI.Color.white.opacity(0.08)
        /// An unlit gauge block and the track of a progress line.
        static let gaugeOff = SwiftUI.Color.white.opacity(0.14)
        /// The track under the correction notice's bar: quieter than a gauge, since the bar
        /// itself is grey (`dim`), not ink.
        static let noticeTrack = SwiftUI.Color.white.opacity(0.07)
        /// The ring of a radio mark that is not chosen.
        static let radioOff = SwiftUI.Color.white.opacity(0.35)
        /// The thumb of a scroll bar inside a text box.
        static let scrollbar = SwiftUI.Color.white.opacity(0.30)
        /// Behind the character counter when it floats over scrolling text.
        static let counterBackdrop = SwiftUI.Color(.sRGB, red: 22/255, green: 22/255, blue: 22/255, opacity: 0.92)
        /// Laid over the painting so the surfaces read.
        static let paintingScrim = SwiftUI.Color.black.opacity(0.58)
        /// The text box inside an overlay tile, where a preview's words are pasted.
        static let previewField = SwiftUI.Color(.sRGB, red: 20/255, green: 20/255, blue: 20/255, opacity: 0.86)
        /// Over the meetings list while a recording is dragged onto it.
        static let dropVeil = SwiftUI.Color.black.opacity(0.62)
        /// Over the page while the delete question is open, and the question's own card.
        static let questionVeil = SwiftUI.Color.black.opacity(0.55)
        static let questionFill = swatch(0x111111)
        /// The bin on a picture's larger view: a dark square, darker under the pointer.
        static let peekDeleteFill = SwiftUI.Color.black.opacity(0.45)
        static let peekDeleteFillHover = SwiftUI.Color.black.opacity(0.75)
        /// The tick box's edge while it is empty.
        static let tickEdge = SwiftUI.Color.white.opacity(0.45)
        static let tickFill = SwiftUI.Color.black.opacity(0.35)

        // Text
        static let ink = gray1000
        static let inkSecondary = gray900
        static let dim = gray700
        static let placeholder = gray600
        /// Label on the inverted button.
        static let inkOnInverted = bg100

        // The one colour: the live audio meter.
        static let meterGreen = swatch(0x32D74B)
        static let meterOff = SwiftUI.Color.white.opacity(0.18)

        // Insights (docs/mockups/insights.html). The squares use GitHub's own dark greens,
        // empty to most (Gokul, 17 Oct 2026): the second colour in the app, only there.
        static let heatEmpty = swatch(0x161B22)
        static let heatLevels = [swatch(0x0E4429), swatch(0x006D32), swatch(0x26A641), swatch(0x39D353)]
        static let heatEdge = SwiftUI.Color.white.opacity(0.05)
        /// The bookshelf: a plank with a lit top edge, a shadow under it and under each book,
        /// and the shade over a book longer than the user's words (round 6: dark, not gone).
        static let plank = swatch(0x2B2724)
        static let plankEdge = swatch(0x4A433D)
        static let shelfShadow = SwiftUI.Color.black.opacity(0.55)
        static let spineShade = SwiftUI.Color.black.opacity(0.3)
        static let bookAheadShade = SwiftUI.Color.black.opacity(0.62)
        /// The small label that follows the pointer over a square or a book.
        static let tipFill = SwiftUI.Color(.sRGB, red: 8/255, green: 8/255, blue: 8/255, opacity: 0.95)

        /// The first open's keyboard: a blank key, and the frame the keys sit in.
        static let keyFill = SwiftUI.Color.white.opacity(0.07)
        static let keyboardFill = SwiftUI.Color.black.opacity(0.35)
        static let stepDotOff = SwiftUI.Color.white.opacity(0.22)

        // MARK: Aliases from the monochrome system (compile bridge; new code uses the names above)
        static let chassis = bg100
        static let panel = controlFill
        static let panelHighlight = border
        static let panelShade = controlFill
        static let well = controlFill
        static let deck = controlFill
        static let cap = controlFill
        static let seam = border
        static let pane = glass
        static let silkscreen = gray900
        static let inkOnDeck = gray1000
        static let record = gray1000
        static let recordIdle = SwiftUI.Color.white.opacity(0.25)
        static let selection = gray1000
        static let selectionEdge = borderStrong
        static let focusRing = blue700
        static let hover = hoverFill
        static let meterFace = controlFill
        static let meterLamp = meterGreen
        static let meterNeedle = meterOff
        static let meterAmber = gray900
        static let meterRed = gray1000

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
        /// Blur radius behind the HUD card and the sidebar.
        static let blurRadius: CGFloat = 24
        /// The native sidebar column.
        static let sidebarWidth: CGFloat = 220
        /// The main window: the Figma frame is 1160 by 760; it never shrinks below this.
        static let windowWidth: CGFloat = 1160
        static let windowHeight: CGFloat = 760
        static let windowMinWidth: CGFloat = 980
        static let windowMinHeight: CGFloat = 620
        /// The pinned title row of every page.
        static let toolbarHeight: CGFloat = 52
        /// Room for the traffic lights at the top of the sidebar.
        static let titleBarClearance: CGFloat = 52
        /// A sidebar item.
        static let navRowHeight: CGFloat = 38
        /// The search box at the head of a list page.
        static let searchWidth: CGFloat = 360
        /// A single-line field inside the Dictionary editor row, and the Name field of a style.
        static let editorFieldWidth: CGFloat = 300
        /// The narrowest the rename field gets before the page would have to grow.
        static let renameFieldMinWidth: CGFloat = 160
        /// The rename field's width that still leaves room for Press Return to save.
        static let renameFieldWidthBesideHint: CGFloat = 200
        /// The three default-style tiles share one height; the custom tiles another, in
        /// three columns, a fourth style starting a second row.
        static let tileHeightDefault: CGFloat = 334
        static let tileHeightCustom: CGFloat = 200
        static let tileColumns: Int = 3
        /// A custom tile shows at most this many lines of its first instruction.
        static let tileLineLimit: Int = 3
        /// Accuracy and Speed gauges on the Models page: five blocks each.
        static let gaugeBlocks: Int = 5
        static let gaugeBlockWidth: CGFloat = 14
        static let gaugeBlockHeight: CGFloat = 4
        static let gaugeBlockGap: CGFloat = 3
        static let gaugeLabelWidth: CGFloat = 68
        static let gaugeRowGap: CGFloat = 6
        /// The column at the right edge of a model row; every state fits inside it.
        static let actionSlotWidth: CGFloat = 176
        /// The three facts under a model name line up in columns.
        static let factsLanguagesWidth: CGFloat = 180
        static let factsSizeWidth: CGFloat = 90
        /// The download progress line inside the action slot.
        static let progressWidth: CGFloat = 92
        static let progressHeight: CGFloat = 2
        /// The Use button is fixed so the column lines up across rows.
        static let useButtonWidth: CGFloat = 72
        /// A snippet box starts at four lines and grows to about six, then scrolls.
        static let snippetBoxMin: CGFloat = 84
        static let snippetBoxMax: CGFloat = 168
        /// The instructions box of a custom style.
        static let instructionsHeight: CGFloat = 120
        /// The underline under the open tab.
        static let tabUnderline: CGFloat = 2
        /// A radio mark and its dot.
        static let radioSize: CGFloat = 16
        static let radioDot: CGFloat = 8
        static let radioStroke: CGFloat = 1.5
        /// A tile that is selected or being edited carries a heavier edge.
        static let tileSelectedStroke: CGFloat = 1.5
        /// Snippets stop at this many characters.
        static let snippetLimit: Int = 2000
        /// Rows a list shows in an offscreen window snapshot (a developer aid).
        static let snapshotRows: Int = 4
        /// A row inside a card, without a caption.
        static let cardRowHeight: CGFloat = 52
        /// A toggle's track.
        static let toggleWidth: CGFloat = 28
        static let toggleHeight: CGFloat = 16
        /// The HUD card's width.
        static let hudWidth: CGFloat = 440
        /// Live notes (docs/mockups/live-notes.html): a card in the top right corner, this
        /// wide, as tall as the user drags it, this far in from the screen's edges.
        static let notesWidth: CGFloat = 400
        static let notesHeight: CGFloat = 430
        static let notesMinHeight: CGFloat = 160
        static let notesInset: CGFloat = 14
        /// The time beside each line.
        static let notesTimeColumn: CGFloat = 46
        /// The bar along the bottom edge that changes the height.
        static let notesGripHeight: CGFloat = 14
        static let notesGripWidth: CGFloat = 36
        static let notesGripThickness: CGFloat = 3
        /// A Tamil line still being heard: a grey block for every so much speech, in these
        /// widths in turn, until the words land (docs/mockups/live-notes-tamil-wait.html, C).
        /// A camera photo beside its line, and the larger view that opens on hover: one size
        /// for photos and screenshots (Gokul, 16 Oct 2026, 3B), beside the picture by this gap.
        static let photoThumbWidth: CGFloat = 46
        static let photoThumbHeight: CGFloat = 34
        /// A screenshot on a line of its own (6B): larger than a photo, it holds text.
        static let screenThumbWidth: CGFloat = 200
        static let screenThumbHeight: CGFloat = 125
        /// Conversations' photo stacks in the list: three stacks of up to three, each photo
        /// this big, each one behind a step up and to the right; the hovered one rises.
        static let stackPhotoWidth: CGFloat = 30
        static let stackPhotoHeight: CGFloat = 22
        static let stackStep: CGFloat = 4
        static let stackGap: CGFloat = 10
        static let stackLift: CGFloat = 4
        static let stackHoverScale: CGFloat = 1.12
        static let stackCountWidth: CGFloat = 40
        /// Pixels the list's small copies are read at (twice the point size, for Retina).
        static let stackThumbPixels: Int = 96
        /// The app icon beside the wordmark, and the gap between them.
        static let logoSize: CGFloat = 28
        /// The app icon on the card that asks to record a call (docs/mockups/call-card.html, 1H).
        static let callPromptIcon: CGFloat = 38
        static let peekWidth: CGFloat = 256
        static let peekHeight: CGFloat = 160
        static let peekGap: CGFloat = 12
        /// The faint bin in the bottom right corner of the larger view (Gokul, 16 Oct 2026,
        /// docs/mockups/delete-recordings.html round 2, 5), and how faint it rests.
        static let peekDeleteSize: CGFloat = 22
        static let peekDeleteInset: CGFloat = 6
        static let peekDeleteRest: Double = 0.55
        /// Every other delete: faint text at the very end of a list or a transcript.
        static let faintDeleteOpacity: Double = 0.75
        /// The delete question: its width, the picture it shows, and how many names it lists
        /// before "and 3 more".
        static let questionWidth: CGFloat = 360
        static let questionPad: CGFloat = 20
        static let questionThumbWidth: CGFloat = 160
        static let questionThumbHeight: CGFloat = 100
        static let questionNames: Int = 4
        /// Ask Claude (docs/mockups/ask-claude.html, 1B 4C; Figma 3.21 and 3.24): the bar
        /// along the foot of Meetings and Conversations until Claude has SigmaFlow, and the
        /// questions under Ask Claude on a transcript.
        static let askBarHeight: CGFloat = 48
        static let askQuestionsWidth: CGFloat = 380
        /// The tick box beside a row while deleting several.
        static let tickSize: CGFloat = 16
        static let tickMark: CGFloat = 12
        static let notesBlockHeight: CGFloat = 9
        static let notesBlockGap: CGFloat = 6
        static let notesBlockWidths: [CGFloat] = [38, 52, 30, 64, 44, 58, 36, 70, 48]
        /// One block per this much speech: about as many as the Tamil words that replace
        /// them, so the line keeps its height when they land (measured on the 13 Oct meeting).
        static let notesBlockPace: Double = 1.0
        /// Where the HUD's bottom edge sits above the bottom of the screen.
        static let hudBottomInset: CGFloat = 96
        /// The first open (docs/mockups/onboarding.html, round 6): a setup window of its own,
        /// set high enough that the overlay, growing up from `hudBottomInset`, never covers it.
        static let welcomeWidth: CGFloat = 760
        static let welcomeHeight: CGFloat = 482
        /// Room kept clear above the overlay's bottom edge for the overlay itself.
        static let welcomeHUDRoom: CGFloat = 200
        static let welcomeFootHeight: CGFloat = 64
        static let welcomeIcon: CGFloat = 84
        /// The widest a step's contents run: the keyboard and the field.
        static let welcomeContentWidth: CGFloat = 520
        /// Permission and folder rows.
        static let welcomeRowsWidth: CGFloat = 470
        static let welcomeLineMeasure: CGFloat = 600
        static let welcomeFieldHeight: CGFloat = 96
        static let welcomeStepDot: CGFloat = 6
        static let welcomeTapDot: CGFloat = 8
        /// The keyboard on the talking step: four rows of blank keys over a bottom row whose
        /// right command and option keys are drawn, the push-to-talk one outlined.
        static let keyHeight: CGFloat = 16
        static let keyGap: CGFloat = 4
        static let keyRows: [Int] = [14, 14, 13, 12]
        /// The bottom row's keys by width: fn, ⌃, ⌥, ⌘, space, ⌘, ⌥, arrows.
        static let keyBottomRow: [CGFloat] = [1, 1, 1, 1.3, 5.4, 1.3, 1, 3]
        /// The overlay's drawing canvas: taller than any card, clipped by the window to the
        /// card's height (`GlassCard`). The card can grow to this before the words clip.
        static let hudCanvasHeight: CGFloat = 1200
        /// The Overlay row on Settings (docs/mockups/overlay-preview-options.html, A1): two
        /// tiles, each a header over a stage where a small overlay sits above a text box.
        /// The headers share a height so the two stages line up whatever the captions do.
        static let overlayTileHeader: CGFloat = 104
        static let overlayStageHeight: CGFloat = 220
        static let overlayFieldHeight: CGFloat = 78
        /// The overlay inside a tile is the real card drawn smaller; never larger than this.
        static let overlayPreviewScale: CGFloat = 0.8
        /// The words inside a preview card stop growing here and show their last lines.
        static let overlayWordsMaxHeight: CGFloat = 80
        /// The painting behind a stage, softened so the card reads over it.
        static let overlayStageBlur: CGFloat = 3
        /// Autowrite (docs/mockups/write-a-reply.html rounds 2 and 3; Figma 8 and O6):
        /// the words in the overlay stop growing here and keep their newest lines in view.
        static let writeWordsMaxHeight: CGFloat = 240
        /// The screen Autowrite read, drawn small beside the words in the overlay (4-09).
        static let writeThumbWidth: CGFloat = 64
        static let writeThumbHeight: CGFloat = 40
        /// The Autowrite page (docs/mockups/autowrite-page.html round 3): the steps run down
        /// a column of their own on the painting, each number in a ring joined to the next
        /// by a line, never in a card (only what you can change has one).
        static let writeStepsWidth: CGFloat = 340
        static let writeStepNumber: CGFloat = 24
        static let writeStepGap: CGFloat = 24
        /// The custom instructions box is never shorter than this, however small the window.
        static let writeInstructionsMin: CGFloat = 72
        /// Everything but the window being written into, dimmed while Autowrite runs (4-11),
        /// and that window's hole, rounded like a macOS window.
        static let spotlightDim: Double = 0.42
        static let spotlightCorner: CGFloat = 10
        /// A meeting transcript: the time column, the bar over it, and how far lines without
        /// the searched word fall back (docs/mockups/meetings-simple.html, 5D).
        static let transcriptTimeColumn: CGFloat = 96
        static let transcriptBarHeight: CGFloat = 44
        /// A speaker's name field in the speakers row, while it is being renamed.
        static let speakerFieldWidth: CGFloat = 180
        /// While a transcript plays, the line playing is brought to this height in the card
        /// (a third of the way down), and a press that moves less than `clickSlop` points
        /// before it lets go is a click on a line, not a drag across its words.
        static let playingLineAnchor = UnitPoint(x: 0, y: 0.3)
        static let clickSlop: CGFloat = 4
        static let searchFadeOpacity: Double = 0.32
        /// Search's moments under a recording in the list (docs/mockups/picture-search.html,
        /// picked 19 Oct 2026: 01 B, 02 A): set in from the row, a time column, a picture
        /// this big, and at most this much of a picture's words.
        static let momentIndent: CGFloat = 24
        static let momentTimeColumn: CGFloat = 52
        static let momentThumbWidth: CGFloat = 64
        static let momentThumbHeight: CGFloat = 40
        static let momentPadY: CGFloat = 6
        static let momentSnippet: Int = 150
        /// A picture opened from search (03 B): as large as this, over the page.
        static let pictureViewWidth: CGFloat = 720
        static let pictureViewHeight: CGFloat = 450
        /// The standalone ⌘, window, until it is rerouted to the main window.
        static let settingsWindowWidth: CGFloat = 760
        static let settingsWindowHeight: CGFloat = 680
        /// Insights: a year of squares, a column per week with Sunday on top, as big as the
        /// card allows between these sizes; words a day for each shade.
        static let heatWeeks: Int = 53
        static let heatSquareMax: CGFloat = 12
        static let heatSquareMin: CGFloat = 7
        static let heatGap: CGFloat = 3
        static let heatRadius: CGFloat = 2
        static let heatDayLabelWidth: CGFloat = 30
        static let heatMonthRow: CGFloat = 15
        static let heatThresholds: [Int] = [1000, 2000, 3000]
        /// The bookcase (11 B): covers this big, turned this far so the spine shows, a
        /// spine as thick as the book is long, shelves of as many as fit.
        static let bookWidth: CGFloat = 70
        static let bookHeight: CGFloat = 105
        static let bookGap: CGFloat = 34
        static let bookTurn: Double = 24
        static let bookPerspective: CGFloat = 0.6
        static let spineBase: CGFloat = 5.6
        static let spinePerThousandRoot: CGFloat = 0.7
        static let bookLift: CGFloat = 12
        static let bookLiftScale: CGFloat = 1.08
        static let bookShadowHeight: CGFloat = 8
        static let bookShadowBlur: CGFloat = 5
        static let shelfPadX: CGFloat = 24
        static let shelfTop: CGFloat = 22
        static let shelfGap: CGFloat = 20
        static let plankHeight: CGFloat = 16
        static let plankShadowBlur: CGFloat = 11
        static let plankShadowY: CGFloat = 14

        // Level meter: round dots that fill left to right.
        static let meterSegments: Int = 14
        /// The live notes card's meter: shorter, so its row keeps room for the camera and
        /// screen buttons.
        static let notesMeterSegments: Int = 6
        static let meterSegmentGap: CGFloat = 3
        static let meterDotSize: CGFloat = 5
        static let meterZeroPoint: Double = 0.72

        // MARK: Aliases and hardware leftovers (compile bridge; removed with Equipment.swift)
        static let navActiveEdge: CGFloat = 0
        static let glassOpacity: Double = 1.0
        static let fieldGlassOpacity: Double = 1.0
        static let glassEdgeOpacity: Double = 1.0
        static let grainLight: Double = 0
        static let grainDark: Double = 0
        static let grainPitch: CGFloat = 2
        static let grainAngle: Angle = .degrees(0)
        static let screwSize: CGFloat = 8
        static let screwInset: CGFloat = 10
        static let ventSlotWidth: CGFloat = 2
        static let ventSlotHeight: CGFloat = 14
        static let ventSlotGap: CGFloat = 4
        static let ventRadius: CGFloat = 0
        static let lampSize: CGFloat = 7
        static let lampSpecular: Double = 0
        static let lampUnlitOpacity: Double = 0.25
        static let segmentThickness: CGFloat = 3
        static let segmentGap: CGFloat = 1
        static let segmentGhostOpacity: Double = 0.12
        static let meterHotSegments: Int = 0
        static let needleSweep: Angle = .degrees(96)
        static let needleWidth: CGFloat = 1.5
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
        /// A compact button: the live notes card's row holds four of them beside REC, the
        /// timer and the meter, in 400 points (docs/mockups/live-notes.html).
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
        /// A popup in a card row. The sound pickers and the shortcut popup are narrower.
        static let popupWidth: CGFloat = 200
        static let popupWidthSound: CGFloat = 140
        /// The cleanup popup carries "With Apple Intelligence", which 200 cannot hold.
        static let popupWidthWide: CGFloat = 240
        static let popupWidthShortcut: CGFloat = 120
        /// The search icon inside the search box, and the check inside a selected tile.
        static let iconSizeSmall: CGFloat = 14
        static let iconSizeTiny: CGFloat = 12
        /// The control lane at the right edge of a card row is at least this wide.
        static let laneMinWidth: CGFloat = 32
        /// Mark glyphs inside the status row of the HUD.
        static let hudGlyph: CGFloat = 12
        static let hudDot: CGFloat = 8
        /// The dot beside Meetings in the sidebar while a meeting records.
        static let liveDot: CGFloat = 6

        // Aliases (compile bridge)
        static let providerMarkSize: CGFloat = 24
        static let providerCardMinHeight: CGFloat = 144
    }

    // MARK: - Type

    /// Geist Pixel is the only text face. The Square shape is the base; the Circle shape is
    /// a texture accent used in exactly one place, the second half of the wordmark. Geist
    /// Mono carries code-like strings: paths, commands. All three ship in Resources/Fonts
    /// under the OFL and register via ATSApplicationFontsPath.
    ///
    /// Pixel has a single weight, so emphasis reads through ink, never through weight.
    enum Font {
        private static let pixel = "GeistPixel-Square"
        private static let pixelAccent = "GeistPixel-Circle"
        private static let monoFace = "GeistMono-Regular"

        /// The toolbar title.
        static let title = pixelFont(22)
        /// "Sigma" in the sidebar head.
        static let wordmark = pixelFont(28)
        /// "flow" in the sidebar head.
        static let wordmarkAccent = SwiftUI.Font.custom(pixelAccent, size: 28)
        /// Section labels, uppercase at the call site via `Eyebrow`.
        static let eyebrow = pixelFont(12)
        static let eyebrowTracking: CGFloat = 0.72
        /// Rows, controls, buttons.
        static let body = pixelFont(14)
        /// One line under a row, in secondary ink.
        static let caption = pixelFont(13)
        /// File names, counts, timers.
        static let data = pixelFont(13).monospacedDigit()
        /// The words in the HUD and in a transcript row.
        static let transcript = pixelFont(15)
        /// Commands and paths.
        static let mono = SwiftUI.Font.custom(monoFace, size: 12)
        /// The name on a style tile.
        static let tileTitle = pixelFont(20)
        /// Gauge labels on the Models page: uppercase at the call site.
        static let micro = pixelFont(11)
        static let microTracking: CGFloat = 0.44
        /// The character counter in a snippet box.
        static let monoSmall = SwiftUI.Font.custom(monoFace, size: 11)
        /// Insights: the numbers of today's sum, and the one sentence atop a card.
        static let insightNumber = pixelFont(40).monospacedDigit()
        static let insightSentence = pixelFont(18)
        /// Weekday and month labels around the squares, and the hover label.
        static let insightAxis = SwiftUI.Font.custom(monoFace, size: 10)
        static let insightTip = SwiftUI.Font.custom(monoFace, size: 12)

        /// The first open: each step's title, the large wordmark on Welcome, the key drawn
        /// into a title, and the labels on the drawn keyboard.
        static let welcomeTitle = pixelFont(26)
        static let welcomeWordmark = pixelFont(56)
        static let welcomeWordmarkAccent = SwiftUI.Font.custom(pixelAccent, size: 56)
        static let welcomeKey = SwiftUI.Font.custom(monoFace, size: 20)
        static let keyLabel = pixelFont(9)

        // MARK: Aliases (compile bridge)
        static let silkscreen = eyebrow
        static let silkscreenLarge = eyebrow
        static let silkscreenTracking: CGFloat = eyebrowTracking
        static let label = caption
        static let bodyEmphasis = body
        static let rowText = transcript
        static let rowTitle = transcript
        static let rowTitleLarge = pixelFont(16)
        static let helper = caption
        static let counter = data
        static let counterLarge = pixelFont(22).monospacedDigit()

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
        /// Page content: 24 at the top, 28 at the sides and the foot (Gokul, 16 Oct 2026: 40
        /// at the foot read as too much beside the sides).
        static let pageTop: CGFloat = 24
        static let pageSide: CGFloat = 28
        static let pageBottom: CGFloat = pageSide
        /// Between one section (eyebrow plus card) and the next.
        static let sectionGap: CGFloat = 28
        /// Eyebrow to its card.
        static let eyebrowGap: CGFloat = 8
        /// Horizontal inset inside a card row.
        static let rowPadX: CGFloat = 16
        /// Vertical inset inside a card row; the row grows past `cardRowHeight` only for a caption.
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
        /// The wordmark block: 6 above, 20 below, 20 at the sides.
        static let wordmarkTop: CGFloat = 6
        static let wordmarkBottom: CGFloat = 20
        static let wordmarkSide: CGFloat = 20
        /// Between the app icon and the wordmark.
        static let wordmarkLogoGap: CGFloat = 10
        /// The version line at the foot of the sidebar.
        static let versionPadY: CGFloat = 14
        /// Title to subtitle in a page header.
        static let headerGap: CGFloat = 8
        /// The subtitle under a page title wraps at about 65 characters.
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
        /// Eyebrow to the field under it in an editor.
        static let fieldLabelGap: CGFloat = 6
        /// The example box inside a default-style tile.
        static let examplePadX: CGFloat = 12
        static let examplePadY: CGFloat = 10
        /// Captions at other measures: a model's blurb, an engine's blurb, a footer hint,
        /// the caption under the default tiles, the instructions caption.
        static let measureNarrow: CGFloat = 420
        static let measureCaption: CGFloat = 640
        static let measureFooter: CGFloat = 700
        static let measureTiles: CGFloat = 720
        static let measureWide: CGFloat = 800
        /// The empty state inside a card: 48 above and below, 24 at the sides.
        static let emptyPadY: CGFloat = 48
        /// The engine row that carries a key field indents it under the label.
        static let radioIndent: CGFloat = 30
        /// A day label above its rows: 12 above, 8 below.
        static let dayLabelTop: CGFloat = 12
        static let dayLabelBottom: CGFloat = 8
        /// The sound pickers under the Sound row: 4 under the caption, 16 at the sides and foot.
        static let soundPickersTop: CGFloat = 4
        /// The HUD card's inset: 18 across, 14 down. The correction notice uses the same.
        static let hudPadX: CGFloat = 18
        static let hudPadY: CGFloat = 14

        // Aliases (compile bridge)
        static let pagePad: CGFloat = pageSide
        static let rowBleed: CGFloat = 0
        static let rowCompact: CGFloat = 12
        static let rowTall: CGFloat = 24
    }

    // MARK: - Radius

    /// Geist: 6 on controls, 8 on cards. The window and the HUD are a little rounder.
    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 4
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let window: CGFloat = 11
        static let hud: CGFloat = 12
        /// The app icon beside the wordmark.
        static let logo: CGFloat = 7
        static let callPromptIcon: CGFloat = 9
        /// The frame of the first open's drawn keyboard.
        static let keyboard: CGFloat = 10

        // Alias (compile bridge)
        static let panel: CGFloat = card
    }

    // MARK: - Border

    enum Border {
        static let hairline: CGFloat = 1
        /// The hollow dot of a paused recording.
        static let pausedRing: CGFloat = 1.5
        /// Controls that can't act yet.
        static let disabledOpacity: Double = 0.35
        /// The filling bar under the correction notice.
        static let bar: CGFloat = 2

        // Aliases (compile bridge)
        static let seam: CGFloat = 1
        static let bevel: CGFloat = 1
    }

    // MARK: - Elevation

    enum Shadow {
        /// Under the HUD card, the one floating surface. The spec as drawn; the panel's
        /// shadow is the window server's, shaped to the card (`GlassCard`), so no view
        /// applies this directly.
        static let hud = Spec(color: .black.opacity(0.55), radius: 32, x: 0, y: 12)
        static let window = Spec(color: .black.opacity(0.45), radius: 24, x: 0, y: 10)

        // Aliases (compile bridge)
        static let raised = Spec(color: .clear, radius: 0, x: 0, y: 0)
        static let pressed = Spec(color: .clear, radius: 0, x: 0, y: 0)
        static let panel = Spec(color: .clear, radius: 0, x: 0, y: 0)

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
        /// A book on the shelf lifting and turning to face the pointer.
        static let bookLift = Animation.easeOut(duration: 0.35)
        /// A playing transcript scrolling to the next line.
        static let follow = Animation.easeInOut(duration: 0.35)
        /// A press on a line still held: how soon to look again whether it has let go.
        static let clickRecheck: TimeInterval = 0.03
        /// A floating panel arriving and leaving.
        static let fadeIn: TimeInterval = 0.16
        static let fadeOut: TimeInterval = 0.3
        /// How long a status line ("Copied") stays before it fades.
        static let statusHold: TimeInterval = 1.5
        /// How long the call card shows the recording after Record meeting, before it goes.
        static let callConfirmHold: TimeInterval = 3
        /// A photo in a stack rising under the pointer.
        static let stackLift: TimeInterval = 0.18
        /// The correction notice: how long the bar takes to drain, and how long ADDED holds.
        static let noticeWindow: TimeInterval = 3.5
        static let addedHold: TimeInterval = 2.0
        /// Deleting: how long Delete stays dim after the question opens, so the double-click
        /// that opened it can't also answer it; how long Undo is offered (6B); how long a
        /// picture's larger view waits for the pointer to come onto it.
        static let deleteArm: TimeInterval = 0.5
        static let undoHold: TimeInterval = 6
        static let peekLinger: TimeInterval = 0.25
        /// Autowrite: the key counts once held this long with no other key, so Right ⌥ or
        /// Right ⌘ pressed with a letter never opens the mic; how long Copied shows what was
        /// written (O6.3); how long Couldn't write stays (O6.4).
        static let writeArm: TimeInterval = 0.3
        static let writeCopiedHold: TimeInterval = 5
        static let writeFailedHold: TimeInterval = 4
        /// Typing in a search box: the exact words answer at once, meaning after this pause.
        static let searchPause: TimeInterval = 0.25
        /// The first open's tap dots: the first lights for as long as a second tap would still
        /// lock hands free (the controller's double-tap window), redrawn at this pace.
        static let doubleTapWindow: TimeInterval = 0.35
        static let tapDotTick: TimeInterval = 0.05
        /// The overlay growing a line ("Make room", docs/mockups/hud-grow-options.html): the
        /// window glides up on an ease-out, and the first word of the new line waits for most
        /// of the glide before it drifts in.
        static let hudGrow: TimeInterval = 0.26
        static let hudGrowCurve: (Float, Float, Float, Float) = (0.22, 1, 0.36, 1)
        static let hudLineWait: TimeInterval = hudGrow * 0.7
        /// The word entrance: blur into focus while dictating, quicker when the final text lands.
        static let wordFlow: TimeInterval = 0.34
        static let wordFlush: TimeInterval = 0.2
        /// The sample dictation the overlay tiles play until someone holds Hold to talk: the
        /// first word after `demoLead`, one more every `demoWordPace`, release at
        /// `demoRecord`, pasted at `demoProcess`, round again at `demoCycle`.
        static let demoCycle: TimeInterval = 9
        static let demoLead: TimeInterval = 0.5
        static let demoWordPace: TimeInterval = 0.3
        static let demoRecord: TimeInterval = 5.4
        static let demoProcess: TimeInterval = 6.4
        /// Where an offscreen snapshot freezes the sample: mid-sentence, still recording.
        static let demoSnapshotAt: TimeInterval = 4.2
        static let needleAttack: TimeInterval = 0.12
        static let needleRelease: TimeInterval = 0.30

        // Aliases (compile bridge)
        static let lamp = Animation.easeOut(duration: 0.08)
        static let needleOvershoot: Double = 0
    }

    // MARK: - Brand

    /// The wordmark is drawn by `Wordmark` in Equipment.swift: "Sigma" in the Square shape,
    /// "flow" in the Circle shape, one word, 28 px. The product is written SigmaFlow in
    /// prose. This string is kept only until the sidebar is rebuilt.
    static let wordmark = "Sigmaflow"
}
