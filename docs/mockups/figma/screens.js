// ---- Screen builders, evaluated after prelude.js. X is the window's x on the canvas (1300 apart).
// Canvas: 20 @0, 21 @1300, 22 @2600, 23 @3900, 23B @5200, 23C @6500, 24 @7800, 24B @9100, 27 @10400, 27B @11700, 27C @13000, 28 HUD @14300 (1560 wide).
// Redrawn 11 Oct 2026 against the app on main (bc37ee3): each window compared with its --snapshot-dir render, and every
// state the code can reach drawn as a strip under its window. Sample words stand in for real dictations.
// Meetings (25, 26) were deleted from the file on 10 Oct 2026 at Gokul's request.
// A copy of this file lives in the Figma file as the hidden text node __screens__; keep both identical.

const NB = String.fromCharCode(160), NL = String.fromCharCode(10);

function searchBox(placeholder, typed) {
  const s = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER", cornerRadius: 6, fills: [FILL], strokes: [EDGE], strokeWeight: 1, name: "search" });
  pad(s, 0, 12); s.resize(360, 32); s.layoutSizingHorizontal="FIXED"; s.layoutSizingVertical="FIXED";
  s.appendChild(svgIcon(ICON.search, 14, DIM));
  const t = T(typed || placeholder, 14, typed ? INK : PLACE, { lh: 20 }); s.appendChild(t);
  if (typed) { fill(t); s.appendChild(svgIcon(ICON.close, 12, INK2)); }
  return s;
}
function toolbar(content, placeholder, count, typed) {
  const tb = AL("HORIZONTAL", { primaryAxisAlignItems: "SPACE_BETWEEN", counterAxisAlignItems: "CENTER", name: "toolbar" });
  tb.appendChild(searchBox(placeholder, typed)); tb.appendChild(data(count)); content.appendChild(tb); fill(tb); return tb;
}
// Gokul's wording for the two-field editors on Dictionary and Snippets.
const SAY = "When I say this", TYPE = "SigmaFlow should type";
function labeled(parent, label, box) { const l = AL("VERTICAL", { itemSpacing: 6 }); l.appendChild(eyebrow(label)); l.appendChild(box); parent.appendChild(l); fill(l); fill(box); return l; }

// ===== 20 Transcriptions =====
const TX_SUB = "Everything you have dictated, newest first. Search it, copy a line back out, or delete what you no longer need.";
function txRows(c) {
  const dayLabel = (txt) => { const d = AL("HORIZONTAL"); pad(d, 12, 16, 8, 16); d.appendChild(eyebrow(txt)); c.appendChild(d); fill(d); };
  const trow = (text, meta, corr, copied, last) => {
    const r = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER" }); pad(r, 12, 16);
    const left = AL("VERTICAL", { itemSpacing: 4 });
    left.appendChild(T(text, 15, INK, { lh: 22, w: 640 }));
    const m = AL("HORIZONTAL", { itemSpacing: 16 }); m.appendChild(data(meta[0])); m.appendChild(data(meta[1])); left.appendChild(m);
    if (corr) { const cr = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER" }); cr.appendChild(eyebrow("Corrected")); cr.appendChild(T(corr[0], 13, INK2, { lh: 18, strike: true })); cr.appendChild(T(corr[1], 13, INK2, { lh: 18 })); left.appendChild(cr); }
    r.appendChild(left); fill(left);
    const copyBtn = copied ? button("Copied", "tertiary", "checkmark") : button("Copy", "tertiary", "copy");
    r.appendChild(actions(copyBtn, button("Delete","tertiary","trash-can")));
    c.appendChild(r); fill(r); if (!last) hdivider(c);
  };
  dayLabel("Today");
  trow("Hey, can you send me the deck before the stand-up tomorrow, and loop in Priya from the design team as well.", ["11:42", "Parakeet Unified EN"]);
  trow("Reminder to check the SigmaFlow build before the demo.", ["10:05", "Parakeet Unified EN"], ["sigma flo", "SigmaFlow"], true);
  dayLabel("Yesterday");
  trow("Draft a reply to Arun about the Zoho Cliq integration timeline and ask for the API docs.", ["18:20", "Parakeet Unified EN"], ["zoho click", "Zoho Cliq"]);
  trow("Okay so the three things for today are the onboarding flow, the notarization and the release notes.", ["09:14", "Apple"], null, false, true);
}
function screen_transcriptions(X) {
  const { win, content } = windowFrame("20 Transcriptions", X, "Transcriptions", "Transcriptions", TX_SUB);
  toolbar(content, "Search transcriptions", "2,625 recordings");
  const c = card("Transcriptions"); content.appendChild(c); fill(c);
  txRows(c);
  footer(c, null, [button("Delete all")]);
  note(win, "Matches the app. Row 2 shows Copy right after a press: Copied with a tick for 1.5 s (DS.Motion.statusHold), then back to Copy. No toast. Days before yesterday are labelled by date, 8 OCTOBER, with the year added for an earlier year.");
  stateStrip(win, "Footer after Delete all is pressed", (w) => {
    const f = footer(null, "Delete all 2,625 transcriptions from this Mac? They cannot be recovered.", [button("Delete all 2,625", "inverted"), button("Cancel", "tertiary")], true);
    w.appendChild(f); fill(f);
  });
  note(win, "Nothing is deleted on the first press. Cancel or Esc puts the footer back. Deleting one row needs no confirmation; the list closes the gap over 0.15 s (DS.Motion.panel).");
  stateStrip(win, "Empty, before the first dictation", (w) => {
    toolbar(w, "Search transcriptions", "0 recordings");
    const k = card("empty"); w.appendChild(k); fill(k);
    emptyBody(k, "Nothing here yet", "Hold Right ⌘ in any app and talk. When you let go, your words land where your cursor is, and a copy is kept here.");
  });
  note(win, "The key named in the sentence is whichever push-to-talk key is set. With nothing recorded the footer and Delete all are gone.");
  stateStrip(win, "Search with no match", (w) => {
    toolbar(w, "Search transcriptions", "2,625 recordings", "invoice for march");
    const k = card("no match"); w.appendChild(k); fill(k);
    emptyBody(k, "Nothing matches that search", "Try fewer words, or a different spelling.");
    footer(k, null, [button("Delete all")]);
  });
  note(win, "The list filters as you type and the cross clears the search. The count stays the total.");
}
// ===== 21 Dictionary =====
function dictEditor(c, hear, write, editing) {
  const ed = AL("VERTICAL", { itemSpacing: 12, fills: [P("#FFFFFF", 0.03)], name: "editor row" }); pad(ed, 16);
  const fr = AL("HORIZONTAL", { itemSpacing: 16 });
  labeled(fr, SAY, field(hear || "sigma flo", 300, !hear));
  labeled(fr, TYPE, field(write || "SigmaFlow", 300, !write));
  ed.appendChild(fr); fill(fr);
  ed.appendChild(actions(button(editing ? "Save dictionary word" : "Add dictionary word", "secondary", null, null, !write), button("Cancel","tertiary")));
  c.appendChild(ed); fill(ed); hdivider(c);
}
function drow(c, hear, write) {
  const r = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER" }); pad(r, 0, 16); r.resize(100, 52); r.layoutSizingVertical="FIXED";
  r.appendChild(T(hear, 14, INK2, { lh: 20, w: 300 }));
  const w = T(write, 14, INK, { lh: 20 }); r.appendChild(w); fill(w); w.textAutoResize = "HEIGHT";
  r.appendChild(actions(button("Edit","tertiary","edit"), button("Delete","tertiary","trash-can"))); c.appendChild(r); fill(r); hdivider(c);
}
function learnFooter(c, on) {
  const lr = row(c, "Learn from my corrections", { caption: "When you edit a word after SigmaFlow transcribes it, the correction is recorded here so the next transcriptions get that word right.", captionW: 700, control: toggle(on), last: true });
  lr.fills = [P("#000000", 0.35)]; return lr;
}
function screen_dictionary(X) {
  const { win, content } = windowFrame("21 Dictionary", X, "Dictionary", "Dictionary",
    "Names, products and terms the engines mishear, each with the spelling you want typed.");
  toolbar(content, "Search entries", "18 entries");
  const c = card("Dictionary"); content.appendChild(c); fill(c);
  dictEditor(c);
  drow(c, "sigma flo","SigmaFlow"); drow(c, "zoho click","Zoho Cliq"); drow(c, "any spelling","Priya"); drow(c, "clode","Claude"); drow(c, "any spelling","Parakeet");
  learnFooter(c, true);
  note(win, "Matches the app. Add dictionary word waits at 35% until the right-hand box has text; the grey words in the boxes are hints, not entries. Leave When I say this empty and the word is saved as a plain term, listed as any spelling.");
  stateStrip(win, "Editing a word", (w) => {
    const k = card("editing"); w.appendChild(k); fill(k);
    dictEditor(k, "zoho click", "Zoho Cliq", true);
    drow(k, "sigma flo", "SigmaFlow"); drow(k, "zoho click", "Zoho Cliq");
    learnFooter(k, true);
  });
  note(win, "Edit loads the row into the editor and the button reads Save dictionary word. Cancel or Esc empties the editor; deleting the row being edited empties it too.");
  stateStrip(win, "Empty, before the first word", (w) => {
    toolbar(w, "Search entries", "0 entries");
    const k = card("empty"); w.appendChild(k); fill(k);
    dictEditor(k);
    emptyBody(k, "No words yet", "Add the first one above. When you fix a word right after SigmaFlow types it, it is added here for you.");
    learnFooter(k, true);
  });
  stateStrip(win, "Search with no match", (w) => {
    toolbar(w, "Search entries", "18 entries", "kubernetes");
    const k = card("no match"); w.appendChild(k); fill(k);
    dictEditor(k);
    emptyBody(k, "Nothing matches that search", "Try fewer letters, or the other spelling.");
    learnFooter(k, true);
  });
  stateStrip(win, "Learning switched off", (w) => { const k = card("learning off"); w.appendChild(k); fill(k); learnFooter(k, false); });
  note(win, "Off, SigmaFlow stops offering the words you fix; the rules already here keep working. On, a fixed word shows the notice on window 28 and is added unless you press Not now.");
}
// ===== 22 Snippets =====
function snipEditor(c, trig, text, o={}) {
  const ed = AL("VERTICAL", { itemSpacing: 12, fills: [P("#FFFFFF", 0.03)], name: "editor row" }); pad(ed, 16);
  const fr = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "MIN" });
  labeled(fr, SAY, textarea(trig || "A short phrase, two words or more. Like “my work email”.", 400, 84, !trig));
  labeled(fr, TYPE, textarea(text || "The text to insert, as many lines as you need.", 400, o.h || 84, !text, (text ? text.length : 0).toLocaleString("en-US") + " / 2,000", !!o.scroll));
  ed.appendChild(fr); fill(fr);
  ed.appendChild(actions(button(o.editing ? "Save snippet" : "Add snippet", "secondary", null, null, !(trig && text)), button("Cancel","tertiary")));
  c.appendChild(ed); fill(ed); return ed;
}
function srow(c, trig, text, last) {
  const r = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER" }); pad(r, 0, 16); r.resize(100, 52); r.layoutSizingVertical="FIXED";
  r.appendChild(T("“" + trig + "”", 14, INK, { lh: 20, w: 300 }));
  const tx = T(text, 14, INK2, { lh: 20 }); r.appendChild(tx); fill(tx); tx.textAutoResize = "HEIGHT";
  r.appendChild(actions(button("Edit","tertiary","edit"), button("Delete","tertiary","trash-can"))); c.appendChild(r); fill(r); if (!last) hdivider(c);
}
const SNIP_SUB = "Say a short phrase, get a saved block of text. Good for addresses, links and sign-offs you type every day.";
function screen_snippets(X) {
  const { win, content } = windowFrame("22 Snippets", X, "Snippets", "Snippets", SNIP_SUB);
  const c = card("Snippets"); content.appendChild(c); fill(c);
  snipEditor(c); hdivider(c);
  srow(c, "my linkedin profile", "https://www.linkedin.com/in/yourname/"); srow(c, "my work email", "name@example.com", true);
  note(win, "Matches the app. Add snippet waits at 35% until both boxes have text. The right box stops at 2,000 characters; typing or pasting past that is cut off there. A phrase is one line, so Return in the left box adds nothing. A row shows the first line of its text.");
  const LONG = ["Thanks for reaching out. I have added the details below and copied the team so nothing gets lost between us. If anything here is unclear, reply to this thread and I will pick it up the same day. For anything urgent, please call the office line rather than waiting on email.", "", "Best regards,", "Name Surname", "Title, Company", "Office hours 9 to 6 IST"].join(NL);
  stateStrip(win, "Editor with a long snippet", (w) => {
    const k = card("long snippet"); w.appendChild(k); fill(k);
    snipEditor(k, "my email signature", LONG, { h: 168, scroll: true });
  });
  note(win, "The box grows with the text from four lines to about six (84 to 168 px), then keeps its height and scrolls inside. The counter floats over the text on a dark backing.");
  stateStrip(win, "Editing a snippet", (w) => {
    const k = card("editing"); w.appendChild(k); fill(k);
    snipEditor(k, "my work email", "name@example.com", { editing: true }); hdivider(k);
    srow(k, "my linkedin profile", "https://www.linkedin.com/in/yourname/"); srow(k, "my work email", "name@example.com", true);
  });
  stateStrip(win, "Empty, before the first snippet", (w) => {
    const k = card("empty"); w.appendChild(k); fill(k);
    snipEditor(k); hdivider(k);
    emptyBody(k, "No snippets yet", "Your email address is a good first one. Say its phrase while you dictate and the full text lands in its place.");
  });
  note(win, "Edit loads a snippet into the editor and the button reads Save snippet. Cancel or Esc empties it.");
}
// ===== 23 Styles: Default styles (tiles, no key) and Custom styles (shortcut rewrites), one window per state =====
const STYLES_SUB = "A default style shapes every dictation you type. Custom styles rewrite selected text in a voice you define, each with its own shortcut.";
const STYLE_TABS = ["Default styles", "Custom styles"];
const newStyleHeader = (h) => h.appendChild(button("New style", "secondary", "add"));
function styleTile(name, sub, example, on) {
  const t = AL("VERTICAL", { itemSpacing: 12, cornerRadius: 8, fills: [on ? P("#FFFFFF", 0.08) : GLASS], strokes: [on ? P(INK) : EDGE], strokeWeight: on ? 1.5 : 1, name: "tile " + name }); pad(t, 20);
  t.appendChild(T(name, 20, INK, { lh: 26 }));
  t.appendChild(caption(sub));
  const b = AL("HORIZONTAL", { cornerRadius: 8, fills: [P("#FFFFFF", 0.06)], name: "example" }); pad(b, 10, 12);
  const ex = T("“" + example + "”", 14, INK, { lh: 20 }); b.appendChild(ex); ex.textAutoResize = "HEIGHT"; ex.layoutSizingHorizontal = "FILL"; t.appendChild(b); fill(b);
  if (on) { const m = AL("HORIZONTAL", { itemSpacing: 6, counterAxisAlignItems: "CENTER" }); m.appendChild(svgIcon(ICON.checkmark, 12, INK)); m.appendChild(eyebrow("Selected", INK)); t.appendChild(m); }
  return t;
}
const DEFAULT_TILES = [
  ["Formal", "Capitals and full punctuation", "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.", false],
  ["Casual", "Capitals, lighter punctuation", "Hey are you free for lunch tomorrow? Let's do 12 if that works for you", true],
  ["Retarded", "No capitals, lighter punctuation", "hey are you free for lunch tomorrow? let's do 12 if that works for you", false],
];
function screen_styles(X) {
  const { win, content } = windowFrame("23 Styles, default styles", X, "Styles", "Styles", STYLES_SUB);
  tabStrip(content, STYLE_TABS, "Default styles");
  const tiles = AL("HORIZONTAL", { itemSpacing: 16, name: "tiles" });
  for (const [n, s, e, on] of DEFAULT_TILES) { const t = styleTile(n, s, e, on); tiles.appendChild(t); fill(t); t.layoutSizingVertical = "FILL"; }
  content.appendChild(tiles); tiles.resize(CONTENT_W, 334); fill(tiles); tiles.layoutSizingVertical = "FIXED";
  content.appendChild(caption("The default style shapes every dictation, in every app. It needs no account and no key.", 720));
  note(win, "Matches the app. One tile is always selected, Casual to start; clicking anywhere on a tile selects it, at once, with no animation. The three differ only in capitals and punctuation, run before the Dictionary, and are skipped when Clean up is Off.");
}
// The engine rows and the custom style tiles are shared by the two Custom windows.
function engineRow(c, on, name, blurb, extra, last) {
  const r = AL("VERTICAL", { itemSpacing: 12 }); pad(r, 14, 16); if (on) r.fills = [P("#FFFFFF", 0.03)];
  const top = AL("HORIZONTAL", { itemSpacing: 14, counterAxisAlignItems: "MIN" });
  top.appendChild(radio(on));
  const tx = AL("VERTICAL", { itemSpacing: 4 }); tx.appendChild(T(name, 14, INK, { lh: 20 })); tx.appendChild(caption(blurb, 640)); top.appendChild(tx); fill(tx);
  r.appendChild(top); fill(top);
  if (extra) { const ex = AL("HORIZONTAL", { itemSpacing: 12, counterAxisAlignItems: "CENTER" }); pad(ex, 0, 0, 0, 30); extra(ex); r.appendChild(ex); fill(ex); }
  c.appendChild(r); fill(r); if (!last) hdivider(c);
}
const keyField = (prompt) => (ex) => { ex.appendChild(field(prompt, 360)); ex.appendChild(button("Save key", "secondary", null, null, true)); };
function engineChooser(c, chosen) {
  engineRow(c, chosen === "apple", "Apple Intelligence", "On this Mac, free, no key. Needs an M-series Mac with Apple Intelligence turned on. Best for short texts.");
  engineRow(c, chosen === "claude", "Claude", "Anthropic's model with your own API key. The best rewrites; you pay Anthropic per use.", chosen === "claude" ? keyField("Paste your Anthropic API key") : null);
  engineRow(c, chosen === "openrouter", "OpenRouter, free models", "Your own OpenRouter key, free models only. Quality varies by model.", chosen === "openrouter" ? keyField("Paste your OpenRouter API key") : null, true);
}
function customTile(name, key, line, editing) {
  const t = AL("VERTICAL", { itemSpacing: 12, cornerRadius: 8, fills: [editing ? P("#FFFFFF", 0.08) : GLASS], strokes: [editing ? P(INK) : EDGE], strokeWeight: editing ? 1.5 : 1, primaryAxisAlignItems: "SPACE_BETWEEN", name: "tile " + name }); pad(t, 20);
  const top = AL("VERTICAL", { itemSpacing: 10 });
  const nm = AL("HORIZONTAL", { itemSpacing: 10, counterAxisAlignItems: "CENTER" }); nm.appendChild(T(name, 20, INK, { lh: 26 })); nm.appendChild(chip(key)); top.appendChild(nm);
  const ln = caption(line); top.appendChild(ln); ln.layoutSizingHorizontal = "FILL"; ln.textAutoResize = "HEIGHT";
  t.appendChild(top); fill(top);
  t.appendChild(actions(button("Edit", "tertiary", "edit"), button("Delete", "tertiary", "trash-can")));
  return t;
}
const CUSTOM_TILES = [
  ["Clean", "⌥1", "Fix spelling, grammar and punctuation. Keep my words and my order.", false],
  ["Boss mode", "⌥2", "Rewrite as short, direct messages. Lead with the ask.", true],
  ["Friendly", "⌥3", "Warm and casual. First names, short sentences, one exclamation mark at most.", false],
  ["Status update", "⌥4", "Turn my notes into a three-line status update: done, next, blocked.", false],
];
// Three columns; a fourth style starts a second row, the empty slots keep the columns.
function customGrid(content, tiles) {
  const grid = AL("VERTICAL", { itemSpacing: 16, name: "custom tiles" }); content.appendChild(grid); fill(grid);
  for (let i = 0; i < tiles.length; i += 3) {
    const r = AL("HORIZONTAL", { itemSpacing: 16 }); r.resize(CONTENT_W, 200); grid.appendChild(r); fill(r); r.layoutSizingVertical = "FIXED";
    for (let j = 0; j < 3; j++) { const d = tiles[i + j]; const t = d ? customTile(d[0], d[1], d[2], d[3]) : AL("VERTICAL", { name: "empty slot" }); r.appendChild(t); fill(t); t.layoutSizingVertical = "FILL"; }
  }
  return grid;
}
function styleEditor(parent, o) {
  const c = card("Editor"); parent.appendChild(c); fill(c);
  const ed = AL("VERTICAL", { itemSpacing: 16, name: "editor" }); pad(ed, 16);
  ed.appendChild(eyebrow(o.isNew ? "New style" : "Editing " + o.name));
  const r1 = AL("HORIZONTAL", { itemSpacing: 16 });
  const a = AL("VERTICAL", { itemSpacing: 6 }); a.appendChild(eyebrow("Name")); a.appendChild(field(o.name || "Boss mode", 300, !o.name)); r1.appendChild(a);
  const b = AL("VERTICAL", { itemSpacing: 6 }); b.appendChild(eyebrow("Shortcut")); b.appendChild(popup("⌥ " + o.key, 120)); r1.appendChild(b);
  ed.appendChild(r1); fill(r1);
  const i = AL("VERTICAL", { itemSpacing: 6 }); i.appendChild(eyebrow("Instructions"));
  i.appendChild(caption("Brief SigmaFlow the way you would brief a person. When you press ⌥" + o.key + " on selected text, it rewrites that text by these instructions and pastes the result back. The first line is what the tile shows.", 800));
  const ta = textarea(o.lines ? o.lines.join(NL) : "Rewrite as short, direct messages. Lead with the ask.", 400, 120, !o.lines); i.appendChild(ta); ed.appendChild(i); fill(i); fill(ta);
  ed.appendChild(actions(button("Save style", "secondary", null, null, !(o.name && o.lines)), button("Cancel","tertiary")));
  c.appendChild(ed); fill(ed); return c;
}
function screen_styles_custom(X) {
  const { win, content } = windowFrame("23B Styles, custom styles", X, "Styles", "Styles", STYLES_SUB, newStyleHeader);
  tabStrip(content, STYLE_TABS, "Custom styles");
  const e = card("Rewrite engine"); content.appendChild(e); fill(e);
  row(e, "Rewrites run on Claude", { caption: "Your Anthropic key is saved in the Mac's Keychain.", control: actions(button("Change engine", "tertiary"), button("Change key", "tertiary")), last: true });
  customGrid(content, CUSTOM_TILES);
  styleEditor(content, { name: "Boss mode", key: "2", lines: ["Rewrite as short, direct messages. Lead with the ask.", "Cut softeners: just, I think, maybe, if possible.", "One idea per sentence. No exclamation marks.", "Keep my facts, names and numbers exactly as written."] });
  note(win, "Matches the app with four styles: three columns, the fourth starts a second row. Edit outlines its tile and opens the editor under the grid; Esc or Cancel closes it. A tile shows at most three lines of the first instruction. The instructions box grows from 120 to 240 px, then scrolls.");
  stateStrip(win, "New style", (w) => styleEditor(w, { isNew: true, key: "5" }));
  note(win, "New style opens a blank editor on the next free shortcut. Save style waits at 35% until there is a name and an instruction. The shortcut popup lists only the free keys.");
  stateStrip(win, "Rewrite engine set to Apple Intelligence", (w) => {
    const k = card("engine apple"); w.appendChild(k); fill(k);
    row(k, "Rewrites run on Apple Intelligence", { caption: "On this Mac, free, no key.", control: actions(button("Change engine", "tertiary")), last: true });
  });
  stateStrip(win, "All five shortcuts in use", (w) => { const r = AL("HORIZONTAL", { primaryAxisAlignItems: "MAX" }); r.appendChild(button("New style", "secondary", "add", null, true)); w.appendChild(r); fill(r); });
  note(win, "With ⌥1 to ⌥5 all taken, New style waits at 35%. Change engine and Change key open the three-row chooser from window 23C in place of the summary. OpenRouter reads: Your OpenRouter key is saved in the Mac's Keychain.");
}
function screen_styles_custom_empty(X) {
  const { win, content } = windowFrame("23C Styles, custom styles, first visit", X, "Styles", "Styles", STYLES_SUB, newStyleHeader);
  tabStrip(content, STYLE_TABS, "Custom styles");
  const e = card("Rewrite engine"); content.appendChild(e); fill(e);
  engineChooser(e, "claude");
  const c = card("Custom styles, empty"); content.appendChild(c); fill(c);
  emptyBody(c, "No custom styles yet", "Pick an engine above and add its key. Then press New style to start blank, or add three starters you can edit or delete: Clean, Boss mode and Friendly.", button("Add the three starters"));
  note(win, "Matches the app. The chooser shows when there are no styles yet, or the chosen cloud engine has no key. Save key waits at 35% until a key is pasted; it stores the key in the Keychain and closes the chooser. Choosing Apple Intelligence closes it at once. Add the three starters fills the grid over 0.15 s (DS.Motion.panel).");
  stateStrip(win, "OpenRouter chosen", (w) => { const k = card("engine openrouter"); w.appendChild(k); fill(k); engineChooser(k, "openrouter"); });
}
// ===== 24 Models =====
const MODEL = {
  uen:  ["Parakeet Unified EN", "The most accurate English, with punctuation and capitalization built in.", "English only", "697 MB", "Live as you speak", 5, 4],
  apple:["Apple", "Built into macOS. Nothing to download.", "macOS system languages", "0 MB", "Live as you speak", 3, 5],
  v3:   ["Parakeet V3", "Fast and accurate across European languages.", "25 languages", "456 MB", "Text after you release", 4, 4],
  nemo: ["Nemotron Streaming 3.5", "Live multilingual transcription. Detects the language on its own.", "100+ languages", "716 MB", "Live as you speak", 4, 4],
  p110: ["Parakeet 110M", "Tiny and quick. A good fit when disk space matters.", "English only", "160 MB", "Text after you release", 2, 5],
  cohere:["Cohere Transcribe", "The accuracy ceiling. Slower, and a big download.", "14 languages", "1.6 GB", "Text after you release", 5, 2],
};
const STATE = {
  active:   (s) => s.appendChild(tag("Active")),
  use:      (s) => s.appendChild(button("Use", "secondary", null, 72)),
  useDel:   (s) => { s.appendChild(button("", "tertiary", "trash-can")); s.appendChild(button("Use", "secondary", null, 72)); },
  download: (s) => s.appendChild(button("Download", "secondary", "download")),
  loading:  (s) => { s.appendChild(button("", "tertiary", "close")); s.appendChild(progress(0.42, 92)); },
};
function modelRow(c, key, state, last, failMsg) {
  const m = MODEL[key];
  const r = AL("HORIZONTAL", { itemSpacing: 24, counterAxisAlignItems: "CENTER" }); pad(r, 12, 16);
  const left = AL("VERTICAL", { itemSpacing: 4 }); left.appendChild(T(m[0], 14, INK, { lh: 20 })); left.appendChild(caption(m[1], 420)); left.appendChild(facts(m[2], m[3], m[4]));
  if (failMsg) left.appendChild(T(failMsg, 13, INK, { lh: 18 }));
  r.appendChild(left); fill(left);
  r.appendChild(gauges(m[5], m[6]));
  const slot = AL("HORIZONTAL", { itemSpacing: 4, counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "MAX", name: "action slot" }); slot.resize(176, 32); slot.layoutSizingHorizontal="FIXED"; slot.layoutSizingVertical="FIXED";
  STATE[state](slot); r.appendChild(slot);
  c.appendChild(r); fill(r); if (!last) hdivider(c);
}
const MODEL_TABS = ["English only", "Multilingual"];
function modelsWindow(name, X, view, rows) {
  const { win, content } = windowFrame(name, X, "Models", "Models",
    "The engine that turns your voice into text. Every engine runs on this Mac; nothing you say leaves it.");
  tabStrip(content, MODEL_TABS, view);
  const c = card("Models"); content.appendChild(c); fill(c);
  rows.forEach(([key, state], i) => modelRow(c, key, state, i === rows.length - 1));
  return win;
}
function screen_models_english(X) {
  const win = modelsWindow("24 Models, English only", X, "English only", [["uen","active"],["p110","download"]]);
  note(win, "Matches the app. A model never changes tabs; active, installed, downloading and not yet downloaded all sit in the same 176 px column at the right. Below the 1,160 window width the three facts stack instead of holding their columns.");
}
function screen_models_multilingual(X) {
  const win = modelsWindow("24B Models, Multilingual", X, "Multilingual", [["apple","use"],["v3","useDel"],["nemo","download"],["cohere","useDel"]]);
  note(win, "Matches the app as installed today: Parakeet V3 and Cohere downloaded, Nemotron not. Apple is built in, so it has Use and no delete.");
  stateStrip(win, "Downloading", (w) => { const k = card("downloading"); w.appendChild(k); fill(k); modelRow(k, "nemo", "loading", true); });
  note(win, "The cross cancels. When the download lands, the progress line becomes Use in the same spot.");
  stateStrip(win, "Download failed", (w) => { const k = card("failed"); w.appendChild(k); fill(k); modelRow(k, "nemo", "download", true, "The network connection was lost."); });
  note(win, "The reason shows in ink under the facts and Download comes back, so trying again is the same press.");
}
// ===== The overlay card, shared by window 28 and the Overlay tiles on window 27 =====
// HUDView: 440 wide, 18 across and 14 down, radius 12, tint #101010 at 62% over a 24 px blur, a 20% edge, shadow 0 12 32 at 55%.
const HUD_GLASS = P("#101010", 0.62), HUD_EDGE = P("#FFFFFF", 0.20);
const HUD_FX = [{ type: "BACKGROUND_BLUR", radius: 24, visible: true }, { type: "DROP_SHADOW", color: { r: 0, g: 0, b: 0, a: 0.55 }, offset: { x: 0, y: 12 }, radius: 32, spread: 0, visible: true, blendMode: "NORMAL" }];
function lockMark() {
  const n = figma.createNodeFromSvg('<svg width="12" height="12" viewBox="0 0 12 12"><path d="M2.88 4.08A3.12 3.12 0 0 1 9.12 4.08" stroke="#EDEDED" stroke-width="1.4" fill="none"/><rect x="1.2" y="5.76" width="9.6" height="6.24" rx="2" fill="#EDEDED"/></svg>');
  n.fills = []; n.name = "lock"; return keep(n);
}
// A steady dot, a lock, a static dashed ring, a warning. None of them move.
function hudGlyph(kind) {
  if (kind === "lock") return lockMark();
  if (kind === "busy") return svgIcon(ICON["circle-dash"], 12, INK);
  if (kind === "warning") return svgIcon(ICON.warning, 12, INK);
  const w = AL("HORIZONTAL", { counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "CENTER", name: "dot" }); w.resize(12, 12);
  const d = figma.createEllipse(); d.resize(8, 8); d.fills = [P(INK)]; w.appendChild(keep(d)); return w;
}
// Words as WordFlowText lays them: one node per word, 14 px, 4 apart, 3 between lines.
// fade: how many of the last words are still blurring in. wait: the index of a word laid out but held back (Make room).
function flowWords(text, color, o={}) {
  const f = AL("HORIZONTAL", { itemSpacing: 4, name: "words" }); f.resize(404, 18); f.layoutWrap = "WRAP"; f.counterAxisSpacing = 3; f.counterAxisSizingMode = "AUTO";
  const words = text.split(" ");
  words.forEach((w, i) => {
    const t = T(w, 14, color, { lh: 18 }); f.appendChild(t);
    const back = words.length - 1 - i;
    if (o.fade && back < o.fade) { const p = (o.fade - back) / (o.fade + 1); t.opacity = 1 - p; t.effects = [{ type: "LAYER_BLUR", radius: Math.max(1, Math.round(p * 3)), visible: true }]; }
    if (o.wait != null && i >= o.wait) t.opacity = i === o.wait ? 0.12 : 0;
  });
  return f;
}
// o: glyph, label, timer (null for a style rewrite), dim (processing), lit (meter dots), flow (live words), words (a plain 15 px line), wordsColor
function hudCard(o) {
  const c = AL("VERTICAL", { itemSpacing: 10, cornerRadius: 12, fills: [HUD_GLASS], strokes: [HUD_EDGE], strokeWeight: 1, name: "overlay " + o.label });
  pad(c, 14, 18); c.resize(440, 40); c.counterAxisSizingMode = "FIXED"; c.primaryAxisSizingMode = "AUTO"; c.effects = HUD_FX;
  const sr = AL("HORIZONTAL", { itemSpacing: 14, counterAxisAlignItems: "CENTER", name: "status row" });
  const gl = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER" }); gl.appendChild(hudGlyph(o.glyph || "dot")); gl.appendChild(eyebrow(o.label, INK)); sr.appendChild(gl);
  if (o.timer) { sr.appendChild(data(o.timer, o.dim ? DIM : INK2)); sr.appendChild(meter(o.lit || 0)); }
  c.appendChild(sr); fill(sr);
  if (o.flow) { const w = flowWords(o.flow, o.dim ? INK2 : INK, o); c.appendChild(w); fill(w); }
  else if (o.words) c.appendChild(T(o.words, 15, o.wordsColor || INK, { lh: 22, w: 404 }));
  return c;
}
// The correction notice (CorrectionNoticePanel): same glass, 16 all round. stage: adding, added, undone. frac: bar left.
function noticeCard(stage, spoken, written, frac) {
  const c = AL("VERTICAL", { itemSpacing: 12, cornerRadius: 12, fills: [HUD_GLASS], strokes: [HUD_EDGE], strokeWeight: 1, name: "notice " + stage });
  pad(c, 16); c.resize(440, 40); c.counterAxisSizingMode = "FIXED"; c.primaryAxisSizingMode = "AUTO"; c.effects = HUD_FX;
  const top = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER" });
  const l = AL("VERTICAL", { itemSpacing: 6 });
  if (stage === "added") { const h = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "CENTER" }); h.appendChild(svgIcon(ICON.checkmark, 12, INK)); h.appendChild(eyebrow("Added to dictionary", INK)); l.appendChild(h); }
  else l.appendChild(stage === "undone" ? eyebrow("Not added", INK) : eyebrow("Adding to dictionary"));
  const pr = AL("HORIZONTAL", { itemSpacing: 10, counterAxisAlignItems: "CENTER" });
  pr.appendChild(T(spoken, 15, INK2, { lh: 22, strike: true })); pr.appendChild(svgIcon(ICON["arrow--right"], 12, INK2)); pr.appendChild(T(written, 15, stage === "undone" ? INK2 : INK, { lh: 22 }));
  l.appendChild(pr); top.appendChild(l); fill(l);
  if (stage === "adding") top.appendChild(button("Not now")); else if (stage === "added") top.appendChild(button("Undo"));
  c.appendChild(top); fill(top);
  if (stage === "adding") {
    const track = AL("HORIZONTAL", { fills: [EDGE], cornerRadius: 1, name: "bar" }); track.resize(408, 2); c.appendChild(track); fill(track);
    const b = figma.createRectangle(); b.resize(Math.round(408 * frac), 2); b.cornerRadius = 1; b.fills = [P(INK)]; track.appendChild(keep(b));
  }
  return c;
}
// ===== 27 Settings: three tabs, one window each =====
const SETTINGS_TABS = ["Dictation", "Connections", "Your data"];
const SETTINGS_SUB = "How SigmaFlow listens, cleans up what you say, and connects to the services you choose.";
const POWER_ON = "When turned on, you will be able to auto-send your messages. Hold Right" + NB + "⌥ with Right" + NB + "⌘ together.";
const POWER_OFF = "Works when your push-to-talk key is Right" + NB + "⌘.";
const CLEAN = {
  off: "Typed exactly as heard.",
  basic: "Removes umms and false starts. Capitals and punctuation follow your default style.",
  smart: "Also fixes punctuation, applies your self-corrections and formats lists. Adds a few seconds after you release.",
  none: "Apple Intelligence is turned off in System Settings.",
};
// The Overlay row (OverlayChooser): a heading with Hold to talk, then two tiles, each a header over a stage.
const SENTENCE = "Can we move the design review to Thursday at three and send the deck tonight?";
const SAMPLE_AT_42 = "Can we move the design review to Thursday at three and send";
function previewField(text) {
  const f = AL("VERTICAL", { cornerRadius: 6, fills: [P("#141414", 0.86)], strokes: [EDGE], strokeWeight: 1, primaryAxisAlignItems: "SPACE_BETWEEN", name: "text box" }); pad(f, 8, 12);
  f.resize(380, 78);
  f.appendChild(T("A text box", 11, DIM, { lh: 14, tracking: 4, upper: true }));
  const t = T(text || "Your words are pasted here", 14, text ? INK : PLACE, { lh: 20, w: 356 }); f.appendChild(t); fill(t);
  return f;
}
// The painting softened (3 px blur, 58% black), the overlay at 80% standing above a text box, 16 inset, 12 apart.
function overlayStage(so) {
  const st = AL("VERTICAL", { itemSpacing: 12, primaryAxisAlignItems: "MAX", counterAxisAlignItems: "CENTER", clipsContent: true, name: "stage" });
  pad(st, 16); st.resize(400, 220);
  const bg = figma.createRectangle(); bg.fills = [{ type: "IMAGE", imageHash: IMAGE_HASH, scaleMode: "FILL" }]; bg.effects = [{ type: "LAYER_BLUR", radius: 3, visible: true }]; bg.name = "painting";
  st.appendChild(keep(bg)); bg.layoutPositioning = "ABSOLUTE"; bg.x = -6; bg.y = -6; bg.resize(412, 232); bg.constraints = { horizontal: "STRETCH", vertical: "STRETCH" };
  const sc = figma.createRectangle(); sc.fills = [P("#000000", 0.58)]; sc.name = "scrim";
  st.appendChild(keep(sc)); sc.layoutPositioning = "ABSOLUTE"; sc.x = 0; sc.y = 0; sc.resize(400, 220); sc.constraints = { horizontal: "STRETCH", vertical: "STRETCH" };
  if (so.card) { const k = hudCard(so.card); k.rescale(0.8); st.appendChild(k); }
  const pf = previewField(so.pasted); st.appendChild(pf); fill(pf);
  return st;
}
function overlayTile(mode, on, so) {
  const t = AL("VERTICAL", { itemSpacing: 0, cornerRadius: 8, clipsContent: true, fills: [on ? P("#FFFFFF", 0.08) : GLASS], strokes: [on ? P(INK) : EDGE], strokeWeight: on ? 1.5 : 1, name: "tile " + mode });
  const h = AL("VERTICAL", { itemSpacing: 2, name: "header" }); pad(h, 16); h.minHeight = 104;
  h.appendChild(T(mode === "live" ? "Live transcript" : "Minimal", 15, INK, { lh: 22 }));
  h.appendChild(caption(mode === "live" ? "Your words appear as you speak." : "Your words appear after you speak."));
  if (on) { const m = AL("HORIZONTAL", { itemSpacing: 6, counterAxisAlignItems: "CENTER" }); pad(m, 8, 0, 0, 0); m.appendChild(svgIcon(ICON.checkmark, 12, INK)); m.appendChild(eyebrow("Selected", INK)); h.appendChild(m); }
  t.appendChild(h); fill(h);
  const st = overlayStage(so || {}); t.appendChild(st); fill(st);
  return t;
}
function holdToTalk(held, disabled) {
  const b = button("Hold to talk", held ? "inverted" : "secondary", "microphone", null, disabled);
  if (held) { b.strokes = [HUD_EDGE]; b.strokeWeight = 1; }
  return b;
}
// o: heading (default on), held, disabled, tiles (default on), live / minimal: { card, pasted }, last (no rule under it)
function overlayChooser(c, o={}) {
  if (o.heading !== false) {
    const head = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "CENTER", name: "row Overlay" }); pad(head, 0, 16); head.minHeight = 52;
    const left = AL("VERTICAL", { itemSpacing: 2 }); pad(left, 12, 0); left.appendChild(T("Overlay", 14, INK, { lh: 20 })); left.appendChild(caption("What you see while you talk."));
    head.appendChild(left); fill(left); head.appendChild(holdToTalk(o.held, o.disabled));
    c.appendChild(head); fill(head);
  }
  if (o.tiles !== false) {
    const tiles = AL("HORIZONTAL", { itemSpacing: 16, name: "overlay tiles" }); pad(tiles, o.heading === false ? 16 : 0, 16, 16, 16);
    for (const mode of ["live", "minimal"]) { const t = overlayTile(mode, mode === "live", o[mode]); tiles.appendChild(t); fill(t); }
    c.appendChild(tiles); fill(tiles);
  }
  if (!o.last) hdivider(c);
}
const recCard = (seconds, lit, words, minimal) => ({ glyph: "dot", label: "Rec", timer: seconds, lit, flow: minimal ? null : words });
const procCard = (seconds, words, minimal) => ({ glyph: "busy", label: "Processing", timer: seconds, dim: true, lit: 0, flow: minimal ? null : words });
const errCard = (message) => ({ glyph: "warning", label: "Error", timer: "00:00", lit: 0, words: message });
function soundPickers(c, start) {
  const sr = AL("HORIZONTAL", { itemSpacing: 12, counterAxisAlignItems: "CENTER", primaryAxisAlignItems: "MAX", name: "sound pickers" }); pad(sr, 4, 16, 16, 16);
  sr.appendChild(eyebrow("Start")); sr.appendChild(popup(start, 140)); sr.appendChild(eyebrow("Stop")); sr.appendChild(popup("Pop", 140)); c.appendChild(sr); fill(sr);
}
function stripCard(w, name) { const k = card(name); w.appendChild(k); fill(k); return k; }
function screen_settings(X) {
  const { win, content } = windowFrame("27 Settings", X, "Settings", "Settings", SETTINGS_SUB);
  tabStrip(content, SETTINGS_TABS, "Dictation");
  const c = card("Dictation"); content.appendChild(c); fill(c);
  row(c, "Push-to-talk key", { caption: "Hold to dictate. Double-tap to latch.", control: popup("Right Command ⌘") });
  row(c, "Power mode", { caption: POWER_ON, captionW: 620, control: toggle(true) });
  row(c, "Microphone", { caption: "Which input records. Plug one in and it appears here.", control: popup("System default") });
  overlayChooser(c, { live: { card: recCard("00:04", 6, SAMPLE_AT_42) }, minimal: { card: recCard("00:04", 6, null, true) } });
  row(c, "Clean up what you say", { caption: CLEAN.basic, control: popup("Basic fixes", 240) });
  row(c, "Sound", { caption: "Morse on start, Pop on stop.", control: toggle(true), divider: false });
  soundPickers(c, "Morse"); hdivider(c);
  row(c, "Pause media while recording", { caption: "Music or video pauses while you talk.", control: toggle(true), last: true });
  note(win, "Matches the app with Right ⌘ as the push-to-talk key, which Power mode needs. Overlay is two tiles instead of a popup; clicking a tile selects it. Until someone holds Hold to talk, both tiles play one sample sentence, and this window freezes it at 4.2 s (DS.Motion.demoSnapshotAt), mid-sentence. Live transcript shows the words, Minimal only the dot, the clock and the meter.");
  note(win, "Microphone lists System default, every input plugged in, and Refresh list, which reads the devices again. Picking a start or stop sound plays it. Everything saves as it changes; there is no Save button.");
  stateStrip(win, "Power mode off, and unavailable", (w) => {
    const k = stripCard(w, "power");
    row(k, "Power mode", { caption: POWER_ON, captionW: 620, control: toggle(false) });
    row(k, "Push-to-talk key", { caption: "Hold to dictate. Double-tap to latch.", control: popup("Right Option ⌥") });
    row(k, "Power mode", { caption: POWER_OFF, control: toggle(false, true), last: true });
  });
  note(win, "On, holding Right ⌥ with Right ⌘ at the moment you let go pastes the text and then presses Return. The overlay reads REC IN POWER MODE while it is held (window 28). With any other push-to-talk key the switch is dimmed and says why. Hands-free and Hold to talk never send.");
  stateStrip(win, "Overlay tiles, the sample after release (5.4 s)", (w) => {
    overlayChooser(stripCard(w, "sample processing"), { heading: false, last: true, live: { card: procCard("00:05", SENTENCE) }, minimal: { card: procCard("00:05", null, true) } });
  });
  stateStrip(win, "Overlay tiles, the sample pasted (6.4 s)", (w) => {
    overlayChooser(stripCard(w, "sample pasted"), { heading: false, last: true, live: { pasted: SENTENCE }, minimal: { pasted: SENTENCE } });
  });
  note(win, "The sample runs on a 9 s loop (DS.Motion.demoCycle): first word at 0.5 s (demoLead), one more every 0.3 s (demoWordPace), released at 5.4 s (demoRecord), pasted at 6.4 s (demoProcess), then it starts again. The card fades in and out over 0.22 s (DS.Motion.fade). Both tiles end with the same sentence in the box, so Minimal visibly hands over the same words.");
  stateStrip(win, "Hold to talk, held", (w) => {
    overlayChooser(stripCard(w, "hold to talk"), { held: true, last: true, live: { card: recCard("00:02", 9, "Testing the overlay with my own") }, minimal: { card: recCard("00:02", 9, null, true) } });
  });
  note(win, "Held, the button inverts and both tiles draw one real run: your mic, model, cleanup and Dictionary, but nothing is typed, nothing is saved and the real overlay stays hidden. Letting go processes it and leaves what it would have typed in both boxes; the sample does not come back.");
  stateStrip(win, "Hold to talk while a dictation is running", (w) => { overlayChooser(stripCard(w, "hold to talk off"), { disabled: true, tiles: false, last: true }); });
  note(win, "While the push-to-talk key is recording, Hold to talk waits at 35%.");
  stateStrip(win, "Overlay tiles, an error", (w) => {
    const m = "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.";
    overlayChooser(stripCard(w, "tiles error"), { heading: false, last: true, live: { card: errCard(m) }, minimal: { card: errCard(m) } });
  });
  note(win, "An error shows its line in both tiles, Minimal included, and clears after 3 s.");
  stateStrip(win, "Clean up what you say, the other answers", (w) => {
    const k = stripCard(w, "cleanup");
    row(k, "Clean up what you say", { caption: CLEAN.off, control: popup("Off", 240) });
    row(k, "Clean up what you say", { caption: CLEAN.smart, captionW: 620, control: popup("With Apple Intelligence", 240) });
    row(k, "Clean up what you say", { caption: CLEAN.none, control: popup("With Apple Intelligence", 240), last: true });
  });
  note(win, "The caption follows the answer. When Apple Intelligence can't run, the caption gives the reason instead: This Mac doesn't support Apple Intelligence. / Apple Intelligence is turned off in System Settings. / The on-device model is still downloading.");
  stateStrip(win, "Sound off", (w) => { row(stripCard(w, "sound off"), "Sound", { caption: "Nothing plays when recording starts or stops.", control: toggle(false), last: true }); });
  note(win, "Off, the start and stop pickers go away.");
  stateStrip(win, "Custom shortcut, saved", (w) => {
    const k = stripCard(w, "custom saved");
    row(k, "Push-to-talk key", { caption: "Hold to dictate. Double-tap to latch.", control: popup("Custom shortcut") });
    contentRow(k, (r) => { r.appendChild(button("Record shortcut")); r.appendChild(chip("⌃⌥D")); r.appendChild(caption("Any modifiers with a key, like ⌃⌥D.")); }, true);
  });
  stateStrip(win, "Custom shortcut, waiting for keys", (w) => {
    contentRow(stripCard(w, "custom capture"), (r) => { r.appendChild(button("Press your keys")); r.appendChild(caption("Any modifiers with a key, like ⌃⌥D.")); }, true);
  });
  stateStrip(win, "Custom shortcut, a key without a modifier", (w) => {
    contentRow(stripCard(w, "custom refused"), (r) => { r.appendChild(button("Record shortcut")); r.appendChild(caption("Add at least one modifier: ⌃, ⌥, ⇧ or ⌘.")); }, true);
  });
  note(win, "Choosing Custom shortcut with none saved starts recording at once. A bare letter is refused, because a global shortcut on it would swallow that letter everywhere.");
  stateStrip(win, "When SigmaFlow can't watch the keyboard", (w) => {
    const k = stripCard(w, "keyboard warning");
    contentRow(k, (r) => {
      r.itemSpacing = 16;
      const l = AL("VERTICAL", { itemSpacing: 2 }); l.appendChild(T("SigmaFlow can't watch the keyboard, so no shortcut works.", 14, INK, { lh: 20 })); l.appendChild(caption("Turn SigmaFlow off and on in the Accessibility list, then open the app again."));
      r.appendChild(l); fill(l); r.appendChild(button("Open Accessibility settings"));
    });
    row(k, "Push-to-talk key", { caption: "Hold to dictate. Double-tap to latch.", control: popup("Right Command ⌘"), last: true });
  });
  note(win, "Shown at the top of the card only when the keyboard watch could not start, usually after a rebuild changed the app's signature.");
}
function screen_settings_connections(X) {
  const { win, content } = windowFrame("27B Settings, Connections", X, "Settings", "Settings", SETTINGS_SUB);
  tabStrip(content, SETTINGS_TABS, "Connections");
  const c = card("Connections"); content.appendChild(c); fill(c);
  row(c, "Claude Desktop", { caption: "Ask Claude about your dictations. Restart Claude Desktop if it has not picked this up.", data: "Connected", control: button("Disconnect", "tertiary", "close") });
  row(c, "Claude Code", { caption: "Paste one command in the terminal and Claude Code can read your dictations too.", control: button("Copy command", "secondary", "copy") });
  row(c, "Other apps", { caption: "Any app that speaks MCP can connect with this path.", control: button("Copy path", "secondary", "copy"), last: true });
  footer(c, "Connected apps read your dictation history on this Mac. Nothing leaves it.", []);
  note(win, "Matches the app with Claude Desktop connected. The command and the path are copied, not shown, so the page stays readable.");
  stateStrip(win, "Claude Desktop, not connected", (w) => { row(stripCard(w, "not connected"), "Claude Desktop", { caption: "Lets Claude Desktop search your dictations and answer questions about them.", control: button("Add to Claude", "secondary", "add"), last: true }); });
  stateStrip(win, "Claude Desktop, not installed", (w) => { row(stripCard(w, "not installed"), "Claude Desktop", { caption: "Claude Desktop is not installed on this Mac.", last: true }); });
  note(win, "If adding fails, the caption carries the reason and Add to Claude stays.");
  stateStrip(win, "Copy command, just pressed", (w) => { row(stripCard(w, "copied"), "Claude Code", { caption: "Paste one command in the terminal and Claude Code can read your dictations too.", control: button("Copied", "secondary", "checkmark"), last: true }); });
  note(win, "Copied with a tick for 1.5 s (DS.Motion.statusHold), then back. Copy path does the same.");
}
function dataRows(c, last) {
  row(c, "Transcriptions", { data: "2,625" });
  row(c, "Dictionary", { data: "18 words" });
  row(c, "Snippets", { data: "2" });
  row(c, "Styles", { data: "4" });
  row(c, "Settings", { data: "Saved" });
  row(c, "API keys", { data: "Kept in the Mac's Keychain, never exported", last });
}
const dataFooter = (c) => footer(c, "Everything SigmaFlow knows about you, in one folder you can carry to another Mac.", [button("Show the folder", "tertiary"), button("Import a folder"), button("Export", "inverted")]);
function screen_settings_data(X) {
  const { win, content } = windowFrame("27C Settings, Your data", X, "Settings", "Settings", SETTINGS_SUB);
  tabStrip(content, SETTINGS_TABS, "Your data");
  const c = card("Your data"); content.appendChild(c); fill(c);
  dataRows(c, true); dataFooter(c);
  note(win, "Matches the app. Export writes a folder named SigmaFlow Export and the date to the Desktop. Downloaded models are not included; they are fetched again on the other Mac. The API keys stay in this Mac's Keychain.");
  stateStrip(win, "Import, before anything is touched", (w) => {
    const k = stripCard(w, "import");
    row(k, "API keys", { data: "Kept in the Mac's Keychain, never exported" });
    contentRow(k, (r) => {
      const v = AL("VERTICAL", { itemSpacing: 8 });
      v.appendChild(eyebrow("Found in SigmaFlow Export 2026-10-11"));
      v.appendChild(caption("2,625 recordings, 18 dictionary entries, 2 snippets, 4 styles, settings. This Mac has 140 transcriptions, 5 dictionary words, 0 snippets and 0 styles.", 800));
      v.appendChild(actions(button("Merge into this Mac"), button("Replace everything here"), button("Cancel", "tertiary"))); v.children[2].itemSpacing = 8;
      r.appendChild(v); fill(v);
    }, true);
    dataFooter(k);
  });
  note(win, "Import a folder asks whether to merge into this Mac or replace everything here before it changes anything.");
  const outcome = (w, name, line, extra) => {
    const k = stripCard(w, name);
    row(k, "API keys", { data: "Kept in the Mac's Keychain, never exported" });
    contentRow(k, (r) => { r.appendChild(line); if (extra) r.appendChild(extra); const sp = AL("HORIZONTAL"); r.appendChild(sp); fill(sp); r.appendChild(button("Dismiss", "tertiary")); }, true);
    dataFooter(k);
  };
  stateStrip(win, "Exported", (w) => outcome(w, "exported", statusLine("Exported to /Users/you/Desktop/SigmaFlow Export 2026-10-11"), button("Show in Finder", "tertiary")));
  stateStrip(win, "Merged", (w) => outcome(w, "merged", statusLine("Merged: 2,625 recordings, 18 dictionary entries, 2 snippets, 4 styles. Settings were left as they are on this Mac.", "checkmark", 640)));
  stateStrip(win, "Import failed", (w) => outcome(w, "failed", statusLine("The file “runs.jsonl” couldn’t be opened because there is no such file.", "warning")));
  note(win, "The outcome stays under the card until Dismiss. Replace reads: Replaced. This Mac now has (what was imported). Your API keys were not touched. The tick is the same green as the audio meter.");
}
// ===== 28 HUD: the overlay and the correction notice, every state, with its timings beside it =====
// Not a window: a 1560 wide board over the painting. Each strip: the cards on the left, bottom aligned (the overlay grows
// upward from a fixed bottom edge), the timings from DS.Motion on the right.
function hudStrip(board, label, items, timing) {
  const r = AL("HORIZONTAL", { itemSpacing: 40, name: "strip " + label });
  const left = AL("VERTICAL", { itemSpacing: 14 }); left.resize(904, 20); left.counterAxisSizingMode = "FIXED"; left.primaryAxisSizingMode = "AUTO";
  left.appendChild(eyebrow(label, INK));
  const seq = AL("HORIZONTAL", { itemSpacing: 24, counterAxisAlignItems: "MAX" });
  for (const [node, cap] of items) { const col = AL("VERTICAL", { itemSpacing: 10 }); col.appendChild(node); if (cap) col.appendChild(caption(cap, 440)); seq.appendChild(col); }
  left.appendChild(seq); r.appendChild(left);
  const n = T(timing, 13, INK2, { lh: 19, w: 520 }); n.name = "timings"; r.appendChild(n);
  board.appendChild(r); fill(r); return r;
}
const LIVE = "Hey, can you send me the deck before the stand-up tomorrow, and loop in Priya from the design team as well. Also, remind me to";
function screen_hud(X) {
  let board = figma.currentPage.children.find(n => n.type === "FRAME" && n.name.split(" ")[0] === "28");
  if (board) { for (const ch of [...board.children]) ch.remove(); keep(board); } else { board = figma.createFrame(); figma.currentPage.appendChild(board); keep(board); }
  board.layoutMode = "VERTICAL"; board.name = "28 HUD"; board.x = X; board.y = 0;
  board.itemSpacing = 44; pad(board, 40, 48, 56, 48);
  board.cornerRadius = 11; board.clipsContent = true; board.strokes = [P("#FFFFFF", 0.14)]; board.strokeWeight = 1;
  board.fills = [{ type: "IMAGE", imageHash: IMAGE_HASH, scaleMode: "FILL" }, P("#000000", 0.45)];
  board.resize(1560, 760); board.counterAxisSizingMode = "FIXED"; board.primaryAxisSizingMode = "AUTO";
  clearExtras(X, 0);
  const head = AL("VERTICAL", { itemSpacing: 8, name: "Title block" });
  head.appendChild(T("Overlay", 22, INK, { lh: 28 }));
  head.appendChild(T("What floats just above the Dock while you talk, and the notice that adds a word you fixed to your Dictionary. In use it sits on glass over whatever app is in front; here it is drawn over the painting. Every state the app can show, with its timings beside it.", 14, INK2, { lh: 20, w: 904 }));
  board.appendChild(head);
  // Making room: lay the words out once to find where the third line starts, then draw before and during the glide.
  const probe = flowWords(LIVE, INK); figma.currentPage.appendChild(probe);
  const ys = probe.children.map(ch => Math.round(ch.y)); const lines = [...new Set(ys)];
  const third = lines.length > 2 ? ys.indexOf(lines[2]) : probe.children.length - 1; probe.remove();
  const before = LIVE.split(" ").slice(0, third).join(" "), during = LIVE.split(" ").slice(0, third + 1).join(" ");

  hudStrip(board, "Rec, before the first word", [[hudCard({ label: "Rec", timer: "00:01", lit: 5, words: "Listening", wordsColor: INK2 })]],
    "Arrives with a fade in over 0.16 s (DS.Motion.fadeIn), parked 96 pt above the Dock and centred. The clock ticks every 0.25 s. The meter is 14 dots; it rises in 0.12 s and falls in 0.30 s (needleAttack, needleRelease), redrawn 30 times a second. Listening stays until the first word; a model that writes after you let go has none to show until then.");
  hudStrip(board, "Rec, words arriving (Live transcript)", [[hudCard({ label: "Rec", timer: "00:06", lit: 9, flow: before, fade: 2 })]],
    "One word drops in every 130 ms, a steady pace whatever the engine sends. Each word blurs into focus over 0.34 s, easing out, from a 3 pt blur and 3 pt low (DS.Motion.wordFlow). The last two words here are mid-way. A word the engine revises is swapped in place with no animation.");
  hudStrip(board, "A line growing (Make room)", [[hudCard({ label: "Rec", timer: "00:07", lit: 8, flow: before }), "The second line is full."], [hudCard({ label: "Rec", timer: "00:07", lit: 8, flow: during, wait: third }), "The card glides up; the next word waits."]],
    "When a word wraps, the window glides up over 0.26 s on an ease-out curve (0.22, 1, 0.36, 1) (DS.Motion.hudGrow, hudGrowCurve). The bottom edge never moves. The new line's first word waits 0.18 s (hudLineWait, 70% of the glide), then drifts in like any other; every word after it queues behind it. No glide while the card is still fading in, and shrinking is instant.");
  hudStrip(board, "Rec in Power mode", [[hudCard({ label: "Rec in Power mode", timer: "00:04", lit: 7, flow: "Sounds good, see you at three" })]],
    "The label changes the moment Right ⌥ goes down with Right ⌘ held, and changes back if it is let go first. No animation of its own; the dot stays the ordinary dot. On release the text is pasted and Return is pressed.");
  hudStrip(board, "Locked, hands-free", [[hudCard({ glyph: "lock", label: "Locked", timer: "01:48", lit: 9, flow: LIVE })]],
    "A press shorter than 0.3 s is a tap and is thrown away; a second tap within 0.35 s locks the mic open. The hotkey, any key or Esc ends it. No hint text in any state.");
  hudStrip(board, "Processing, after you let go", [[hudCard({ glyph: "busy", label: "Processing", timer: "00:12", dim: true, lit: 0, flow: LIVE }), "Live words dim to grey."], [hudCard({ glyph: "busy", label: "Processing", timer: "00:12", dim: true, lit: 0, words: "Transcribing", wordsColor: INK2 }), "A model that writes after release."]],
    "The clock stops and dims, the meter falls to zero. Words still queued land at once, each settling in 0.2 s (DS.Motion.wordFlush). Then the text is pasted and the overlay fades out over 0.3 s (DS.Motion.fadeOut). If processing runs past min(180, max(30, 3 times the recording)) seconds, the run is abandoned with an Error.");
  hudStrip(board, "Minimal", [[hudCard({ label: "Rec", timer: "00:04", lit: 6 }), "Recording."], [hudCard({ glyph: "busy", label: "Processing", timer: "00:04", dim: true, lit: 0 }), "After release."]],
    "The same dot, clock and meter, never the words. An error or a style rewrite still shows its line. Same fade in and out as Live transcript.");
  hudStrip(board, "Error", [[hudCard(errCard("That took too long, so the recording was abandoned. Try again, or pick a faster model in Models.")), "Abandoned by the watchdog."], [hudCard(errCard("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")), "A failure."]],
    "The clock reads 00:00 and the meter is off. A failure holds 3 s, a run abandoned with a reason holds 4 s, then the overlay fades out over 0.3 s (DS.Motion.fadeOut). Esc on its own abandons silently: the overlay simply fades.");
  hudStrip(board, "A custom style rewriting (⌥1 to ⌥5)", [[hudCard({ glyph: "busy", label: "Boss mode", words: "Rewriting" }), "While the rewrite runs."], [hudCard({ glyph: "warning", label: "Style failed", words: "Select some text first, then press the shortcut." }), "When it can't."]],
    "A rewrite borrows the overlay: the style's name, no clock, no meter. It gives up after 45 s. A failure stays 4 s, then clears, and the selected text is left untouched.");
  hudStrip(board, "Correction noticed", [[noticeCard("adding", "clode", "Claude", 0.62), "The bar draining."], [noticeCard("adding", "clode", "Claude", 0.36), "Pointer on the card: the bar stands still."]],
    "Same spot and glass as the overlay; it takes clicks but never the cursor. Fades in over 0.16 s. The bar drains over 3.5 s (DS.Motion.noticeWindow), read from the clock, so nothing else moves. With the pointer on the card it freezes, keeping at least 1.5 s in hand; a hold gives up after 15 s and adds the word. Not now removes the card at once and adds nothing.");
  hudStrip(board, "Added, and taken back", [[noticeCard("added", "clode", "Claude"), "The bar reached the end."], [noticeCard("undone", "clode", "Claude"), "After Undo."]],
    "ADDED TO DICTIONARY holds 2.0 s (DS.Motion.addedHold) with Undo, then fades out over 0.3 s. Undo flips it to NOT ADDED for the same 2.0 s. The card keeps its bottom edge as its height changes.");
}
// ===== 20B / 20C / 20D Insights: BACKLOG, not in 1.0 (Gokul, 10 Oct). Three directions, parked at y 2600. When built, Transcriptions gets tabStrip(content, TX_TABS, ...). =====
const TX_TABS = ["Transcriptions", "Insights"];
function statTile(value, label, sub) {
  const t = card("stat " + label); pad(t, 18, 20); t.itemSpacing = 6;
  t.appendChild(T(value, 28, INK, { lh: 34 }));
  t.appendChild(eyebrow(label));
  if (sub) { const c = caption(sub); t.appendChild(c); c.textAutoResize = "HEIGHT"; c.layoutSizingHorizontal = "FILL"; }
  return t;
}
function statRow(content, tiles) {
  const r = AL("HORIZONTAL", { itemSpacing: 16, name: "stats" });
  tiles.forEach(([v, l, s]) => { const t = statTile(v, l, s); r.appendChild(t); fill(t); t.layoutSizingVertical = "FILL"; });
  content.appendChild(r); fill(r); return r;
}
// Activity calendar: one column per week, seven cells, white at four strengths. The last cell is today.
function heat(weeks, seed) {
  const g = AL("HORIZONTAL", { itemSpacing: 4, name: "heat grid" });
  let x = seed; const rnd = () => { x = (x * 9301 + 49297) % 233280; return x / 233280; };
  for (let w = 0; w < weeks; w++) {
    const col = AL("VERTICAL", { itemSpacing: 4 });
    for (let d = 0; d < 7; d++) {
      const v = rnd(); const c = figma.createRectangle(); c.resize(14, 14); c.cornerRadius = 2;
      const recent = w >= weeks - 4; const a = v < 0.15 && !recent ? 0.08 : v < 0.45 ? 0.3 : v < 0.8 ? 0.6 : 0.95;
      c.fills = [P("#FFFFFF", a)];
      if (w === weeks - 1 && d === 6) { c.strokes = [P(INK)]; c.strokeWeight = 1.5; c.fills = [P("#FFFFFF", 0.3)]; }
      col.appendChild(keep(c));
    }
    g.appendChild(col);
  }
  return g;
}
function heatBlock(weeks, seed) {
  const grid = AL("HORIZONTAL", { itemSpacing: 8, counterAxisAlignItems: "MIN", name: "calendar" });
  const days = AL("VERTICAL", { itemSpacing: 4 }); ["Mon", " ", "Wed", " ", "Fri", " ", "Sun"].forEach(d => days.appendChild(T(d, 10, DIM, { lh: 14, w: 26 })));
  grid.appendChild(days); grid.appendChild(heat(weeks, seed)); return grid;
}
function heatLegend() {
  const lg = AL("HORIZONTAL", { itemSpacing: 6, counterAxisAlignItems: "CENTER" }); lg.appendChild(caption("Less"));
  [0.08, 0.3, 0.6, 0.95].forEach(a => { const c = figma.createRectangle(); c.resize(10, 10); c.cornerRadius = 2; c.fills = [P("#FFFFFF", a)]; lg.appendChild(keep(c)); });
  lg.appendChild(caption("More")); return lg;
}
// Bars that fill the card width; the last bar is the current period.
function bars(values, h) {
  const row = AL("HORIZONTAL", { itemSpacing: 6, counterAxisAlignItems: "MAX", name: "bars" }); row.resize(400, h); row.layoutSizingHorizontal = "FIXED"; row.layoutSizingVertical = "FIXED";
  const max = Math.max(...values);
  values.forEach((v, i) => { const b = figma.createRectangle(); b.resize(10, Math.max(2, Math.round(h * v / max))); b.cornerRadius = 1; b.fills = [P("#FFFFFF", i === values.length - 1 ? 0.95 : 0.45)]; row.appendChild(keep(b)); b.layoutSizingHorizontal = "FILL"; });
  return row;
}
function axis(left, right) { const a = AL("HORIZONTAL", { primaryAxisAlignItems: "SPACE_BETWEEN" }); a.appendChild(caption(left)); a.appendChild(caption(right)); return a; }
// Half ring: faint track, ink value.
function halfRing(frac, size) {
  const clip = AL("HORIZONTAL", { clipsContent: true, name: "half ring" }); clip.resize(size, size / 2 + 2); clip.layoutSizingHorizontal = "FIXED"; clip.layoutSizingVertical = "FIXED";
  for (const [a, f] of [[1, 0.14], [frac, 1]]) {
    const e = figma.createEllipse(); e.resize(size, size); e.fills = [P("#FFFFFF", f)];
    e.arcData = { startingAngle: Math.PI, endingAngle: Math.PI + Math.PI * a, innerRadius: 0.84 };
    clip.appendChild(keep(e)); e.layoutPositioning = "ABSOLUTE"; e.x = 0; e.y = 0;
  }
  return clip;
}
function cardTitle(c, title, right) {
  const h = AL("HORIZONTAL", { primaryAxisAlignItems: "SPACE_BETWEEN", counterAxisAlignItems: "BASELINE" });
  h.appendChild(T(title, 20, INK, { lh: 26 })); if (right) h.appendChild(data(right)); c.appendChild(h); fill(h); return h;
}
function milestone(c, label, done, sub, extra, last) {
  contentRow(c, (r) => {
    r.appendChild(done ? svgIcon(ICON.checkmark, 14, INK) : radio(false));
    const l = AL("VERTICAL", { itemSpacing: 2 }); l.appendChild(T(label, 14, done ? INK : INK2, { lh: 20 })); if (sub) { const cp = caption(sub); l.appendChild(cp); cp.textAutoResize = "HEIGHT"; cp.layoutSizingHorizontal = "FILL"; } r.appendChild(l); fill(l);
    if (extra) r.appendChild(extra);
  }, last);
}
function screen_insights_numbers(X, Y) {
  const { win, content } = windowFrame("20B Insights A, numbers first", X, "Transcriptions", "Transcriptions", TX_SUB, null, Y);
  tabStrip(content, TX_TABS, "Insights");
  statRow(content, [["61,204", "Words dictated", "2,625 dictations since 14 August"], ["142", "Words a minute", "Typing averages about 40"], ["18 h 19 m", "Saved against typing", "At 40 words a minute"], ["1,318", "Words fixed for you", "Dictionary rules, applied as you spoke"]]);
  const two = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "MIN" });
  const s = card("Streak"); pad(s, 18, 20); s.itemSpacing = 14;
  cardTitle(s, "23 day streak", "Longest 41 days");
  s.appendChild(heatBlock(16, 7)); s.appendChild(heatLegend());
  two.appendChild(s); fill(s);
  const wk = card("Words per week"); pad(wk, 18, 20); wk.itemSpacing = 14;
  cardTitle(wk, "3,180 words", "This week, up 12% on last week");
  const b = bars([1200, 1850, 2100, 1700, 2600, 2900, 2200, 3100, 2800, 3400, 2840, 3180], 120); wk.appendChild(b); fill(b);
  const ax = axis("12 weeks ago", "This week"); wk.appendChild(ax); fill(ax);
  two.appendChild(wk); fill(wk);
  content.appendChild(two); fill(two);
  note(win, "Option A, numbers first. Four facts at the top, then the streak calendar and words per week. Every number comes from what the app already records: words, timings, dates and dictionary fixes.");
}
function screen_insights_story(X, Y) {
  const { win, content } = windowFrame("20C Insights B, story first", X, "Transcriptions", "Transcriptions", TX_SUB, null, Y);
  tabStrip(content, TX_TABS, "Insights");
  const hero = card("Hero"); pad(hero, 24); hero.itemSpacing = 12;
  hero.appendChild(T("You have dictated 61,204 words since August.", 24, INK, { lh: 32, w: 800 }));
  hero.appendChild(T("That is the length of a short novel. Spoken at 142 words a minute it took you 7 hours and 11 minutes; typed at 40 a minute it would have taken more than a working day. SigmaFlow fixed 1,318 words for you along the way.", 15, INK2, { lh: 22, w: 800 }));
  content.appendChild(hero); fill(hero);
  const two = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "MIN" });
  const m = card("Milestones");
  const mh = AL("HORIZONTAL"); pad(mh, 14, 16, 6, 16); mh.appendChild(eyebrow("Milestones")); m.appendChild(mh); fill(mh);
  milestone(m, "First dictation", true, "14 August");
  milestone(m, "1,000 words", true, "19 August");
  milestone(m, "10,000 words", true, "6 September");
  milestone(m, "50,000 words", true, "2 October");
  milestone(m, "100,000 words", false, "61% there, about five weeks at your pace", progress(0.61, 100));
  milestone(m, "30 day streak", false, "23 days and counting", null, true);
  two.appendChild(m); fill(m);
  const w = card("This week"); pad(w, 18, 20); w.itemSpacing = 16;
  cardTitle(w, "This week");
  for (const [v, c] of [["3,180 words", "Up 12% on last week"], ["47 dictations", "Longest: 412 words, Tuesday at 15:20"], ["23 day streak", "Longest ever, 41 days"], ["142 words a minute", "Typing averages about 40"]]) {
    const l = AL("VERTICAL", { itemSpacing: 2 }); l.appendChild(T(v, 15, INK, { lh: 22 })); l.appendChild(caption(c)); w.appendChild(l);
  }
  two.appendChild(w); fill(w);
  content.appendChild(two); fill(two);
  note(win, "Option B, story first. One paragraph says what the numbers mean, milestones give something to reach for, and the week card keeps the streak alive. Fewer charts, more words; closest to how the rest of SigmaFlow talks.");
}
function screen_insights_habits(X, Y) {
  const { win, content } = windowFrame("20D Insights C, habits", X, "Transcriptions", "Transcriptions", TX_SUB, null, Y);
  tabStrip(content, TX_TABS, "Insights");
  const s = card("Streak"); pad(s, 18, 20); s.itemSpacing = 14;
  cardTitle(s, "23 day streak", "Longest 41 days    61,204 words since 14 August");
  s.appendChild(heatBlock(26, 11)); s.appendChild(heatLegend());
  content.appendChild(s); fill(s);
  const three = AL("HORIZONTAL", { itemSpacing: 16, counterAxisAlignItems: "MIN" });
  const sp = card("Speed"); pad(sp, 18, 20); sp.itemSpacing = 10; sp.counterAxisAlignItems = "CENTER";
  sp.appendChild(eyebrow("Words a minute"));
  const ring = AL("VERTICAL", { counterAxisAlignItems: "CENTER", itemSpacing: 0 }); ring.appendChild(halfRing(0.71, 160));
  const big = T("142", 28, INK, { lh: 34 }); ring.appendChild(big); big.layoutPositioning = "ABSOLUTE"; big.x = 80 - big.width / 2; big.y = 44;
  sp.appendChild(ring);
  sp.appendChild(caption("3.5 times faster than typing at 40", 200, { center: true }));
  three.appendChild(sp); fill(sp);
  const wh = card("When"); pad(wh, 18, 20); wh.itemSpacing = 10;
  wh.appendChild(eyebrow("When you dictate"));
  const hb = bars([0, 0, 0, 0, 0, 0, 1, 3, 9, 14, 22, 18, 9, 12, 17, 21, 15, 10, 6, 4, 3, 2, 1, 0], 96); wh.appendChild(hb); fill(hb);
  const hx = axis("6 am", "6 pm"); wh.appendChild(hx); fill(hx);
  wh.appendChild(caption("Most dictations land between 10 and 11 in the morning.", 240));
  three.appendChild(wh); fill(wh);
  const en = card("Engines"); pad(en, 18, 20); en.itemSpacing = 12;
  en.appendChild(eyebrow("Which engine did the work"));
  for (const [n, f] of [["Parakeet Unified EN", 0.78], ["Apple", 0.19], ["Parakeet V3", 0.03]]) {
    const l = AL("VERTICAL", { itemSpacing: 6 }); l.appendChild(T(n, 14, INK, { lh: 20 })); const pr = progress(f, 160); l.appendChild(pr); en.appendChild(l); fill(l);
  }
  three.appendChild(en); fill(en);
  content.appendChild(three); fill(three);
  note(win, "Option C, habits. The streak calendar is the hero, then how fast you speak, when in the day you dictate, and which engines did the work. The most behavioural of the three and the closest to the reference.");
}
