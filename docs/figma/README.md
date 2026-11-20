# The Figma file "[ SIGMAFLOW ]"

https://www.figma.com/design/ucHDq8KTA5W3xmG1ssf1mX (team Growth Marketing). Made 20 Oct 2026 from the
code on main (1.0.0, after a143d4c). Every screen, tab, state and flow, as editable layers built from
components and variables. Since that day a change to how SigmaFlow looks or behaves is drawn in this file
first, and the code follows it.

Pages: Read me, Flows (ten journeys), Screens (sections 0 First open to 9 Settings, frames numbered 2.1,
2.2, ... inside each), Overlays (O1 overlay, O2 correction notice, O3 live notes card, O4 call prompt,
O5 menu bar and app menu, O6 Write for me), Foundations, Components, App renders (the app's own
--snapshot-dir renders of 20 Oct, locked, for checking).

On 23 Oct 2026 Write for me was drawn as section 8, after Styles as in the sidebar, and Settings became 9
(its frames 9.1 to 9.17, notes and Flows references renumbered with it). The Sidebar component has a
Write for me item in every variant and a Page=Write for me variant.

On 4 Nov 2026 meeting video was drawn (docs/mockups/meeting-video.html, picks 03 33 12 15 20 22 27 30 31):
Screens 3.25 to 3.28 at the right of the Meetings section (recording with video, the transcript with the
video on the left, a slide as a row, search finding what was on screen) and Overlays O4.5 to O4.7 (the call
card asking With video or Sound only, with its 20 s line and no Not now). Icon/video and Icon/video--off
joined the Icons board after Icon/camera; the camera is live notes' photos, never video.

On 12 Nov 2026 updates were drawn (docs/mockups/app-updates.html, picks 10 + 02; built in 1.1.0). The
sidebar's version text became the component set Version line (Components page, under Sidebar) with
State=Version, Ready ("1.1.0 is ready", Restart) and Restart waiting ("After this"); every Sidebar
variant holds a State=Version instance, so the version reads 1.1.0 everywhere. Overlays gained section
O7 Updates: O7.1 and O7.2 are 2.1 Transcriptions with the line Ready and Restart waiting, O7.3 the
UPDATED notice above the Dock, drawn on O2.5's desktop. components.js still writes the old plain
version text; the file, not the script, is the record.

On 13 Nov 2026 the browser extension was drawn (docs/mockups/browser-extension.html, picks 01 02 07,
and docs/mockups/autowrite-what-it-read.html, 09 without its WHOLE PAGE line; built on 12 and 13 Nov).
Screens 9.18 and 9.19 start a third row in the Settings section: Connections with Your browser under
the connections card, a row per browser with its own icon (Dia connected, Chrome waiting after Add,
Arc not added; then nothing added, the default browser with the inverted Add). Overlays gained
section O8 Browser extension: O8.1 the one-time card above the Dock, O8.2 and O8.3 the toolbar card
on and off for a site, O8.4 Autowrite with the screenshot framed by four corners because the page
was read, O8.5 the toolbar card while SigmaFlow isn't open. The Components page has Icon/earth on the
Icons board, App icon/Dia, App icon/Chrome and App icon/Arc (each browser's real icon, 18 px), and
the component set Browser toolbar card (State=On, Off, Not open), drawn from the extension's own CSS
in Geist with the file's tracking, since scripts can't load Pixel. The Button component's Inverted
kind keeps a swapped icon white; the Add buttons here set theirs to ink/on-inverted by hand. O6 is
still titled Write for me; O8.4 is the Autowrite overlay as built.

On 16 Nov 2026 spelling fixes in the browser were drawn (docs/mockups/browser-autocorrect.html, picks
02 04 06 08). Overlays O8.6, at the right of O8, is the reply box on someone else's page with the faint
dotted line (1.5 px, #8a8a8a) under the word just fixed, the 2 s the extension draws it. Screens 9.18
and 9.19 have Fix my spelling as I type, with its Toggle, as the Your browser card's last row before the
footer, and 9.18's connected Dia row names spelling first. The component set Browser toolbar card has a
Spelling row (On every site in Dia, switch on) under the site row in State=On and State=Off, none in Not
open, and the site row's line reads "Fixes your spelling, learns from your fixes, and Autowrite reads the
page." wherever its switch is on. 08 (a kept word into the Dictionary, tagged LEARNED) is not drawn: the
Dictionary screens have no LEARNED row to follow.

On 16 Nov 2026 the website got a page of its own, Website (100:16698), for a new hero: a black MacBook Right
Command key alone in the first window, which runs a live transcript in the app's own overlay when pressed.
Drawn before any code, for Gokul to agree. W1 is the hero in a browser window: waiting, the browser's
microphone question, Listening, words arriving, Processing, landed, then the phone with a finger on the key.
The overlays are clones of O1's HUD cards, so they match the app. W2 is the key two ways (alone on the page,
or in a cropped close-up of a MacBook deck) and holds the page's local components: Site/Right command key
(Up, Down), Site/Browser bar, Site/Announce, Site/Nav and Site/Mac screen, plus a hidden frame of the uploaded
images (app icon, Dock icons, the painting) whose fills the page reuses. W3 is the whole page at 1440: the
key hero, then today's page below it unchanged. Headlines are Geist with tracking for Pixel, as everywhere in
this file; the key's legends are Inter, because SF Pro lays out at zero width from a script here.

On 19 Nov 2026 the file was brought level with the build of 1.3.1, after the copy audit
(docs/copy-voice.md rules 10 to 14). Every text layer took the new copy by script (Transcriptions is
Dictations, Write for me is Autowrite, Processing is Writing, version 1.3.1), and the frames, sections
and Sidebar variants (Page=Dictations, Page=Autowrite) were renamed with it. Then each area was
compared with the app's own `--snapshot-dir` renders and the code, and redrawn where it differed:
Insights' year heading is a plain sentence (2.10, 2.11); call recordings carry their source,
a phone and the app, on the Meetings list, and every transcript has Ask Claude beside Play, which
reads Pause while playing; Styles' chooser has its two groups and Your own model (7.15 to 7.18);
section 8 is the Autowrite page as built (four steps, Key, AI model, Custom instructions; 8.7 your
own model); Settings' Ask to record calls has its caption and Copy command turns into Copied; the
menu bar's cleanup is one "Clean up what you say" submenu (O5); O6 is the Autowrite overlay with
the pen, the screen picture and the spotlight; the call card asks With video or Sound only (O4.2,
the old Record meeting card, was removed). The App icon tile now carries the real gradient icon, and
Icon/phone joined the Icons board after Icon/pause.
On 20 Nov 2026 (1.3.2) the Today card's sum came back on 2.10 and 2.11, Written with SigmaFlow +
Typed by you = Your words today, and the Version line reads 1.3.2 (its Ready states, 1.4.0).

## Sources here

- `components.js` drew the Components page once: Button, Toggle, Popup, Field, Search box, chips, marks,
  gauges, Level meter, Status line, Faint delete, App icon tile, Wordmark, Traffic lights, Nav item,
  Sidebar (a variant per page), Tab, Page header, Window background. Icons came in as the SVGs in
  Resources/Icons through `upload_assets`, then became 16 px components with the ink variable bound.
- `kit.js` is the screen kit: helpers that draw a window, cards, rows, footers, notes and prototype
  links from those components. It also lives in the file as the hidden, locked text node `__kit__`
  (6:432) on the Components page. Keep the node and this file identical: patch both, compare lengths.
  A script loads it with
  `const kit = await new (Object.getPrototypeOf(async function(){}).constructor)("figma", (await figma.getNodeByIdAsync("6:432")).characters)(figma);`
  after switching to its page. No backticks, backslashes or `${` in kit.js.

Component ids the kit uses are listed at its top (`kit.C`). The Screens page is 6:433, Overlays 3:14,
Components 3:4.

## Things that look wrong and are not

- Text is Geist Regular with extra tracking, not Geist Pixel: scripts can't load Pixel. Pixel Square is
  proportional; Geist at +3.1% (+9.1% eyebrow, +7.1% micro) runs within 1% of its width with the same line
  height, so wrapping matches the app. Geist Mono, the first stand-in, ran 24% wide. Foundations says how
  to switch the styles to the real face in the desktop app.
- Figma's screenshot service can show a stale font inside component instances after a style changes; the
  file data is right.
- Overlay preview cards on Settings are scaled to 80%, which detaches their text from the styles; they
  carry Geist and tracking by hand.
- Sidebar items on every window are prototype links to each area's first screen; a screen can't link to
  itself, so its own area's item has none.
