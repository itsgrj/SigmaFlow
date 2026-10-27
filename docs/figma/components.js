// Builds the Components page of the Figma file "[ SIGMAFLOW ]" (ucHDq8KTA5W3xmG1ssf1mX).
// Run once through the Figma MCP use_figma tool. Every value comes from DS in
// Sources/SigmaFlow/UI/DesignSystem.swift; every component mirrors a view in UI/Equipment.swift
// or UI/MainWindow.swift, named in its description.

const page = await figma.getNodeByIdAsync("3:4");
await figma.setCurrentPageAsync(page);
await figma.loadFontAsync({family: "Geist Mono", style: "Regular"});
await figma.loadFontAsync({family: "Geist Mono", style: "Light"});

const vars = await figma.variables.getLocalVariablesAsync();
const V = n => { const v = vars.find(x => x.name === n); if (!v) throw new Error("no variable " + n); return v; };
const paint = n => figma.variables.setBoundVariableForPaint({type: "SOLID", color: {r: 1, g: 1, b: 1}}, "color", V(n));
const tstyles = await figma.getLocalTextStylesAsync();
const S = n => { const s = tstyles.find(x => x.name === n); if (!s) throw new Error("no style " + n); return s; };
const ICON = n => page.findOne(c => c.type === "COMPONENT" && c.name === "Icon/" + n);
const BG_HASH = "91810ecfd86b11542cb560bc15d1dd494608b7c3";
const ICON_HASH = "daaae7de662a4805746835f28961c35fe7a1bcda";

async function text(str, style, color) {
  const t = figma.createText();
  await t.setTextStyleIdAsync(S(style).id);
  t.characters = str;
  t.fills = [paint(color || "ink/primary")];
  return t;
}
function al(dir, o) {
  o = o || {};
  const f = figma.createAutoLayout(dir);
  f.name = o.name || "stack";
  f.itemSpacing = o.gap || 0;
  const p = o.pad || [0, 0, 0, 0];
  f.paddingTop = p[0]; f.paddingRight = p[1]; f.paddingBottom = p[2]; f.paddingLeft = p[3];
  f.fills = o.fill ? [paint(o.fill)] : [];
  if (o.stroke) { f.strokes = [paint(o.stroke)]; f.strokeWeight = 1; f.strokeAlign = "INSIDE"; }
  if (o.radius) f.cornerRadius = o.radius;
  f.counterAxisAlignItems = o.cross || "CENTER";
  if (o.main) f.primaryAxisAlignItems = o.main;
  return f;
}
function icon(n, size, color) {
  const i = ICON(n).createInstance();
  i.resize(size, size);
  i.findOne(c => c.name === "shape").fills = [paint(color || "ink/primary")];
  return i;
}
function place(node, x, y) { node.x = x; node.y = y; return node; }
const made = {};
function section(title, y, h) {
  const s = figma.createSection(); s.name = title; s.x = 0; s.y = y; s.resizeWithoutConstraints(1600, h);
  made[title] = s.id; return s;
}

// ---------- Button (AppButton) ----------
const btnVariants = [];
for (const size of ["Regular", "Compact"]) for (const kind of ["Inverted", "Secondary", "Tertiary"]) for (const state of ["Default", "Hover", "Disabled"]) {
  const compact = size === "Compact";
  const hover = state === "Hover";
  const c = figma.createComponent();
  c.name = "Kind=" + kind + ", State=" + state + ", Size=" + size;
  c.layoutMode = "HORIZONTAL"; c.primaryAxisSizingMode = "AUTO"; c.counterAxisSizingMode = "FIXED";
  c.resize(80, compact ? 26 : 32);
  c.itemSpacing = compact ? 6 : 8; c.counterAxisAlignItems = "CENTER"; c.primaryAxisAlignItems = "CENTER";
  const px = compact ? 8 : (kind === "Tertiary" ? 10 : 12);
  c.paddingLeft = c.paddingRight = px;
  c.cornerRadius = 6;
  const fill = kind === "Inverted" ? (hover ? "geist/gray-900" : "geist/gray-1000") : kind === "Secondary" ? (hover ? "fill/hover" : "fill/control") : (hover ? "fill/hover" : null);
  c.fills = fill ? [paint(fill)] : [];
  if (kind === "Secondary") { c.strokes = [paint(hover ? "edge/border-strong" : "edge/border")]; c.strokeWeight = 1; c.strokeAlign = "INSIDE"; }
  const ink = kind === "Inverted" ? "ink/on-inverted" : kind === "Secondary" ? "ink/primary" : (hover ? "ink/primary" : "ink/secondary");
  const lead = icon("add", compact ? 14 : 16, ink); lead.name = "Icon";
  const label = await text("Button", compact ? "Pixel/Caption 13" : "Pixel/Body 14", ink); label.name = "Label";
  const trail = icon("arrow--right", compact ? 14 : 16, ink); trail.name = "Trailing icon";
  c.appendChild(lead); c.appendChild(label); c.appendChild(trail);
  if (state === "Disabled") c.opacity = 0.35;
  btnVariants.push(c);
}
const buttons = figma.combineAsVariants(btnVariants, page);
buttons.name = "Button";
buttons.description = "AppButton (UI/Equipment.swift). Three tiers, one height: Inverted for the one action a page exists for, Secondary the everyday button, Tertiary actions inside a row. Danger reads through placement, never colour. Compact (26 high) only on the live notes card.";
const pLabel = buttons.addComponentProperty("Label", "TEXT", "Button");
const pIcon = buttons.addComponentProperty("Show icon", "BOOLEAN", true);
const pIconSwap = buttons.addComponentProperty("Icon", "INSTANCE_SWAP", ICON("add").id);
const pTrail = buttons.addComponentProperty("Show trailing icon", "BOOLEAN", false);
const pTrailSwap = buttons.addComponentProperty("Trailing icon", "INSTANCE_SWAP", ICON("arrow--right").id);
for (const v of buttons.children) {
  v.findOne(n => n.name === "Label").componentPropertyReferences = {characters: pLabel};
  v.findOne(n => n.name === "Icon").componentPropertyReferences = {visible: pIcon, mainComponent: pIconSwap};
  v.findOne(n => n.name === "Trailing icon").componentPropertyReferences = {visible: pTrail, mainComponent: pTrailSwap};
}
// combineAsVariants leaves each variant FIXED at its resize width; a button hugs its label.
for (const v of buttons.children) v.primaryAxisSizingMode = "AUTO";
buttons.layoutMode = "HORIZONTAL"; buttons.layoutWrap = "WRAP"; buttons.itemSpacing = 16; buttons.counterAxisSpacing = 16;
buttons.paddingLeft = buttons.paddingRight = buttons.paddingTop = buttons.paddingBottom = 24;
buttons.primaryAxisSizingMode = "FIXED"; buttons.resize(760, 100); buttons.counterAxisSizingMode = "AUTO";
buttons.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made.Button = buttons.id;

// ---------- Toggle (native small switch, tinted blue-700) ----------
const togs = [];
for (const on of [true, false]) for (const en of [true, false]) {
  const c = figma.createComponent();
  c.name = "On=" + (on ? "Yes" : "No") + ", Enabled=" + (en ? "Yes" : "No");
  c.resize(28, 16); c.cornerRadius = 8; c.fills = [paint(on ? "geist/blue-700" : "fill/gauge-off")];
  const k = figma.createEllipse(); k.resize(14, 14); k.fills = [{type: "SOLID", color: {r: 1, g: 1, b: 1}}];
  k.effects = [{type: "DROP_SHADOW", color: {r: 0, g: 0, b: 0, a: 0.3}, offset: {x: 0, y: 1}, radius: 2, spread: 0, visible: true, blendMode: "NORMAL"}];
  c.appendChild(k); k.x = on ? 13 : 1; k.y = 1; k.name = "knob";
  if (!en) c.opacity = 0.35;
  togs.push(c);
}
const toggle = figma.combineAsVariants(togs, page); toggle.name = "Toggle";
toggle.description = "The native switch in ToggleRow: .toggleStyle(.switch), .controlSize(.small), tinted DS.Color.blue700. 28 by 16.";
toggle.layoutMode = "HORIZONTAL"; toggle.itemSpacing = 16; toggle.paddingLeft = toggle.paddingRight = toggle.paddingTop = toggle.paddingBottom = 16;
toggle.primaryAxisSizingMode = "AUTO"; toggle.counterAxisSizingMode = "AUTO"; toggle.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made.Toggle = toggle.id;

// ---------- Popup chevrons and Popup (PopupButton) ----------
const chevSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M5 6.5 L8 3.5 L11 6.5 M5 9.5 L8 12.5 L11 9.5" fill="none" stroke="#8F8F8F" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const chev = figma.createComponent(); chev.name = "Popup chevrons"; chev.resize(16, 16); chev.fills = [];
const chevNode = figma.createNodeFromSvg(chevSvg); chev.appendChild(chevNode); chevNode.x = 0; chevNode.y = 0;
chevNode.findAll(n => n.type === "VECTOR").forEach(v => { v.strokes = [paint("ink/dim")]; });
chev.description = "PopupChevrons: two small chevrons, 1.5 stroke, dim ink.";
const popup = figma.createComponent(); popup.name = "Popup";
popup.layoutMode = "HORIZONTAL"; popup.primaryAxisSizingMode = "FIXED"; popup.counterAxisSizingMode = "FIXED"; popup.resize(200, 32);
popup.primaryAxisAlignItems = "SPACE_BETWEEN"; popup.counterAxisAlignItems = "CENTER"; popup.paddingLeft = 12; popup.paddingRight = 10; popup.itemSpacing = 8;
popup.cornerRadius = 6; popup.fills = [paint("fill/control")]; popup.strokes = [paint("edge/border")]; popup.strokeWeight = 1; popup.strokeAlign = "INSIDE";
const popLabel = await text("Right ⌘", "Pixel/Body 14"); popLabel.name = "Value"; popup.appendChild(popLabel);
popup.appendChild(chev.createInstance());
const pPop = popup.addComponentProperty("Value", "TEXT", "Right ⌘"); popLabel.componentPropertyReferences = {characters: pPop};
popup.description = "PopupButton: the current choice with chevrons; a menu with a check against the chosen one opens under it. 200 wide; 140 for sounds, 240 for cleanup, 120 for a shortcut. Resize the instance.";
made.Popup = popup.id;

// ---------- Fields ----------
function fieldFrame(c, h) {
  c.layoutMode = "HORIZONTAL"; c.primaryAxisSizingMode = "FIXED"; c.counterAxisSizingMode = "FIXED"; c.resize(300, h);
  c.counterAxisAlignItems = "CENTER"; c.paddingLeft = c.paddingRight = 12; c.itemSpacing = 8;
  c.cornerRadius = 6; c.fills = [paint("fill/control")]; c.strokes = [paint("edge/border")]; c.strokeWeight = 1; c.strokeAlign = "INSIDE";
}
const fieldVars = [];
for (const st of ["Empty", "Filled"]) {
  const c = figma.createComponent(); c.name = "State=" + st; fieldFrame(c, 32);
  const t = await text(st === "Empty" ? "Name" : "Weekly sync", "Pixel/Body 14", st === "Empty" ? "ink/placeholder" : "ink/primary");
  t.name = "Text"; c.appendChild(t); t.layoutGrow = 1; t.textAutoResize = "HEIGHT";
  fieldVars.push(c);
}
const field = figma.combineAsVariants(fieldVars, page); field.name = "Field";
const pField = field.addComponentProperty("Text", "TEXT", "Name");
field.children.forEach(v => v.findOne(n => n.name === "Text").componentPropertyReferences = {characters: pField});
field.description = "FormField and SecureFormField: one line, control fill, border, radius 6, 32 high. Empty shows the prompt in placeholder ink.";
field.layoutMode = "VERTICAL"; field.itemSpacing = 12; field.paddingLeft = field.paddingRight = field.paddingTop = field.paddingBottom = 16;
field.primaryAxisSizingMode = "AUTO"; field.counterAxisSizingMode = "AUTO"; field.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made.Field = field.id;

const searchVars = [];
for (const st of ["Empty", "Filled"]) {
  const c = figma.createComponent(); c.name = "State=" + st; fieldFrame(c, 32); c.resize(360, 32);
  c.appendChild(icon("search", 14, "ink/dim"));
  const t = await text(st === "Empty" ? "Search transcriptions" : "budget", "Pixel/Body 14", st === "Empty" ? "ink/placeholder" : "ink/primary");
  t.name = "Text"; c.appendChild(t); t.layoutGrow = 1; t.textAutoResize = "HEIGHT";
  if (st === "Filled") { const x = icon("close", 12, "ink/secondary"); x.name = "Clear"; c.appendChild(x); }
  searchVars.push(c);
}
const search = figma.combineAsVariants(searchVars, page); search.name = "Search box";
const pSearch = search.addComponentProperty("Text", "TEXT", "Search transcriptions");
search.children.forEach(v => v.findOne(n => n.name === "Text").componentPropertyReferences = {characters: pSearch});
search.description = "SearchBox: magnifier, field, a clear cross once something is typed. 360 wide. Exact words answer at once, meaning after DS.Motion.searchPause (0.25 s).";
search.layoutMode = "VERTICAL"; search.itemSpacing = 12; search.paddingLeft = search.paddingRight = search.paddingTop = search.paddingBottom = 16;
search.primaryAxisSizingMode = "AUTO"; search.counterAxisSizingMode = "AUTO"; search.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Search box"] = search.id;

// ---------- Chips and marks ----------
const key = figma.createComponent(); key.name = "Key chip";
key.layoutMode = "HORIZONTAL"; key.primaryAxisSizingMode = "AUTO"; key.counterAxisSizingMode = "AUTO";
key.paddingLeft = key.paddingRight = 8; key.paddingTop = key.paddingBottom = 2; key.cornerRadius = 4;
key.fills = [paint("fill/control")]; key.strokes = [paint("edge/border")]; key.strokeWeight = 1; key.strokeAlign = "INSIDE";
const keyT = await text("Right ⌘", "Mono/Mono 12"); keyT.name = "Key"; key.appendChild(keyT);
keyT.componentPropertyReferences = {characters: key.addComponentProperty("Key", "TEXT", "Right ⌘")};
key.description = "KeyChip: an inline keyboard key, Geist Mono 12.";
made["Key chip"] = key.id;

const tag = figma.createComponent(); tag.name = "Tag chip";
tag.layoutMode = "HORIZONTAL"; tag.primaryAxisSizingMode = "AUTO"; tag.counterAxisSizingMode = "AUTO";
tag.paddingLeft = tag.paddingRight = 6; tag.paddingTop = tag.paddingBottom = 2; tag.cornerRadius = 4; tag.fills = [];
tag.strokes = [paint("edge/border")]; tag.strokeWeight = 1; tag.strokeAlign = "INSIDE";
const tagT = await text("Active", "Pixel/Eyebrow 12", "ink/secondary"); tagT.name = "Tag"; tag.appendChild(tagT);
tagT.componentPropertyReferences = {characters: tag.addComponentProperty("Tag", "TEXT", "Active")};
tag.description = "TagChip: an uppercase word in a thin frame (ACTIVE on Models).";
made["Tag chip"] = tag.id;

const radios = [];
for (const on of [true, false]) {
  const c = figma.createComponent(); c.name = "On=" + (on ? "Yes" : "No"); c.resize(16, 16); c.fills = [];
  const ring = figma.createEllipse(); ring.resize(16, 16); ring.fills = []; ring.strokes = [paint(on ? "ink/primary" : "fill/radio-off")]; ring.strokeWeight = 1.5; ring.strokeAlign = "INSIDE";
  c.appendChild(ring);
  if (on) { const d = figma.createEllipse(); d.resize(8, 8); d.fills = [paint("ink/primary")]; c.appendChild(d); d.x = 4; d.y = 4; }
  radios.push(c);
}
const radio = figma.combineAsVariants(radios, page); radio.name = "Radio mark";
radio.description = "RadioMark: a 16 ring, 1.5 stroke, an 8 dot when chosen.";
radio.layoutMode = "HORIZONTAL"; radio.itemSpacing = 16; radio.paddingLeft = radio.paddingRight = radio.paddingTop = radio.paddingBottom = 16;
radio.primaryAxisSizingMode = "AUTO"; radio.counterAxisSizingMode = "AUTO"; radio.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Radio mark"] = radio.id;

const ticks = [];
for (const on of [true, false]) {
  const c = figma.createComponent(); c.name = "On=" + (on ? "Yes" : "No"); c.resize(16, 16); c.cornerRadius = 4;
  c.fills = [paint(on ? "ink/primary" : "fill/tick")];
  if (on) { const m = icon("checkmark", 12, "ink/on-inverted"); c.appendChild(m); m.x = 2; m.y = 2; }
  else { c.strokes = [paint("edge/tick")]; c.strokeWeight = 1; c.strokeAlign = "INSIDE"; }
  ticks.push(c);
}
const tick = figma.combineAsVariants(ticks, page); tick.name = "Tick box";
tick.description = "TickBox: beside a row while deleting several. White with a dark check when on.";
tick.layoutMode = "HORIZONTAL"; tick.itemSpacing = 16; tick.paddingLeft = tick.paddingRight = tick.paddingTop = tick.paddingBottom = 16;
tick.primaryAxisSizingMode = "AUTO"; tick.counterAxisSizingMode = "AUTO"; tick.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Tick box"] = tick.id;

// ---------- Gauge line, progress line, meter, status ----------
const gauges = [];
for (let v = 0; v <= 5; v++) {
  const c = figma.createComponent(); c.name = "Value=" + v;
  c.layoutMode = "HORIZONTAL"; c.primaryAxisSizingMode = "AUTO"; c.counterAxisSizingMode = "AUTO"; c.itemSpacing = 10; c.counterAxisAlignItems = "CENTER"; c.fills = [];
  const l = await text("Accuracy", "Pixel/Micro 11", "ink/dim"); l.textCase = "UPPER"; l.name = "Label";
  l.textAutoResize = "HEIGHT"; l.resize(68, l.height); c.appendChild(l);
  const blocks = al("HORIZONTAL", {gap: 3, name: "blocks"});
  for (let i = 0; i < 5; i++) { const r = figma.createRectangle(); r.resize(14, 4); r.fills = [paint(i < v ? "ink/primary" : "fill/gauge-off")]; blocks.appendChild(r); }
  c.appendChild(blocks); gauges.push(c);
}
const gauge = figma.combineAsVariants(gauges, page); gauge.name = "Gauge line";
const pG = gauge.addComponentProperty("Label", "TEXT", "Accuracy");
gauge.children.forEach(v => v.findOne(n => n.name === "Label").componentPropertyReferences = {characters: pG});
gauge.description = "GaugeLine: Accuracy and Speed on a model row. Five 14 by 4 blocks, 3 apart.";
gauge.layoutMode = "VERTICAL"; gauge.itemSpacing = 8; gauge.paddingLeft = gauge.paddingRight = gauge.paddingTop = gauge.paddingBottom = 16;
gauge.primaryAxisSizingMode = "AUTO"; gauge.counterAxisSizingMode = "AUTO"; gauge.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Gauge line"] = gauge.id;

const prog = figma.createComponent(); prog.name = "Progress line";
prog.layoutMode = "HORIZONTAL"; prog.primaryAxisSizingMode = "AUTO"; prog.counterAxisSizingMode = "AUTO"; prog.itemSpacing = 10; prog.counterAxisAlignItems = "CENTER"; prog.fills = [];
const track = figma.createFrame(); track.name = "track"; track.resize(92, 2); track.cornerRadius = 1; track.fills = [paint("fill/gauge-off")];
const bar = figma.createRectangle(); bar.name = "fill"; bar.resize(37, 2); bar.cornerRadius = 1; bar.fills = [paint("ink/primary")]; track.appendChild(bar);
prog.appendChild(track);
const pct = await text("40%", "Pixel/Data 13"); pct.name = "Percent"; prog.appendChild(pct);
pct.componentPropertyReferences = {characters: prog.addComponentProperty("Percent", "TEXT", "40%")};
prog.description = "ProgressLine: 92 by 2 with the percentage beside it. Resize the fill to the fraction.";
made["Progress line"] = prog.id;

const meters = [];
for (const seg of [14, 6]) for (const lit of (seg === 14 ? [0, 5, 9, 12] : [0, 3, 5])) {
  const c = figma.createComponent(); c.name = "Dots=" + seg + ", Lit=" + lit;
  c.layoutMode = "HORIZONTAL"; c.primaryAxisSizingMode = "AUTO"; c.counterAxisSizingMode = "AUTO"; c.itemSpacing = 3; c.fills = [];
  for (let i = 0; i < seg; i++) { const d = figma.createEllipse(); d.resize(5, 5); d.fills = [paint(i < lit ? "meter/green" : "fill/meter-off")]; c.appendChild(d); }
  meters.push(c);
}
const meter = figma.combineAsVariants(meters, page); meter.name = "Level meter";
meter.description = "VUMeter: round 5 px dots, 3 apart, filling left to right in system green, the one colour in the app. 14 dots in the overlay, 6 on the live notes card. Rises in 0.12 s, drains in 0.30 s.";
meter.layoutMode = "VERTICAL"; meter.itemSpacing = 12; meter.paddingLeft = meter.paddingRight = meter.paddingTop = meter.paddingBottom = 16;
meter.primaryAxisSizingMode = "AUTO"; meter.counterAxisSizingMode = "AUTO"; meter.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Level meter"] = meter.id;

const status = figma.createComponent(); status.name = "Status line";
status.layoutMode = "HORIZONTAL"; status.primaryAxisSizingMode = "AUTO"; status.counterAxisSizingMode = "FIXED"; status.resize(100, 32);
status.itemSpacing = 8; status.counterAxisAlignItems = "CENTER"; status.fills = [];
status.appendChild(icon("checkmark", 14, "meter/green"));
const stT = await text("Copied", "Pixel/Caption 13", "ink/secondary"); stT.name = "Text"; status.appendChild(stT);
stT.componentPropertyReferences = {characters: status.addComponentProperty("Text", "TEXT", "Copied")};
status.description = "StatusLine: the result of an action where the action was, held 1.5 s (DS.Motion.statusHold). Replaces toasts, always.";
made["Status line"] = status.id;

const faint = figma.createComponent(); faint.name = "Faint delete";
faint.layoutMode = "HORIZONTAL"; faint.primaryAxisSizingMode = "FIXED"; faint.counterAxisSizingMode = "AUTO"; faint.resize(600, 40);
faint.primaryAxisAlignItems = "MAX"; faint.counterAxisAlignItems = "CENTER"; faint.paddingLeft = faint.paddingRight = 16; faint.paddingTop = faint.paddingBottom = 16; faint.fills = [];
faint.strokes = [paint("edge/border")]; faint.strokeTopWeight = 1; faint.strokeBottomWeight = 0; faint.strokeLeftWeight = 0; faint.strokeRightWeight = 0; faint.strokeAlign = "INSIDE";
const fg = al("HORIZONTAL", {gap: 6, name: "button"}); fg.opacity = 0.75;
fg.appendChild(icon("trash-can", 12, "ink/dim"));
const fT = await text("Delete transcriptions", "Pixel/Micro 11", "ink/dim"); fT.name = "Title"; fg.appendChild(fT);
faint.appendChild(fg);
fT.componentPropertyReferences = {characters: faint.addComponentProperty("Title", "TEXT", "Delete transcriptions")};
faint.description = "FaintDelete: the way in to deleting, faint text at the very end of a list or transcript, in the card's fixed footer, never on a row. Every press goes to the delete question. Hover: secondary ink, full opacity.";
made["Faint delete"] = faint.id;

// ---------- App icon tile, wordmark, traffic lights ----------
const tile = figma.createComponent(); tile.name = "App icon tile"; tile.resize(28, 28); tile.cornerRadius = 7; tile.clipsContent = true;
tile.fills = [{type: "IMAGE", imageHash: ICON_HASH, scaleMode: "FILL"}];
tile.strokes = [paint("edge/border-strong")]; tile.strokeWeight = 1; tile.strokeAlign = "INSIDE";
tile.description = "AppIconTile: the app icon as a rounded tile with a thin edge, 28 beside the wordmark (radius 7), 38 on the call card (radius 9), 84 on Welcome.";
made["App icon tile"] = tile.id;

const wm = figma.createComponent(); wm.name = "Wordmark";
wm.layoutMode = "HORIZONTAL"; wm.primaryAxisSizingMode = "AUTO"; wm.counterAxisSizingMode = "AUTO"; wm.itemSpacing = 10; wm.counterAxisAlignItems = "CENTER"; wm.fills = [];
wm.appendChild(tile.createInstance());
const word = al("HORIZONTAL", {name: "word", cross: "BASELINE"});
word.appendChild(await text("Sigma", "Pixel/Wordmark 28"));
word.appendChild(await text("flow", "Pixel/Wordmark accent 28"));
wm.appendChild(word);
wm.description = "Wordmark: the app icon, then Sigma in Geist Pixel Square and flow in Geist Pixel Circle, 28. Written SigmaFlow in prose.";
made.Wordmark = wm.id;

const lights = figma.createComponent(); lights.name = "Traffic lights";
lights.layoutMode = "HORIZONTAL"; lights.primaryAxisSizingMode = "AUTO"; lights.counterAxisSizingMode = "AUTO"; lights.itemSpacing = 8; lights.fills = [];
for (const c of [[1, 0.373, 0.341], [0.996, 0.737, 0.18], [0.157, 0.784, 0.251]]) {
  const e = figma.createEllipse(); e.resize(12, 12); e.fills = [{type: "SOLID", color: {r: c[0], g: c[1], b: c[2]}}];
  e.strokes = [{type: "SOLID", color: {r: 0, g: 0, b: 0}, opacity: 0.15}]; e.strokeWeight = 0.5; lights.appendChild(e);
}
lights.description = "The window's close, minimise and zoom, drawn by macOS in the sidebar's title-bar clearance (52). Not in app snapshots.";
made["Traffic lights"] = lights.id;

// ---------- Nav item and Sidebar ----------
const SECTIONS = [["Models", "chip"], ["Transcriptions", "text--align--left"], ["Meetings", "microphone"], ["Conversations", "notebook"], ["Dictionary", "book"], ["Snippets", "text--short-paragraph"], ["Styles", "magic-wand"], ["Settings", "settings"]];
const navVars = [];
for (const st of ["Default", "Selected"]) {
  const c = figma.createComponent(); c.name = "State=" + st;
  c.layoutMode = "HORIZONTAL"; c.primaryAxisSizingMode = "FIXED"; c.counterAxisSizingMode = "FIXED"; c.resize(200, 38);
  c.itemSpacing = 12; c.counterAxisAlignItems = "CENTER"; c.paddingLeft = c.paddingRight = 12; c.cornerRadius = 6;
  c.fills = st === "Selected" ? [paint("fill/selected")] : [];
  const ic = icon("chip", 15, st === "Selected" ? "ink/primary" : "ink/secondary"); ic.name = "Icon"; c.appendChild(ic);
  const t = await text("Models", "Pixel/Body 14"); t.name = "Label"; c.appendChild(t); t.layoutGrow = 1;
  const dot = figma.createEllipse(); dot.resize(6, 6); dot.fills = [paint("ink/primary")]; dot.name = "Live dot"; c.appendChild(dot);
  navVars.push(c);
}
const nav = figma.combineAsVariants(navVars, page); nav.name = "Nav item";
const pNL = nav.addComponentProperty("Label", "TEXT", "Models");
const pNI = nav.addComponentProperty("Icon", "INSTANCE_SWAP", ICON("chip").id);
const pND = nav.addComponentProperty("Recording dot", "BOOLEAN", false);
nav.children.forEach(v => {
  v.findOne(n => n.name === "Label").componentPropertyReferences = {characters: pNL};
  v.findOne(n => n.name === "Icon").componentPropertyReferences = {mainComponent: pNI};
  v.findOne(n => n.name === "Live dot").componentPropertyReferences = {visible: pND};
});
nav.description = "A sidebar item (MainWindow.navItem): Carbon icon 15, label, 38 high, radius 6. Selected: fill 10% white and the icon in ink. The dot shows beside Meetings while a meeting records, from any page.";
nav.layoutMode = "VERTICAL"; nav.itemSpacing = 8; nav.paddingLeft = nav.paddingRight = nav.paddingTop = nav.paddingBottom = 10;
nav.primaryAxisSizingMode = "AUTO"; nav.counterAxisSizingMode = "AUTO"; nav.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made["Nav item"] = nav.id;
const navDefault = nav.children.find(v => v.name === "State=Default");
const navSel = nav.children.find(v => v.name === "State=Selected");

const sideVars = [];
for (const [sel] of SECTIONS) {
  const c = figma.createComponent(); c.name = "Page=" + sel;
  c.layoutMode = "VERTICAL"; c.primaryAxisSizingMode = "FIXED"; c.counterAxisSizingMode = "FIXED"; c.resize(220, 760); c.itemSpacing = 0;
  c.fills = [paint("surface/rail")];
  c.strokes = [paint("edge/border")]; c.strokeRightWeight = 1; c.strokeLeftWeight = 0; c.strokeTopWeight = 0; c.strokeBottomWeight = 0; c.strokeAlign = "INSIDE";
  const clear = figma.createFrame(); clear.name = "Title bar clearance"; clear.resize(220, 52); clear.fills = []; c.appendChild(clear);
  const tl = lights.createInstance(); clear.appendChild(tl); tl.x = 20; tl.y = 20;
  const wmw = al("HORIZONTAL", {name: "Wordmark block", pad: [6, 20, 20, 20]}); wmw.appendChild(wm.createInstance()); c.appendChild(wmw);
  const list = al("VERTICAL", {name: "Pages", gap: 8, pad: [0, 10, 0, 10], cross: "MIN"}); c.appendChild(list); list.layoutSizingHorizontal = "FILL";
  for (const [label, ic] of SECTIONS) {
    const it = (label === sel ? navSel : navDefault).createInstance();
    list.appendChild(it); it.layoutSizingHorizontal = "FILL";
    it.setProperties({[pNL]: label, [pNI]: ICON(ic).id});
    it.name = label;
  }
  const spacer = figma.createFrame(); spacer.name = "Spacer"; spacer.fills = []; c.appendChild(spacer); spacer.layoutSizingHorizontal = "FILL"; spacer.layoutGrow = 1;
  const ver = al("HORIZONTAL", {name: "Version", pad: [14, 20, 14, 20]});
  ver.appendChild(await text("1.0.0", "Pixel/Data 13", "ink/dim")); c.appendChild(ver);
  sideVars.push(c);
}
const sidebar = figma.combineAsVariants(sideVars, page); sidebar.name = "Sidebar";
sidebar.description = "MainWindow.sidebar: 220 wide on the rail (vibrancy plus 55% black), traffic lights in the 52 clearance, the wordmark, eight pages in the reviewed order, the version at the foot. Clicking an item opens its page; the page open last opens again at launch (Settings.lastPage).";
sidebar.layoutMode = "HORIZONTAL"; sidebar.itemSpacing = 24; sidebar.paddingLeft = sidebar.paddingRight = sidebar.paddingTop = sidebar.paddingBottom = 24;
sidebar.primaryAxisSizingMode = "AUTO"; sidebar.counterAxisSizingMode = "AUTO";
sidebar.fills = [{type: "IMAGE", imageHash: BG_HASH, scaleMode: "FILL"}];
made.Sidebar = sidebar.id;

// ---------- Tab and Page header ----------
const tabVars = [];
for (const st of ["Open", "Closed"]) {
  const c = figma.createComponent(); c.name = "State=" + st;
  c.layoutMode = "VERTICAL"; c.primaryAxisSizingMode = "AUTO"; c.counterAxisSizingMode = "AUTO"; c.itemSpacing = 10; c.fills = [];
  const t = await text("History", "Pixel/Body 14", st === "Open" ? "ink/primary" : "ink/secondary"); t.name = "Label"; c.appendChild(t);
  const u = figma.createRectangle(); u.name = "Underline"; u.resize(t.width, 2); u.fills = st === "Open" ? [paint("ink/primary")] : []; c.appendChild(u); u.layoutSizingHorizontal = "FILL";
  tabVars.push(c);
}
const tab = figma.combineAsVariants(tabVars, page); tab.name = "Tab";
const pTab = tab.addComponentProperty("Label", "TEXT", "History");
tab.children.forEach(v => v.findOne(n => n.name === "Label").componentPropertyReferences = {characters: pTab});
tab.description = "One tab of a TabStrip: the label, and a 2 px underline as wide as the label under the open one. Tabs sit 24 apart over a 1 px rule. A tab strip, never a content switcher.";
tab.layoutMode = "HORIZONTAL"; tab.itemSpacing = 24; tab.paddingLeft = tab.paddingRight = tab.paddingTop = tab.paddingBottom = 16;
tab.primaryAxisSizingMode = "AUTO"; tab.counterAxisSizingMode = "AUTO"; tab.fills = [{type: "SOLID", color: {r: 0.04, g: 0.04, b: 0.04}}];
made.Tab = tab.id;

const hdr = figma.createComponent(); hdr.name = "Page header";
hdr.layoutMode = "VERTICAL"; hdr.primaryAxisSizingMode = "AUTO"; hdr.counterAxisSizingMode = "FIXED"; hdr.resize(884, 60); hdr.itemSpacing = 8; hdr.fills = [];
const hT = await text("Transcriptions", "Pixel/Title 22"); hT.name = "Title"; hdr.appendChild(hT);
const hS = await text("Everything you have dictated, newest first. Search it, copy a line back out, or delete what you no longer need.", "Pixel/Body 14", "ink/secondary");
hS.name = "Subtitle"; hdr.appendChild(hS); hS.textAutoResize = "HEIGHT"; hS.resize(560, hS.height);
hT.componentPropertyReferences = {characters: hdr.addComponentProperty("Title", "TEXT", "Transcriptions")};
hS.componentPropertyReferences = {characters: hdr.addComponentProperty("Subtitle", "TEXT", hS.characters)};
hdr.primaryAxisSizingMode = "AUTO";
hdr.description = "PageHeader: the title (22) and one subtitle wrapped at 560 (about 65 characters). At most one instrument at the right, placed beside the instance on the screen.";
made["Page header"] = hdr.id;

// ---------- Window background ----------
const bg = figma.createComponent(); bg.name = "Window background"; bg.resize(1160, 760); bg.clipsContent = true; bg.fills = [];
const img = figma.createRectangle(); img.name = "The Death of Socrates"; img.resize(1160, 760);
img.fills = [{type: "IMAGE", imageHash: BG_HASH, scaleMode: "FILL"}]; img.constraints = {horizontal: "STRETCH", vertical: "STRETCH"}; bg.appendChild(img);
const scrim = figma.createRectangle(); scrim.name = "Scrim"; scrim.resize(1160, 760); scrim.fills = [paint("surface/painting-scrim")];
scrim.constraints = {horizontal: "STRETCH", vertical: "STRETCH"}; bg.appendChild(scrim);
bg.description = "BackgroundImage: Jacques-Louis David's The Death of Socrates (1787) in colour, scaled to fill, under a 58% black scrim. Behind every window and, softened, behind the overlay tiles on Settings.";
made["Window background"] = bg.id;

// ---------- Lay the page out ----------
const order = [["Button", 0, 400], ["Toggle", 800, 400], ["Radio mark", 1000, 400], ["Tick box", 1150, 400], ["Field", 800, 520], ["Search box", 800, 680], ["Popup", 1240, 520], ["Popup chevrons", 1460, 520],
  ["Key chip", 1240, 600], ["Tag chip", 1360, 600], ["Status line", 1240, 660], ["Progress line", 1240, 720], ["Gauge line", 0, 860], ["Level meter", 260, 860], ["Faint delete", 520, 860],
  ["App icon tile", 1180, 860], ["Wordmark", 1240, 860], ["Traffic lights", 1180, 920], ["Nav item", 0, 1160], ["Tab", 260, 1160], ["Page header", 520, 1160], ["Window background", 0, 1380], ["Sidebar", 1260, 1380]];
for (const [n, x, y] of order) { const node = await figma.getNodeByIdAsync(made[n] || (n === "Popup chevrons" ? chev.id : "")); if (node) place(node, x, y); }
made["Popup chevrons"] = chev.id;
// Park the raw image frames out of the way, labelled as sources.
let px = 0;
for (const n of page.children.filter(n => n.type === "FRAME" && /^(asset|book)-/.test(n.name))) {
  n.resize(n.name.startsWith("book-") ? 70 : 120, n.name.startsWith("book-") ? 105 : 80); place(n, px, 3000); px += n.width + 12; n.locked = true;
}
return made;
