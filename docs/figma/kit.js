// The screen kit for the Figma file "[ SIGMAFLOW ]" (ucHDq8KTA5W3xmG1ssf1mX).
// Stored in the file as the hidden text node "__kit__" on the Components page. A screen script loads it:
//
//   const AF = Object.getPrototypeOf(async function(){}).constructor;
//   const kit = await new AF("figma", (await figma.getNodeByIdAsync(KIT_NODE_ID)).characters)(figma);
//
// Every helper mirrors a view in Sources/SigmaFlow/UI (named beside it) and takes its numbers from DS.
// Keep this file and the node identical. No backticks or template strings in here.

const kit = {};
kit.C = {
  Button: "5:146", Toggle: "5:155", Popup: "5:159", Field: "5:168", Search: "5:182", KeyChip: "5:183", TagChip: "5:185",
  Radio: "5:192", Tick: "5:198", Gauge: "5:247", Progress: "5:248", Meter: "5:333", Status: "5:334", FaintDelete: "5:339",
  AppIconTile: "5:345", Wordmark: "5:346", TrafficLights: "5:351", NavItem: "5:367", Sidebar: "5:1008", Tab: "5:1015",
  PageHeader: "5:1016", WindowBackground: "5:1019", PopupChevrons: "5:156"
};
kit.BG_HASH = "91810ecfd86b11542cb560bc15d1dd494608b7c3";
kit.ICON_HASH = "daaae7de662a4805746835f28961c35fe7a1bcda";
kit.APPLE_HASH = "b676e65af78d266e1c78e1bf0fc72df0e55bd869";

await figma.loadFontAsync({family: "Geist Mono", style: "Regular"});
await figma.loadFontAsync({family: "Geist Mono", style: "Light"});
await figma.loadFontAsync({family: "Inter", style: "Regular"});
await figma.loadFontAsync({family: "Inter", style: "Semi Bold"});

const allVars = await figma.variables.getLocalVariablesAsync();
kit.v = function (n) { const v = allVars.find(x => x.name === n); if (!v) throw new Error("no variable " + n); return v; };
kit.paint = function (n, opacity) {
  // The opacity goes in before binding: the bound paint that comes back is read-only.
  const base = {type: "SOLID", color: {r: 1, g: 1, b: 1}};
  if (opacity !== undefined) base.opacity = opacity;
  return figma.variables.setBoundVariableForPaint(base, "color", kit.v(n));
};
const tstyles = await figma.getLocalTextStylesAsync();
kit.styleId = function (n) { const s = tstyles.find(x => x.name === n); if (!s) throw new Error("no text style " + n); return s.id; };

// Component lookup: sets by name, variants by property string.
const cache = {};
kit.node = async function (id) { if (!cache[id]) cache[id] = await figma.getNodeByIdAsync(id); return cache[id]; };
kit.variant = async function (setId, props) {
  const set = await kit.node(setId);
  if (set.type === "COMPONENT") return set;
  const want = Object.entries(props || {});
  const hit = set.children.find(c => want.every(([k, val]) => c.name.split(", ").includes(k + "=" + val)));
  if (!hit) throw new Error("no variant " + JSON.stringify(props) + " in " + set.name);
  return hit;
};
kit.prop = async function (setId, name) {
  const set = await kit.node(setId);
  const defs = set.componentPropertyDefinitions;
  const k = Object.keys(defs).find(x => x.split("#")[0] === name);
  if (!k) throw new Error("no property " + name + " on " + set.name);
  return k;
};
kit.inst = async function (setId, variantProps, props) {
  const comp = await kit.variant(setId, variantProps);
  const i = comp.createInstance();
  if (props) {
    const out = {};
    for (const [k, val] of Object.entries(props)) out[await kit.prop(setId, k)] = val;
    i.setProperties(out);
  }
  return i;
};

// Icons
const compPage = await figma.getNodeByIdAsync("3:4");
await compPage.loadAsync();
const iconBoard = compPage.children.find(n => n.name === "Icons");
kit.iconComp = function (name) {
  const c = iconBoard.children.find(n => n.name === "Icon/" + name || n.name === name);
  if (!c) throw new Error("no icon " + name);
  return c;
};
kit.icon = function (name, size, color) {
  const i = kit.iconComp(name).createInstance();
  i.resize(size || 16, size || 16);
  i.name = name;
  if (color) i.findOne(c => c.name === "shape").fills = [kit.paint(color)];
  return i;
};
kit.mark = function (name, height) {
  const i = kit.iconComp("Mark/" + name).createInstance();
  i.rescale((height || 24) / 24);
  return i;
};

// Text. Styles: "Pixel/Body 14", "Pixel/Caption 13", "Pixel/Title 22", "Pixel/Eyebrow 12", "Pixel/Data 13",
// "Pixel/Transcript 15", "Pixel/Micro 11", "Mono/Mono 12", and the rest on the Foundations page.
kit.text = async function (str, style, color, o) {
  o = o || {};
  const t = figma.createText();
  await t.setTextStyleIdAsync(kit.styleId(style || "Pixel/Body 14"));
  t.characters = String(str);
  t.fills = [kit.paint(color || "ink/primary")];
  if (o.name) t.name = o.name;
  if (o.w) { t.textAutoResize = "HEIGHT"; t.resize(o.w, t.height); }
  if (o.align) t.textAlignHorizontal = o.align;
  if (o.opacity !== undefined) t.opacity = o.opacity;
  return t;
};
kit.eyebrow = function (str, color) { return kit.text(str, "Pixel/Eyebrow 12", color || "ink/secondary", {name: "Eyebrow"}); };
kit.caption = function (str, w) { return kit.text(str, "Pixel/Caption 13", "ink/secondary", {name: "Caption", w: w}); };

// Auto layout. o: {name, gap, pad:[t,r,b,l] or n, fill, fillOpacity, stroke, radius, cross, main, w, h, clip}
kit.al = function (dir, o) {
  o = o || {};
  const f = figma.createAutoLayout(dir || "VERTICAL");
  f.name = o.name || (dir === "HORIZONTAL" ? "row" : "column");
  f.itemSpacing = o.gap || 0;
  const p = typeof o.pad === "number" ? [o.pad, o.pad, o.pad, o.pad] : (o.pad || [0, 0, 0, 0]);
  f.paddingTop = p[0]; f.paddingRight = p[1]; f.paddingBottom = p[2]; f.paddingLeft = p[3];
  f.fills = o.fill ? [kit.paint(o.fill, o.fillOpacity)] : [];
  if (o.stroke) { f.strokes = [kit.paint(o.stroke)]; f.strokeWeight = o.strokeWeight || 1; f.strokeAlign = "INSIDE"; }
  if (o.radius) f.cornerRadius = o.radius;
  f.counterAxisAlignItems = o.cross || (dir === "HORIZONTAL" ? "CENTER" : "MIN");
  if (o.main) f.primaryAxisAlignItems = o.main;
  if (o.w || o.h) {
    f.resize(o.w || 100, o.h || 100);
    if (o.w) { if (dir === "HORIZONTAL") f.primaryAxisSizingMode = "FIXED"; else f.counterAxisSizingMode = "FIXED"; }
    if (o.h) { if (dir === "HORIZONTAL") f.counterAxisSizingMode = "FIXED"; else f.primaryAxisSizingMode = "FIXED"; }
    // resize() fixes both sides; the side not given goes back to hugging.
    if (!o.h) { if (dir === "HORIZONTAL") f.counterAxisSizingMode = "AUTO"; else f.primaryAxisSizingMode = "AUTO"; }
    if (!o.w) { if (dir === "HORIZONTAL") f.primaryAxisSizingMode = "AUTO"; else f.counterAxisSizingMode = "AUTO"; }
  }
  if (o.clip) f.clipsContent = true;
  return f;
};
// Append children; "fill" stretches a child across the parent's width (or grows it along a row).
kit.add = function (parent, children, mode) {
  for (const c of [].concat(children)) {
    if (!c) continue;
    parent.appendChild(c);
    if (mode === "fill") {
      if (parent.layoutMode === "VERTICAL") c.layoutSizingHorizontal = "FILL"; else c.layoutGrow = 1;
      if (c.type === "TEXT") c.textAutoResize = "HEIGHT";
    }
  }
  return parent;
};
kit.fill = function (node) {
  const p = node.parent;
  if (p.layoutMode === "VERTICAL") node.layoutSizingHorizontal = "FILL";
  else if (p.layoutMode === "HORIZONTAL") node.layoutGrow = 1;
  if (node.type === "TEXT") node.textAutoResize = "HEIGHT";
  return node;
};
kit.spacer = function () { const s = figma.createFrame(); s.name = "Spacer"; s.fills = []; s.resize(1, 1); s.layoutGrow = 1; return s; };
kit.rect = function (w, h, fill, radius) { const r = figma.createRectangle(); r.resize(w, h); r.fills = fill ? [kit.paint(fill)] : []; if (radius) r.cornerRadius = radius; return r; };
kit.dot = function (size, fill) { const e = figma.createEllipse(); e.resize(size, size); e.fills = [kit.paint(fill || "ink/primary")]; return e; };
kit.divider = function () { const r = figma.createRectangle(); r.name = "Divider"; r.resize(100, 1); r.fills = [kit.paint("edge/border")]; return r; };

// Controls (instances of the library)
kit.button = async function (label, o) {
  o = o || {};
  const kind = {inverted: "Inverted", secondary: "Secondary", tertiary: "Tertiary"}[o.kind || "tertiary"];
  const props = {"Label": label || "", "Show icon": !!o.icon, "Show trailing icon": !!o.trailing};
  if (o.icon) props["Icon"] = kit.iconComp(o.icon).id;
  if (o.trailing) props["Trailing icon"] = kit.iconComp(o.trailing).id;
  const b = await kit.inst(kit.C.Button, {Kind: kind, State: o.state || "Default", Size: o.compact ? "Compact" : "Regular"}, props);
  b.name = (label || o.icon || "Button") + " button";
  if (!label) { const t = b.findOne(n => n.name === "Label"); if (t) t.visible = false; }
  if (o.dim) { const ic = b.findOne(n => n.name === "Icon"); if (ic) ic.opacity = 0.35; }
  if (o.width) { b.primaryAxisSizingMode = "FIXED"; b.resize(o.width, b.height); }
  return b;
};
kit.toggle = function (on, enabled) { return kit.inst(kit.C.Toggle, {On: on ? "Yes" : "No", Enabled: enabled === false ? "No" : "Yes"}); };
kit.popup = async function (value, width) { const p = await kit.inst(kit.C.Popup, null, {Value: value}); if (width) p.resize(width, 32); return p; };
kit.field = async function (str, o) { o = o || {}; const f = await kit.inst(kit.C.Field, {State: o.empty ? "Empty" : "Filled"}, {Text: str}); if (o.width) f.resize(o.width, 32); return f; };
kit.search = async function (str, o) { o = o || {}; const f = await kit.inst(kit.C.Search, {State: o.empty === false ? "Filled" : (o.filled ? "Filled" : "Empty")}, {Text: str}); if (o.width) f.resize(o.width, 32); return f; };
kit.keyChip = function (k) { return kit.inst(kit.C.KeyChip, null, {Key: k}); };
kit.tagChip = function (t) { return kit.inst(kit.C.TagChip, null, {Tag: t}); };
kit.radio = function (on) { return kit.inst(kit.C.Radio, {On: on ? "Yes" : "No"}); };
kit.tick = function (on) { return kit.inst(kit.C.Tick, {On: on ? "Yes" : "No"}); };
kit.gauge = function (label, value) { return kit.inst(kit.C.Gauge, {Value: String(value)}, {Label: label}); };
kit.progress = async function (fraction) {
  const p = await kit.inst(kit.C.Progress, null, {Percent: Math.round(fraction * 100) + "%"});
  const f = p.findOne(n => n.name === "fill"); f.resize(Math.max(1, 92 * fraction), 2);
  return p;
};
kit.meter = function (dots, lit) { return kit.inst(kit.C.Meter, {Dots: String(dots || 14), Lit: String(lit || 0)}); };
kit.status = function (str) { return kit.inst(kit.C.Status, null, {Text: str || "Copied"}); };
kit.faintDelete = function (title) { return kit.inst(kit.C.FaintDelete, null, {Title: title}); };
kit.appIcon = async function (size, radius) {
  const i = (await kit.node(kit.C.AppIconTile)).createInstance();
  if (size) { i.resize(size, size); i.cornerRadius = radius || Math.round(size / 4); }
  return i;
};

// Page furniture
kit.header = async function (title, subtitle, instrument) {
  const h = await kit.inst(kit.C.PageHeader, null, {Title: title, Subtitle: subtitle || ""});
  if (!subtitle) { const s = h.findOne(n => n.name === "Subtitle"); if (s) s.visible = false; }
  if (!instrument) { h.name = "Page header"; return h; }
  const row = kit.al("HORIZONTAL", {name: "Page header", gap: 24, cross: "CENTER"});
  row.appendChild(h); h.layoutGrow = 1; h.layoutSizingHorizontal = "FILL";
  row.appendChild(instrument);
  return row;
};
// TabStrip: labels, the open one underlined, a 1 px rule beneath.
kit.tabs = async function (labels, open) {
  const strip = kit.al("VERTICAL", {name: "Tab strip"});
  const row = kit.al("HORIZONTAL", {name: "Tabs", gap: 24, cross: "MIN"});
  for (let i = 0; i < labels.length; i++) {
    const t = await kit.inst(kit.C.Tab, {State: i === open ? "Open" : "Closed"}, {Label: labels[i]});
    t.name = labels[i] + " tab"; row.appendChild(t);
  }
  strip.appendChild(row);
  const rule = kit.divider(); strip.appendChild(rule); rule.layoutSizingHorizontal = "FILL";
  return strip;
};
// Card: glass, 1 px border, radius 8, clipped.
kit.card = function (name) {
  const c = kit.al("VERTICAL", {name: name || "Card", fill: "surface/glass", stroke: "edge/border", radius: 8, clip: true});
  return c;
};
// CardRow: label, optional caption under it, optional data, the control in a lane at the right. 52 high without a caption.
kit.row = async function (label, o) {
  o = o || {};
  const outer = kit.al("VERTICAL", {name: o.name || label});
  const line = kit.al("HORIZONTAL", {name: "content", gap: 16, pad: [0, 16, 0, 16], cross: "CENTER"});
  line.minHeight = 52;
  outer.appendChild(line); line.layoutSizingHorizontal = "FILL";
  const words = kit.al("VERTICAL", {name: "words", gap: 2, pad: [12, 0, 12, 0]});
  line.appendChild(words); words.layoutGrow = 1;
  words.appendChild(await kit.text(label, o.labelStyle || "Pixel/Body 14", o.labelColor || "ink/primary", {name: "Label"}));
  if (o.caption) { const c = await kit.caption(o.caption); words.appendChild(c); c.layoutSizingHorizontal = "FILL"; c.textAutoResize = "HEIGHT"; c.maxWidth = 620; }
  if (o.data) line.appendChild(await kit.text(o.data, "Pixel/Data 13", "ink/secondary", {name: "Data"}));
  for (const ctl of [].concat(o.control || [])) if (ctl) line.appendChild(ctl);
  if (!o.last) { const d = kit.divider(); outer.appendChild(d); d.layoutSizingHorizontal = "FILL"; }
  if (o.opacity !== undefined) outer.opacity = o.opacity;
  return outer;
};
// CardContentRow: any content full width, 16 by 12 inset.
kit.contentRow = function (child, o) {
  o = o || {};
  const outer = kit.al("VERTICAL", {name: o.name || "Content row"});
  const inner = kit.al(o.dir || "VERTICAL", {name: "content", gap: o.gap || 8, pad: o.pad || [12, 16, 12, 16]});
  outer.appendChild(inner); inner.layoutSizingHorizontal = "FILL";
  for (const c of [].concat(child)) { if (!c) continue; inner.appendChild(c); }
  if (!o.last) { const d = kit.divider(); outer.appendChild(d); d.layoutSizingHorizontal = "FILL"; }
  return {row: outer, inner: inner};
};
// CardFooter: hint at the left, at most two buttons at the right, on the recessed footer fill.
kit.footer = async function (hint, actions) {
  const f = kit.al("HORIZONTAL", {name: "Footer", gap: 8, pad: [12, 16, 12, 16], fill: "surface/footer", cross: "CENTER"});
  f.strokes = [kit.paint("edge/border")]; f.strokeTopWeight = 1; f.strokeBottomWeight = 0; f.strokeLeftWeight = 0; f.strokeRightWeight = 0; f.strokeAlign = "INSIDE";
  const h = await kit.text(hint || "", "Pixel/Caption 13", "ink/secondary", {name: "Hint"});
  f.appendChild(h); h.layoutGrow = 1;
  for (const a of [].concat(actions || [])) if (a) f.appendChild(a);
  return f;
};
// DayLabel: an eyebrow above one day's rows, 16 in, 12 above, 8 below.
kit.dayLabel = async function (str) {
  const f = kit.al("HORIZONTAL", {name: "Day " + str, pad: [12, 16, 8, 16]});
  f.appendChild(await kit.eyebrow(str));
  return f;
};
// EditorRow: the editor at the head of a list card, a shade lighter, 16 inset, 12 between.
kit.editorRow = function () { return kit.al("VERTICAL", {name: "Editor", gap: 12, pad: 16, fill: "fill/editor"}); };
kit.labeledField = async function (label, fieldNode) {
  const c = kit.al("VERTICAL", {name: label, gap: 6});
  c.appendChild(await kit.eyebrow(label)); c.appendChild(fieldNode); fieldNode.layoutSizingHorizontal = "FILL";
  return c;
};
// An eyebrow over its card, 8 apart (a section of a settings-like page).
kit.block = async function (eyebrow, card) {
  const b = kit.al("VERTICAL", {name: eyebrow, gap: 8});
  b.appendChild(await kit.eyebrow(eyebrow)); b.appendChild(card); card.layoutSizingHorizontal = "FILL";
  return b;
};
// EmptyCardBody: a line in ink, a centred caption, at most one button. 48 above and below.
kit.empty = async function (title, detail, action) {
  const e = kit.al("VERTICAL", {name: "Empty", gap: 16, pad: [48, 24, 48, 24], cross: "CENTER"});
  e.appendChild(await kit.text(title, "Pixel/Transcript 15", "ink/primary"));
  if (detail) e.appendChild(await kit.text(detail, "Pixel/Caption 13", "ink/secondary", {w: 560, align: "CENTER"}));
  if (action) e.appendChild(action);
  return e;
};
// ListToolbar: search at the left, an optional add button, the count at the right.
kit.listToolbar = async function (placeholder, count, o) {
  o = o || {};
  const r = kit.al("HORIZONTAL", {name: "List toolbar", gap: 4, cross: "CENTER"});
  r.appendChild(await kit.search(o.query || placeholder, {filled: !!o.query}));
  if (o.add) r.appendChild(await kit.button(o.add, {kind: "secondary", icon: "add"}));
  r.appendChild(kit.spacer());
  r.appendChild(await kit.text(count, "Pixel/Data 13", "ink/secondary", {name: "Count"}));
  return r;
};
// A stand-in for a photo or screenshot from someone's recording (the real ones are private).
kit.picture = function (w, h, label, tone) {
  const f = kit.al("VERTICAL", {name: label || "Picture", w: w, h: h, main: "CENTER", cross: "CENTER", radius: 3, clip: true});
  f.fills = [{type: "SOLID", color: tone || {r: 0.23, g: 0.22, b: 0.2}}];
  if (w >= 40) { const i = kit.icon("image", Math.min(16, Math.round(h / 2)), "ink/dim"); f.appendChild(i); }
  return f;
};

// Window: 1160 by 760 (or o.w by o.h), radius 11, the painting behind, the sidebar for o.section, the page column.
// o: {name, section, x, y, parent, w, h, noSidebar}. Returns {win, page} where page is the padded page column
// (24 top, 28 sides and foot, 28 between sections), already FILL.
kit.window = async function (o) {
  const w = o.w || 1160, h = o.h || 760;
  const win = figma.createFrame();
  win.name = o.name; win.resize(w, h); win.cornerRadius = 11; win.clipsContent = true;
  win.fills = [kit.paint("geist/bg-100")];
  win.effects = [{type: "DROP_SHADOW", color: {r: 0, g: 0, b: 0, a: 0.45}, offset: {x: 0, y: 10}, radius: 24, spread: 0, visible: true, blendMode: "NORMAL"}];
  if (o.parent) o.parent.appendChild(win);
  win.x = o.x || 0; win.y = o.y || 0;
  win.layoutMode = "HORIZONTAL"; win.primaryAxisSizingMode = "FIXED"; win.counterAxisSizingMode = "FIXED"; win.itemSpacing = 0; win.counterAxisAlignItems = "MIN";
  const bg = (await kit.node(kit.C.WindowBackground)).createInstance();
  win.appendChild(bg); bg.layoutPositioning = "ABSOLUTE"; bg.x = 0; bg.y = 0; bg.resize(w, h); bg.constraints = {horizontal: "STRETCH", vertical: "STRETCH"};
  bg.locked = true;
  if (!o.noSidebar) {
    const side = await kit.inst(kit.C.Sidebar, {Page: o.section || "Transcriptions"});
    win.appendChild(side); side.layoutSizingVertical = "FILL";
    if (o.recording) {
      const m = side.findOne(n => n.name === "Meetings" && n.type === "INSTANCE");
      if (m) m.setProperties({[await kit.prop(kit.C.NavItem, "Recording dot")]: true});
    }
  }
  const page = kit.al("VERTICAL", {name: "Page", gap: 28, pad: [24, 28, 28, 28], clip: true});
  win.appendChild(page); page.layoutGrow = 1; page.layoutSizingVertical = "FILL";
  return {win: win, page: page};
};
// The veil over the page while the delete question is open, with the question centred on it.
kit.veil = function (win, fill) {
  const v = figma.createFrame(); v.name = "Veil"; v.fills = [kit.paint(fill || "surface/question-veil")];
  win.appendChild(v); v.layoutPositioning = "ABSOLUTE"; v.x = 0; v.y = 0; v.resize(win.width, win.height);
  v.constraints = {horizontal: "STRETCH", vertical: "STRETCH"};
  return v;
};

// Notes beside screens, in Inter on white so they never read as part of the design.
kit.note = async function (str, o) {
  o = o || {};
  const n = figma.createAutoLayout("VERTICAL");
  n.name = "Note"; n.itemSpacing = 6; n.paddingTop = n.paddingBottom = 14; n.paddingLeft = n.paddingRight = 16; n.cornerRadius = 6;
  n.fills = [{type: "SOLID", color: {r: 1, g: 1, b: 1}}];
  if (o.title) {
    const t = figma.createText(); t.fontName = {family: "Inter", style: "Semi Bold"}; t.fontSize = 13; t.characters = o.title;
    t.fills = [{type: "SOLID", color: {r: 0.08, g: 0.08, b: 0.08}}]; n.appendChild(t);
    t.textAutoResize = "HEIGHT"; t.layoutSizingHorizontal = "FILL";
  }
  const b = figma.createText(); b.fontName = {family: "Inter", style: "Regular"}; b.fontSize = 12; b.characters = str;
  b.lineHeight = {unit: "PIXELS", value: 18}; b.fills = [{type: "SOLID", color: {r: 0.2, g: 0.2, b: 0.2}}];
  n.appendChild(b);
  n.counterAxisSizingMode = "FIXED"; n.resize(o.w || 340, 40); n.primaryAxisSizingMode = "AUTO";
  b.layoutSizingHorizontal = "FILL"; b.textAutoResize = "HEIGHT";
  if (o.parent) o.parent.appendChild(n);
  n.x = o.x || 0; n.y = o.y || 0;
  return n;
};
// A label above a screen: its number and name, large, in Inter.
kit.label = async function (str, o) {
  o = o || {};
  const t = figma.createText(); t.fontName = {family: "Inter", style: "Semi Bold"}; t.fontSize = o.size || 20; t.characters = str;
  t.fills = [{type: "SOLID", color: o.dark ? {r: 0.1, g: 0.1, b: 0.1} : {r: 1, g: 1, b: 1}}];
  t.name = "Label " + str;
  if (o.parent) o.parent.appendChild(t);
  t.x = o.x || 0; t.y = o.y || 0;
  return t;
};
// Find or make a Figma Section on the current page.
kit.section = function (name, x, y, w, h) {
  let s = figma.currentPage.children.find(n => n.type === "SECTION" && n.name === name);
  if (!s) { s = figma.createSection(); s.name = name; }
  s.x = x; s.y = y; s.resizeWithoutConstraints(w, h);
  s.fills = [{type: "SOLID", color: {r: 0.11, g: 0.11, b: 0.11}}];
  return s;
};
// Remove what a previous run of the same script drew, by name, inside a parent.
kit.clear = function (parent, names) {
  for (const c of parent.children.slice()) if (names.includes(c.name)) c.remove();
};
// Prototype: clicking "from" opens "to" (a top-level frame on the same page). Overlay for questions and panels.
kit.link = async function (from, to, o) {
  o = o || {};
  const action = o.overlay
    ? {type: "NODE", destinationId: to.id, navigation: "OVERLAY", transition: {type: "DISSOLVE", easing: {type: "EASE_OUT"}, duration: 0.16}, overlayRelativePosition: undefined}
    : {type: "NODE", destinationId: to.id, navigation: o.swap ? "SWAP" : "NAVIGATE", transition: o.instant ? null : {type: "DISSOLVE", easing: {type: "EASE_IN_AND_OUT"}, duration: 0.15}, preserveScrollPosition: false};
  if (action.overlayRelativePosition === undefined) delete action.overlayRelativePosition;
  await from.setReactionsAsync([{trigger: {type: o.trigger || "ON_CLICK"}, actions: [action]}]);
};
kit.back = async function (from) { await from.setReactionsAsync([{trigger: {type: "ON_CLICK"}, actions: [{type: "BACK"}]}]); };

return kit;
