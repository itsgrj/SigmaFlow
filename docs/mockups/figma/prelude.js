// ---- SigmaFlow 1.0 builder prelude (Figma Plugin API). Geist dark scale, glass over the painting.
// Run inside use_figma: this text is read from the hidden __prelude__ node and evaluated, then a screen function is called.
// Text is created in Geist Mono because Geist Pixel is not loadable from scripts; swap to Geist Pixel Square in the desktop app.
const FONT = { family: "Geist Mono", style: "Regular" };
const FONT_ACCENT = { family: "Geist Mono", style: "Light" };
const MONO = { family: "Geist Mono", style: "Regular" };
const IMAGE_HASH = "91810ecfd86b11542cb560bc15d1dd494608b7c3";
await Promise.all([figma.loadFontAsync(FONT), figma.loadFontAsync(FONT_ACCENT), figma.loadFontAsync(MONO)]);

const hex = (h) => ({ r: parseInt(h.slice(1,3),16)/255, g: parseInt(h.slice(3,5),16)/255, b: parseInt(h.slice(5,7),16)/255 });
const P = (h, a=1) => ({ type: "SOLID", color: hex(h), opacity: a });
const INK="#EDEDED", INK2="#A1A1A1", DIM="#8F8F8F", PLACE="#878787", BG="#0A0A0A", GREEN="#32D74B", BLUE="#0071F6";
const EDGE = P("#FFFFFF", 0.145), FILL = P("#FFFFFF", 0.06), GLASS = P("#0A0A0A", 0.72), RAIL = P("#000000", 0.55);
const ids = [];
const keep = (n) => { ids.push(n.id); return n; };
const CONTENT_X = 249, CONTENT_W = 883, SUBTITLE_W = 560;

function AL(dir, o={}) {
  const f = figma.createAutoLayout(dir, {});
  f.fills = []; f.strokes = [];
  Object.assign(f, o);
  return keep(f);
}
function pad(f, t, r=t, b=t, l=r) { f.paddingTop=t; f.paddingRight=r; f.paddingBottom=b; f.paddingLeft=l; return f; }
function T(txt, size, color=INK, o={}) {
  const n = figma.createText();
  n.fontName = o.font || FONT; n.characters = txt; n.fontSize = size;
  n.fills = [P(color)];
  n.lineHeight = { unit: "PIXELS", value: o.lh || Math.round(size*1.45) };
  if (o.tracking) n.letterSpacing = { unit: "PERCENT", value: o.tracking };
  if (o.upper) n.textCase = "UPPER";
  if (o.strike) n.textDecoration = "STRIKETHROUGH";
  if (o.center) n.textAlignHorizontal = "CENTER";
  if (o.w) { n.resize(o.w, n.height); n.textAutoResize = "HEIGHT"; }
  return keep(n);
}
function fill(n) { n.layoutSizingHorizontal = "FILL"; return n; }
function eyebrow(txt, color=INK2) { return T(txt, 12, color, { tracking: 6, upper: true, lh: 16 }); }
function caption(txt, w, o={}) { return T(txt, 13, INK2, Object.assign({ lh: 18, w }, o)); }
function data(txt, color=INK2) { return T(txt, 13, color, { lh: 18 }); }
function divider() { const r = figma.createRectangle(); r.fills=[EDGE]; r.resize(100, 1); return keep(r); }
function hdivider(parent) { const d = divider(); parent.appendChild(d); fill(d); return d; }
function svgIcon(svg, size, color) {
  const n = figma.createNodeFromSvg(svg.replace(/<svg /, '<svg fill="' + color + '" ').replace(/<path /g, '<path fill="' + color + '" '));
  n.resize(size, size); n.fills = []; return keep(n);
}
// Carbon icons used by the screens
const ICON = {
  "text--align--left": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M12 6H30V8H12zM12 12H24V14H12zM12 18H30V20H12zM12 24H24V26H12zM2 2H4V30H2zM6 6H8V8H6zM6 12H8V14H6zM6 18H8V20H6zM6 24H8V26H6z"/></svg>',
  "book": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M19 10H26V12H19z"/><path d="M19 15H26V17H19z"/><path d="M19 20H26V22H19z"/><path d="M6 10H13V12H6z"/><path d="M6 15H13V17H6z"/><path d="M6 20H13V22H6z"/><path d="M28,5H4A2.002,2.002,0,0,0,2,7V25a2.002,2.002,0,0,0,2,2H28a2.002,2.002,0,0,0,2-2V7A2.002,2.002,0,0,0,28,5ZM4,7H15V25H4ZM17,25V7H28V25Z"/></svg>',
  "text--short-paragraph": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M6 12H26V14H6zM6 18H22V20H6z"/></svg>',
  "magic-wand": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M29.414 24 12 6.586a2.048 2.048 0 0 0-2.828 0L6.586 9.172a2 2 0 0 0 0 2.828L24 29.414a2 2 0 0 0 2.828 0l2.586-2.586a2 2 0 0 0 0-2.828zM8 10.586 10.586 8l5 5-2.586 2.586zM25.414 28 14.414 17l2.586-2.586 11 11z"/><path d="M2.586 14.586 5 12.172l1.414 1.414L4 16zM10.586 2.586 13 .172l1.414 1.414L12 4zM2 4l2.414-2.414L5.828 3 3.414 5.414zM14 6.586 16.414 4.172l1.414 1.414L15.414 8zM4 10.586 6.414 8.172l1.414 1.414L5.414 12z"/></svg>',
  "chip": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M11,11V21H21V11Zm8,8H13V13h6Z"/><path d="M30,13V11H26V8a2,2,0,0,0-2-2H21V2H19V6H13V2H11V6H8A2,2,0,0,0,6,8v3H2v2H6v6H2v2H6v3a2,2,0,0,0,2,2h3v4h2V26h6v4h2V26h3a2,2,0,0,0,2-2V21h4V19H26V13ZM24,24H8V8H24Z"/></svg>',
  "settings": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M27,16.76c0-.25,0-.5,0-.76s0-.51,0-.77l1.92-1.68A2,2,0,0,0,29.3,11L26.94,7a2,2,0,0,0-1.73-1,2,2,0,0,0-.64.1l-2.43.82a11.35,11.35,0,0,0-1.31-.75l-.51-2.52a2,2,0,0,0-2-1.61H13.64a2,2,0,0,0-2,1.61l-.51,2.52a11.48,11.48,0,0,0-1.32.75L7.43,6.06A2,2,0,0,0,6.79,6,2,2,0,0,0,5.06,7L2.7,11a2,2,0,0,0,.41,2.51L5,15.24c0,.25,0,.5,0,.76s0,.51,0,.77L3.11,18.45A2,2,0,0,0,2.7,21L5.06,25a2,2,0,0,0,1.73,1,2,2,0,0,0,.64-.1l2.43-.82a11.35,11.35,0,0,0,1.31.75l.51,2.52a2,2,0,0,0,2,1.61h4.72a2,2,0,0,0,2-1.61l.51-2.52a11.48,11.48,0,0,0,1.32-.75l2.42.82a2,2,0,0,0,.64.1,2,2,0,0,0,1.73-1L29.3,21a2,2,0,0,0-.41-2.51ZM25.21,24l-3.43-1.16a8.86,8.86,0,0,1-2.71,1.57L18.36,28H13.64l-.71-3.55a9.36,9.36,0,0,1-2.7-1.57L6.79,24,4.43,20l2.72-2.4a8.9,8.9,0,0,1,0-3.13L4.43,12,6.79,8l3.43,1.16a8.86,8.86,0,0,1,2.71-1.57L13.64,4h4.72l.71,3.55a9.36,9.36,0,0,1,2.7,1.57L25.21,8,27.57,12l-2.72,2.4a8.9,8.9,0,0,1,0,3.13L27.57,20Z"/><path d="M16,22a6,6,0,1,1,6-6A5.94,5.94,0,0,1,16,22Zm0-10a3.91,3.91,0,0,0-4,4,3.91,3.91,0,0,0,4,4,3.91,3.91,0,0,0,4-4A3.91,3.91,0,0,0,16,12Z"/></svg>',
  "copy": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M28,10V28H10V10H28m0-2H10a2,2,0,0,0-2,2V28a2,2,0,0,0,2,2H28a2,2,0,0,0,2-2V10a2,2,0,0,0-2-2Z"/><path d="M4,18H2V4A2,2,0,0,1,4,2H18V4H4Z"/></svg>',
  "trash-can": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M12 12H14V24H12zM18 12H20V24H18z"/><path d="M4,6V8H6V28a2,2,0,0,0,2,2H24a2,2,0,0,0,2-2V8h2V6ZM8,28V8H24V28Z"/><path d="M12 2H20V4H12z"/></svg>',
  "edit": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M2 26H30V28H2zM25.4 9c.8-.8.8-2 0-2.8 0 0 0 0 0 0l-3.6-3.6c-.8-.8-2-.8-2.8 0 0 0 0 0 0 0l-15 15V24h6.4L25.4 9zM20.4 4L24 7.6l-3 3L17.4 7 20.4 4zM6 22v-3.6l10-10 3.6 3.6-10 10H6z"/></svg>',
  "checkmark": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M13 24L4 15 5.414 13.586 13 21.171 26.586 7.586 28 9 13 24z"/></svg>',
  "search": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M29,27.5859l-7.5521-7.5521a11.0177,11.0177,0,1,0-1.4141,1.4141L27.5859,29ZM4,13a9,9,0,1,1,9,9A9.01,9.01,0,0,1,4,13Z"/></svg>',
  "add": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M17 15L17 8 15 8 15 15 8 15 8 17 15 17 15 24 17 24 17 17 24 17 24 15z"/></svg>',
  "close": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M24 9.4L22.6 8 16 14.6 9.4 8 8 9.4 14.6 16 8 22.6 9.4 24 16 17.4 22.6 24 24 22.6 17.4 16 24 9.4z"/></svg>',
  "download": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M26 24v4H6v-4H4v4a2 2 0 0 0 2 2h20a2 2 0 0 0 2-2v-4zM26 14l-1.41-1.41L17 20.17V2h-2v18.17l-7.59-7.58L6 14l10 10 10-10z"/></svg>',
  "microphone": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M23,14v3A7,7,0,0,1,9,17V14H7v3a9,9,0,0,0,8,8.94V28H11v2H21V28H17V25.94A9,9,0,0,0,25,17V14Z"/><path d="M16,22a5,5,0,0,0,5-5V7A5,5,0,0,0,11,7V17A5,5,0,0,0,16,22ZM13,7a3,3,0,0,1,6,0V17a3,3,0,0,1-6,0Z"/></svg>',
  "warning": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2Zm0,26A12,12,0,1,1,28,16,12,12,0,0,1,16,28Z"/><path d="M15 8H17V19H15z"/><path d="M16,22a1.5,1.5,0,1,0,1.5,1.5A1.5,1.5,0,0,0,16,22Z"/></svg>',
  "circle-dash": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M7.7,4.7a14.7,14.7,0,0,0-3,3.1L6.3,9A13.26,13.26,0,0,1,8.9,6.3Z"/><path d="M4.6,12.3l-1.9-.6A12.51,12.51,0,0,0,2,16H4A11.48,11.48,0,0,1,4.6,12.3Z"/><path d="M2.7,20.4a14.4,14.4,0,0,0,2,3.9l1.6-1.2a12.89,12.89,0,0,1-1.7-3.3Z"/><path d="M7.8,27.3a14.4,14.4,0,0,0,3.9,2l.6-1.9A12.89,12.89,0,0,1,9,25.7Z"/><path d="M11.7,2.7l.6,1.9A11.48,11.48,0,0,1,16,4V2A12.51,12.51,0,0,0,11.7,2.7Z"/><path d="M24.2,27.3a15.18,15.18,0,0,0,3.1-3.1L25.7,23A11.53,11.53,0,0,1,23,25.7Z"/><path d="M27.4,19.7l1.9.6A15.47,15.47,0,0,0,30,16H28A11.48,11.48,0,0,1,27.4,19.7Z"/><path d="M29.2,11.6a14.4,14.4,0,0,0-2-3.9L25.6,8.9a12.89,12.89,0,0,1,1.7,3.3Z"/><path d="M24.1,4.6a14.4,14.4,0,0,0-3.9-2l-.6,1.9a12.89,12.89,0,0,1,3.3,1.7Z"/><path d="M20.3,29.3l-.6-1.9A11.48,11.48,0,0,1,16,28v2A21.42,21.42,0,0,0,20.3,29.3Z"/></svg>',
  "arrow--right": '<svg width="32" height="32" viewBox="0 0 32 32"><path d="M18 6 16.57 7.393 24.15 15 4 15 4 17 24.15 17 16.57 24.573 18 26 28 16 18 6z"/></svg>',
};
const chevrons = '<svg width="16" height="16" viewBox="0 0 16 16"><path d="M5 6.5L8 3.5L11 6.5M5 9.5L8 12.5L11 9.5" stroke="#8F8F8F" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';

function popup(value, w=200) {
  const f = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER", cornerRadius: 6, fills: [FILL], strokes: [EDGE], strokeWeight: 1, primaryAxisAlignItems: "SPACE_BETWEEN" });
  pad(f, 0, 10, 0, 12); f.resize(w, 32); f.layoutSizingHorizontal="FIXED"; f.layoutSizingVertical="FIXED"; f.name = "popup";
  f.appendChild(T(value, 14, INK, { lh: 20 })); const c = figma.createNodeFromSvg(chevrons); c.resize(16,16); c.fills=[]; f.appendChild(keep(c)); return f;
}
// The native small switch, tinted blue when on. disabled: the system dims it.
function toggle(on, disabled=false) {
  const f = AL("HORIZONTAL", { cornerRadius: 8, fills: [P(on ? BLUE : "#454545")], counterAxisAlignItems: "CENTER", primaryAxisAlignItems: on ? "MAX" : "MIN" });
  pad(f, 2); f.resize(28, 16); f.layoutSizingHorizontal="FIXED"; f.layoutSizingVertical="FIXED"; f.name = "toggle";
  if (disabled) f.opacity = 0.35;
  const k = figma.createEllipse(); k.resize(12,12); k.fills=[P("#FFFFFF")]; f.appendChild(keep(k)); return f;
}
// kind: inverted (the one primary), secondary (outlined), tertiary (quiet). fixedW pins the width so columns line up.
// disabled: the app draws a button that can't act yet at 35% (DS.Border.disabledOpacity).
function button(label, kind="secondary", icon, fixedW, disabled=false) {
  const f = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER", cornerRadius: 6 });
  pad(f, 0, kind==="tertiary"?10:12); f.resize(fixedW || 10, 32); f.layoutSizingVertical="FIXED"; f.layoutSizingHorizontal = fixedW ? "FIXED" : "HUG"; f.name = "button/"+kind;
  if (fixedW) f.primaryAxisAlignItems = "CENTER";
  let col = INK;
  if (kind==="inverted") { f.fills=[P(INK)]; col = BG; }
  else if (kind==="secondary") { f.fills=[FILL]; f.strokes=[EDGE]; f.strokeWeight=1; }
  else { col = INK2; }
  if (icon) f.appendChild(svgIcon(ICON[icon], 16, col));
  if (label) f.appendChild(T(label, 14, col, { lh: 20 }));
  if (disabled) f.opacity = 0.35;
  return f;
}
function field(text, w, placeholder=true) {
  const f = AL("HORIZONTAL", { counterAxisAlignItems: "CENTER", cornerRadius: 6, fills: [FILL], strokes: [EDGE], strokeWeight: 1 });
  pad(f, 0, 12); f.resize(w || 200, 32); f.layoutSizingVertical="FIXED"; f.layoutSizingHorizontal = "FIXED"; f.name="field";
  f.appendChild(T(text, 14, placeholder ? PLACE : INK, { lh: 20 })); return f;
}
// Multi-line box. Text wraps to the box width. placeholder=false renders typed text in ink.
// counter: a small "n / limit" bottom right. scroll=true: the text is longer than the box, so clip it and show a scrollbar.
function textarea(text, w, h=64, placeholder=true, counter, scroll=false) {
  const f = AL("VERTICAL", { cornerRadius: 6, fills: [FILL], strokes: [EDGE], strokeWeight: 1 });
  pad(f, 8, 12); f.resize(w || 400, h); f.layoutSizingVertical="FIXED"; f.layoutSizingHorizontal="FIXED"; f.name="textarea";
  const t = T(text, 14, placeholder ? PLACE : INK, { lh: 20 }); f.appendChild(t); t.textAutoResize = "HEIGHT"; t.layoutSizingHorizontal = "FILL";
  if (scroll) {
    f.clipsContent = true; f.paddingRight = 20;
    const bar = figma.createRectangle(); bar.resize(4, Math.round(h * 0.45)); bar.cornerRadius = 2; bar.fills = [P("#FFFFFF", 0.3)]; bar.name = "scrollbar";
    f.appendChild(keep(bar)); bar.layoutPositioning = "ABSOLUTE"; bar.x = (w || 400) - 10; bar.y = 8; bar.constraints = { horizontal: "MAX", vertical: "MIN" };
  }
  if (counter) {
    const cr = AL("HORIZONTAL", { primaryAxisAlignItems: "MAX", name: "counter" }); cr.appendChild(T(counter, 11, DIM, { lh: 14, font: MONO }));
    if (scroll) { pad(cr, 2, 6); cr.fills = [P("#161616", 0.92)]; cr.cornerRadius = 3; f.appendChild(cr); cr.layoutPositioning = "ABSOLUTE"; cr.x = (w || 400) - 20 - cr.width; cr.y = h - cr.height - 6; cr.constraints = { horizontal: "MAX", vertical: "MAX" }; }
    else { f.primaryAxisAlignItems = "SPACE_BETWEEN"; f.appendChild(cr); fill(cr); }
  }
  return f;
}
function chip(txt) { const f = AL("HORIZONTAL", { cornerRadius: 4, fills: [FILL], strokes: [EDGE], strokeWeight: 1 }); pad(f, 2, 8); f.appendChild(T(txt, 12, INK, { lh: 16, font: MONO })); return f; }
function tag(txt) { const f = AL("HORIZONTAL", { cornerRadius: 4, strokes: [EDGE], strokeWeight: 1 }); pad(f, 2, 6); f.appendChild(eyebrow(txt)); return f; }
function meter(lit) { const f = AL("HORIZONTAL", { itemSpacing: 3, counterAxisAlignItems: "CENTER" }); for (let i=0;i<14;i++){ const d=figma.createEllipse(); d.resize(5,5); d.fills=[i<lit?P(GREEN):P("#FFFFFF",0.18)]; f.appendChild(keep(d)); } return f; }
// Five-block gauge with a label: Accuracy / Speed on the Models rows.
function gauge(label, n) {
  const g = AL("HORIZONTAL", { itemSpacing: 10, counterAxisAlignItems: "CENTER" });
  g.appendChild(T(label, 11, DIM, { lh: 14, tracking: 4, upper: true, w: 68 }));
  const bars = AL("HORIZONTAL", { itemSpacing: 3 });
  for (let i=0;i<5;i++){ const r = figma.createRectangle(); r.resize(14,4); r.fills=[i<n?P(INK):P("#FFFFFF",0.14)]; bars.appendChild(keep(r)); }
  g.appendChild(bars); return g;
}
function gauges(acc, spd) { const v = AL("VERTICAL", { itemSpacing: 6, name: "gauges" }); v.appendChild(gauge("Accuracy", acc)); v.appendChild(gauge("Speed", spd)); return v; }
// Carbon-style content switcher: joined segments, the selected one is filled with ink. items = [[label, count], ...]
function switcher(items, active) {
  const s = AL("HORIZONTAL", { cornerRadius: 6, strokes: [EDGE], strokeWeight: 1, clipsContent: true, name: "content switcher" });
  items.forEach((it, i) => {
    const on = i === active;
    const seg = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER", fills: [on ? P(INK) : FILL] });
    pad(seg, 0, 14); seg.resize(10, 32); seg.layoutSizingVertical="FIXED"; seg.layoutSizingHorizontal="HUG";
    seg.appendChild(T(it[0], 14, on ? BG : INK, { lh: 20 }));
    if (it[1] != null) seg.appendChild(T(String(it[1]), 13, on ? BG : INK2, { lh: 18, font: MONO }));
    s.appendChild(seg);
    if (i < items.length - 1) { const d = divider(); d.resize(1, 32); s.appendChild(d); }
  });
  return s;
}
function progress(frac, w=100) {
  const pr = AL("HORIZONTAL", { itemSpacing: 10, counterAxisAlignItems: "CENTER" });
  const track = AL("HORIZONTAL", { fills: [P("#FFFFFF", 0.14)], cornerRadius: 1 }); track.resize(w, 2); track.layoutSizingHorizontal="FIXED"; track.layoutSizingVertical="FIXED";
  const bar = figma.createRectangle(); bar.resize(Math.round(w*frac), 2); bar.fills=[P(INK)]; track.appendChild(keep(bar));
  pr.appendChild(track); pr.appendChild(data(Math.round(frac*100)+"%", INK)); return pr;
}

// Tab strip, the same one Settings uses: labels with an underline under the active one, a rule beneath.
function tabStrip(content, labels, active) {
  const tabs = AL("HORIZONTAL", { itemSpacing: 24, name: "Tab strip" });
  for (const s of labels) {
    const on = s === active; const tcol = AL("VERTICAL", { itemSpacing: 10 }); const lbl = T(s, 14, on ? INK : INK2, { lh: 20 }); tcol.appendChild(lbl);
    const ul = figma.createRectangle(); ul.resize(lbl.width, 2); ul.fills = on ? [P(INK)] : []; ul.cornerRadius = 1; tcol.appendChild(keep(ul)); tabs.appendChild(tcol);
  }
  const strip = AL("VERTICAL", { itemSpacing: 0 }); strip.appendChild(tabs); hdivider(strip); content.appendChild(strip); fill(strip); return strip;
}
// Radio mark for a pick-one list.
function radio(on) { const w = AL("HORIZONTAL", { counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "CENTER", cornerRadius: 8, strokes: [P("#FFFFFF", on ? 1 : 0.35)], strokeWeight: 1.5, name: "radio" }); w.resize(16,16); w.layoutSizingHorizontal="FIXED"; w.layoutSizingVertical="FIXED"; if (on) { const d = figma.createEllipse(); d.resize(8,8); d.fills=[P(INK)]; w.appendChild(keep(d)); } return w; }
// Three aligned columns under a model name: languages, size, how the text arrives.
function facts(langs, size, delivery) { const r = AL("HORIZONTAL", { itemSpacing: 0 }); r.appendChild(T(langs, 13, INK2, { lh: 18, w: 180 })); r.appendChild(T(size, 13, INK2, { lh: 18, w: 90 })); r.appendChild(T(delivery, 13, INK2, { lh: 18 })); return r; }

// A card: glass, border, radius 8. Rows are appended with row().
function card(name="card") {
  const c = AL("VERTICAL", { cornerRadius: 8, fills: [GLASS], strokes: [EDGE], strokeWeight: 1, clipsContent: true, name });
  return c;
}
// Row: label (+caption) left, data + control right. last=true drops the divider.
function row(cardNode, label, o={}) {
  const r = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER", name: "row" }); pad(r, 0, 16); r.minHeight = 52;
  const left = AL("VERTICAL", { itemSpacing: 2 }); pad(left, 12, 0);
  left.appendChild(T(label, 14, o.labelColor || INK, { lh: 20 }));
  // The caption wraps inside the column, never wider than the app's caption measure (620) or captionW.
  if (o.caption) { const cp = caption(o.caption); left.appendChild(cp); fill(cp); cp.textAutoResize = "HEIGHT"; cp.maxWidth = o.captionW || 620; }
  r.appendChild(left); fill(left);
  if (o.data) r.appendChild(data(o.data));
  if (o.control) r.appendChild(o.control);
  cardNode.appendChild(r); fill(r);
  if (!o.last && o.divider !== false) hdivider(cardNode);
  return r;
}
function contentRow(cardNode, build, last=false) {
  const r = AL("HORIZONTAL", { itemSpacing: 12, counterAxisAlignItems: "CENTER", name: "row" }); pad(r, 12, 16);
  build(r); cardNode.appendChild(r); fill(r); if (!last) hdivider(cardNode); return r;
}
// Footer strip: hint left, buttons right. Pass it a parent card, or standalone=true to draw it on its own (for state strips).
function footer(cardNode, hint, buttons, standalone=false) {
  if (!standalone) hdivider(cardNode);
  const f = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "SPACE_BETWEEN", fills: [P("#000000", 0.35)], name: "footer" }); pad(f, 12, 16);
  if (standalone) { f.strokes = [EDGE]; f.strokeWeight = 1; f.cornerRadius = 8; f.fills = [GLASS]; }
  if (hint) { const c = caption(hint); f.appendChild(c); fill(c); } else { f.primaryAxisAlignItems = "MAX"; }
  if (buttons && buttons.length) { const acts = AL("HORIZONTAL", { itemSpacing: 8 }); buttons.forEach(b => acts.appendChild(b)); f.appendChild(acts); }
  if (cardNode) { cardNode.appendChild(f); fill(f); }
  return f;
}
function section(parent, label) { const s = AL("VERTICAL", { itemSpacing: 8, name: "section "+label }); s.appendChild(eyebrow(label)); parent.appendChild(s); fill(s); return s; }
function actions(...btns) { const a = AL("HORIZONTAL", { itemSpacing: 4 }); btns.forEach(b => a.appendChild(b)); return a; }

// Notes and state strips sit under a window, in the content column. Old ones in the same column are cleared first.
// Clears down to the next frame in the same column (the backlog row under 20, 21, 22), or to the end of the canvas.
function clearExtras(X, Y=0) {
  const below = figma.currentPage.children.filter(n => n.type === "FRAME" && !n.name.startsWith("state ") && n.y > Y && n.x < X + 1160 && n.x + n.width > X).map(n => n.y);
  const limit = below.length ? Math.min(...below) : Infinity;
  for (const n of [...figma.currentPage.children]) { if ((n.name.startsWith("note ") || n.name.startsWith("state ")) && n.x >= X && n.x < X + 1160 && n.y >= Y && n.y < limit) n.remove(); }
}
// The empty body of a list card: a line in ink, a centred caption, at most one button.
function emptyBody(cardNode, title, detail, btn) {
  const b = AL("VERTICAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER", name: "empty" }); pad(b, 48, 24);
  b.appendChild(T(title, 15, INK, { lh: 22 })); b.appendChild(caption(detail, 560, { center: true }));
  if (btn) b.appendChild(btn); cardNode.appendChild(b); fill(b); return b;
}
// The result of an action, where the action was: a green check (or a warning) and a few words in caption ink.
function statusLine(text, icon="checkmark", w) {
  const s = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER", name: "status line" }); s.minHeight = 32;
  s.appendChild(svgIcon(ICON[icon], 14, GREEN)); s.appendChild(T(text, 13, INK2, { lh: 18, w })); return s;
}
const NEXT_Y = {};
function nextY(win, h) { const y = NEXT_Y[win.id] || (win.y + win.height + 30); NEXT_Y[win.id] = y + h + 20; return y; }
function note(win, text) { const n = T(text, 13, DIM, { lh: 18, w: CONTENT_W }); n.name = "note " + text.slice(0, 40); n.x = win.x + CONTENT_X; n.y = nextY(win, n.height); return n; }
function stateStrip(win, label, build) {
  const wrap = AL("VERTICAL", { itemSpacing: 8, name: "state " + label }); wrap.x = win.x + CONTENT_X;
  wrap.resize(CONTENT_W, 10); wrap.layoutSizingHorizontal="FIXED"; wrap.layoutSizingVertical="HUG";
  wrap.appendChild(eyebrow(label)); build(wrap); wrap.y = nextY(win, wrap.height); return wrap;
}

// The window: painting, sidebar on the rail, content column with the title, subtitle and instrument.
// Reuses the frame whose name starts with the same number so comment pins stay attached; otherwise creates one.
const NAV = [["chip","Models"],["text--align--left","Transcriptions"],["book","Dictionary"],["text--short-paragraph","Snippets"],["magic-wand","Styles"],["settings","Settings"]];
function windowFrame(name, x, activeNav, title, subtitle, instrumentBuild, y=0) {
  const num = name.split(" ")[0];
  let win = figma.currentPage.children.find(n => n.type === "FRAME" && n.name.split(" ")[0] === num);
  if (win) { for (const ch of [...win.children]) ch.remove(); keep(win); }
  else { win = AL("HORIZONTAL"); figma.currentPage.appendChild(win); }
  win.name = name; win.cornerRadius = 11; win.clipsContent = true; win.strokes = [P("#FFFFFF", 0.14)]; win.strokeWeight = 1;
  win.resize(1160, 760); win.layoutSizingHorizontal="FIXED"; win.layoutSizingVertical="HUG"; win.minHeight = 760;
  win.fills = [{ type: "IMAGE", imageHash: IMAGE_HASH, scaleMode: "FILL" }, P("#000000", 0.58)];
  win.x = x; win.y = y;
  clearExtras(x, y);
  // sidebar
  const sb = AL("VERTICAL", { fills: [RAIL], name: "Sidebar" }); sb.resize(220, 760); sb.layoutSizingHorizontal="FIXED";
  const lights = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER" }); pad(lights, 0, 20); lights.resize(220, 52); lights.layoutSizingVertical="FIXED"; lights.layoutSizingHorizontal="FIXED";
  for (const c of ["#FF5F57","#FEBC2E","#28C840"]) { const e = figma.createEllipse(); e.resize(12,12); e.fills=[P(c)]; lights.appendChild(keep(e)); }
  sb.appendChild(lights);
  const wm = AL("HORIZONTAL", { itemSpacing: 0, counterAxisAlignItems: "BASELINE", name: "Wordmark" }); pad(wm, 6, 20, 20, 20);
  wm.appendChild(T("Sigma", 28, INK, { lh: 32 })); wm.appendChild(T("flow", 28, INK, { lh: 32, font: FONT_ACCENT })); sb.appendChild(wm);
  const nav = AL("VERTICAL", { itemSpacing: 8, name: "Nav" }); pad(nav, 0, 10);
  for (const [icon, label] of NAV) {
    const on = label === activeNav;
    const item = AL("HORIZONTAL", { itemSpacing: 12, counterAxisAlignItems: "CENTER", cornerRadius: 6, name: "nav "+label }); pad(item, 0, 12); item.resize(200, 38); item.layoutSizingVertical="FIXED";
    if (on) item.fills = [P("#FFFFFF", 0.10)];
    item.appendChild(svgIcon(ICON[icon], 15, on ? INK : INK2)); item.appendChild(T(label, 14, INK, { lh: 20 }));
    nav.appendChild(item); fill(item);
  }
  sb.appendChild(nav); fill(nav);
  const spacer = AL("VERTICAL"); sb.appendChild(spacer); fill(spacer); spacer.layoutSizingVertical = "FILL";
  const ver = AL("HORIZONTAL"); pad(ver, 14, 20); ver.appendChild(data("1.0.0", DIM)); sb.appendChild(ver);
  win.appendChild(sb); sb.layoutSizingVertical = "FILL";
  const edge = divider(); edge.resize(1, 760); win.appendChild(edge); edge.layoutSizingVertical = "FILL";
  // content
  const content = AL("VERTICAL", { itemSpacing: 28, name: "Content" }); pad(content, 24, 28, 40, 28);
  win.appendChild(content); fill(content);
  if (title !== null) {
    const head = AL("HORIZONTAL", { itemSpacing: 24, counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "SPACE_BETWEEN", name: "Header" });
    const tl = AL("VERTICAL", { itemSpacing: 8, name: "Title block" });
    tl.appendChild(T(title, 22, INK, { lh: 28 }));
    if (subtitle) tl.appendChild(T(subtitle, 14, INK2, { lh: 20, w: SUBTITLE_W }));
    head.appendChild(tl); fill(tl);
    if (instrumentBuild) instrumentBuild(head);
    content.appendChild(head); fill(head);
  }
  return { win, content };
}
