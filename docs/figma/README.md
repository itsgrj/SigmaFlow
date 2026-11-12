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
