// SigmaFlow in the page (docs/mockups/browser-extension.html, picks 01 02 04 07 09).
//
// Two parts. The first runs only when asked: the background calls it, through
// chrome.scripting, when SigmaFlow on the Mac asks: right after a dictation lands (the text
// box it went into, so a fix can be learned and the saved transcript can follow it), and
// while the Autowrite key is held (the page's words). The second, at the bottom, fixes
// spelling as you type: each finished word goes to SigmaFlow for a fix. Nothing is kept,
// and nothing leaves the Mac.
//
// The background's calls run in this same isolated world, which is how they reach
// `globalThis.sigmaflow`. A frame answers only when it has the focus, so of all the
// frames on a page exactly one speaks for the text box.

(() => {
  // Once per frame. A copy left by an extension that has since reloaded can no longer reach
  // its background; a new copy takes its place, and the old one's listeners stand down.
  if (globalThis.sigmaflow && globalThis.sigmaflow.isAlive && globalThis.sigmaflow.isAlive()) return;
  const alive = () => {
    try {
      return !!chrome.runtime.id;
    } catch {
      return false;
    }
  };

  // A field SigmaFlow typed into, by token, for as long as the learner watches it. Weak,
  // so a field the page throws away is gone here too.
  const watched = new Map();
  const forgetAfter = 3 * 60 * 1000;
  const longest = 100_000;

  // The element with the focus, through any shadow roots on the way.
  function focused() {
    let element = document.activeElement;
    while (element && element.shadowRoot && element.shadowRoot.activeElement) {
      element = element.shadowRoot.activeElement;
    }
    return element;
  }

  const textInputs = new Set(["", "text", "search", "email", "url"]);

  // The box the focus is in: a text area, a plain text input, or the outermost element of
  // a rich editor. Password fields never count.
  function editableBox(element) {
    if (!element) return null;
    if (element.tagName === "TEXTAREA") return element;
    if (element.tagName === "INPUT") return textInputs.has((element.type || "").toLowerCase()) ? element : null;
    if (element.isContentEditable) {
      let host = element;
      while (host.parentElement && host.parentElement.isContentEditable) host = host.parentElement;
      return host;
    }
    return null;
  }

  function textOf(box) {
    const text = box.tagName === "TEXTAREA" || box.tagName === "INPUT" ? box.value : box.innerText;
    return typeof text === "string" ? text : null;
  }

  function sweep() {
    const now = Date.now();
    for (const [token, entry] of watched) {
      if (now - entry.since > forgetAfter || !entry.ref.deref()) watched.delete(token);
    }
  }

  globalThis.sigmaflow = {
    isAlive: alive,

    // The box SigmaFlow just typed into, remembered under `token`, and what it holds now.
    watch(token) {
      if (!document.hasFocus()) return null;
      const box = editableBox(focused());
      if (!box) return null;
      const text = textOf(box);
      if (text === null || text.length > longest) return null;
      sweep();
      watched.set(token, { ref: new WeakRef(box), since: Date.now() });
      return { text };
    },

    // What that box holds now; nothing once it has left the page.
    read(token) {
      const entry = watched.get(token);
      const box = entry && entry.ref.deref();
      if (!box || !box.isConnected) {
        watched.delete(token);
        return null;
      }
      const text = textOf(box);
      if (text === null || text.length > longest) return null;
      return { text };
    },

    forget(token) {
      watched.delete(token);
    },

    // The words of this frame, for Autowrite: the page's main part when it has one with
    // real text in it (a mail thread, a ticket), else the whole page.
    page() {
      if (!document.body) return null;
      const main = document.querySelector("main, [role=main]");
      const root = main && main.innerText && main.innerText.trim().length > 400 ? main : document.body;
      const text = (root.innerText || "").replace(/\n{3,}/g, "\n\n").trim();
      return { text, title: document.title || "", top: window === window.top };
    },
  };

  // MARK: Fixing spelling as you type (docs/mockups/browser-autocorrect.html, picks 02 04 06 08)
  //
  // The one thing here that starts by itself. When a word is finished with a space or
  // punctuation, that word and the few before it go to the background, which asks SigmaFlow
  // (unless the switch is off, the site is off, or SigmaFlow isn't there). A fix comes back
  // in a few milliseconds and is put in as if typed, so ⌘Z undoes it and the page's editor
  // hears it; a faint dotted line sits under it for 2 seconds (02). Delete straight after
  // puts your word back and sends it to SigmaFlow, which keeps it as a word (08). If the text
  // before the cursor has changed by the time the fix arrives, it is dropped.

  const enders = new Set([" ", " ", ".", ",", "!", "?", ";", ":", ")"]);
  const latinWord = /^\p{Script=Latin}+(?:['’]\p{Script=Latin}+)*$/u;
  const opening = /^[("'“‘\[]+/u;
  const contextLength = 120;
  const markHold = 2000;
  const takeBackWithin = 10_000;
  // Code editors, and code blocks inside a rich editor (the cursor's own element is checked).
  const codeLike = "code, pre, .monaco-editor, .cm-editor, .cm-content, .CodeMirror, .ace_editor";

  let fixing = false;   // our own edit is going in: its events are not typing
  let lastFix = null;   // { box, original, fixed, ender, at }
  const keptHere = new Set();

  function fixable(box) {
    if (!box) return false;
    if (box.closest(codeLike)) return false;
    if (box.tagName === "INPUT" || box.tagName === "TEXTAREA") {
      if (box.tagName === "INPUT" && !["", "text", "search"].includes((box.type || "").toLowerCase())) return false;
      // A plain field the page keeps spelling out of (a search box, a username, a code)
      // stays as typed. `spellcheck` reads the attribute as inherited from the ancestors.
      if (!box.spellcheck) return false;
      const autocorrect = box.closest("[autocorrect]");
      if (autocorrect && autocorrect.getAttribute("autocorrect").toLowerCase() === "off") return false;
      return true;
    }
    // A rich editor is fixed even with spelling switched off: Gmail and others switch the
    // browser's checker off to draw their own lines. Only a code block inside it is left.
    const at = window.getSelection()?.anchorNode;
    const element = at && (at.nodeType === Node.ELEMENT_NODE ? at : at.parentElement);
    return !(element && element.closest(codeLike));
  }

  // An element a word can't run across: a block (a paragraph, a line's div), a line break,
  // a picture, or a piece the page won't let you type into (a chip, a mention).
  function breaksWords(element) {
    if (["BR", "IMG", "INPUT", "TEXTAREA", "SELECT", "BUTTON", "HR"].includes(element.tagName)) return true;
    if (!element.isContentEditable) return true;
    return !getComputedStyle(element).display.startsWith("inline");
  }

  // The text nodes before the cursor, back to the start of its line or far enough for the
  // context, as { node, to } pieces (each from its start, the last one to the cursor).
  // An editor may wrap a word in its own span (an underline, a highlight); this reads
  // through it, so "lunch <span>sesson</span> " still ends in "sesson ".
  function piecesBefore(box, node, offset) {
    const pieces = [{ node, to: offset }];
    let length = offset;
    let current = node;
    walk: while (length < contextLength + 60) {
      let previous = current.previousSibling;
      if (!previous) {
        const parent = current.parentNode;
        if (!parent || parent === box || parent.nodeType !== Node.ELEMENT_NODE || breaksWords(parent)) break;
        current = parent;
        continue;
      }
      while (previous.nodeType === Node.ELEMENT_NODE) {
        if (breaksWords(previous)) break walk;
        if (!previous.lastChild) break;
        previous = previous.lastChild;
      }
      current = previous;
      if (previous.nodeType === Node.TEXT_NODE && previous.data.length) {
        pieces.unshift({ node: previous, to: previous.data.length });
        length += previous.data.length;
      }
    }
    return pieces;
  }

  // The place `count` characters before the end of `pieces`.
  function placeBack(pieces, count) {
    let left = count;
    for (let i = pieces.length - 1; i >= 0; i--) {
      if (pieces[i].to >= left) return { node: pieces[i].node, offset: pieces[i].to - left };
      left -= pieces[i].to;
    }
    return null;
  }

  // What sits just before the cursor in `box`: the text there, and how to put something
  // in its place. Null when there is a selection, or the cursor isn't in plain text.
  function beforeCursor(box) {
    if (box.tagName === "TEXTAREA" || box.tagName === "INPUT") {
      const end = box.selectionStart;
      if (end === null || end !== box.selectionEnd) return null;
      return {
        text: box.value.slice(Math.max(0, end - contextLength - 60), end),
        replace(length, text) {
          box.setSelectionRange(end - length, end);
          if (!document.execCommand("insertText", false, text)) {
            box.setRangeText(text, end - length, end, "end");
            box.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: text }));
          }
        },
        rect(from, to) {
          const at = box.selectionStart;
          return fieldRect(box, at - from, at - to);
        },
      };
    }
    const selection = window.getSelection();
    if (!selection || selection.rangeCount !== 1 || !selection.isCollapsed) return null;
    const node = selection.anchorNode;
    const offset = selection.anchorOffset;
    if (!node || node.nodeType !== Node.TEXT_NODE || !box.contains(node)) return null;
    const pieces = piecesBefore(box, node, offset);
    const text = pieces.map((piece) => piece.node.data.slice(0, piece.to)).join("");
    return {
      text: text.slice(-(contextLength + 60)),
      replace(length, replacement) {
        const start = placeBack(pieces, length);
        if (!start) return;
        const range = document.createRange();
        range.setStart(start.node, start.offset);
        range.setEnd(node, offset);
        selection.removeAllRanges();
        selection.addRange(range);
        if (!document.execCommand("insertText", false, replacement)) {
          range.collapse(false);
          selection.removeAllRanges();
          selection.addRange(range);
        }
      },
      rect(from, to) {
        const now = window.getSelection();
        const at = now && now.anchorNode;
        if (!at || at.nodeType !== Node.TEXT_NODE || !box.contains(at)) return null;
        const after = piecesBefore(box, at, now.anchorOffset);
        const start = placeBack(after, from);
        const end = placeBack(after, to);
        if (!start || !end) return null;
        const range = document.createRange();
        range.setStart(start.node, start.offset);
        range.setEnd(end.node, end.offset);
        return range.getClientRects()[0] || null;
      },
    };
  }

  // The finished word: the last run before the ender, with opening brackets and quotes taken
  // off its front. Null for anything that isn't a plain Latin word (an address, an email,
  // a number, a path, Tamil) or was typed in capitals or camelCase on purpose.
  function finishedWord(text) {
    const ender = text.slice(-1);
    if (!enders.has(ender)) return null;
    const token = text.slice(0, -1).split(/\s/).pop().replace(opening, "");
    if (!token || token.length < 2 || token.length > 40 || !latinWord.test(token)) return null;
    const letters = [...token].filter((c) => /\p{L}/u.test(c));
    if (letters.length >= 2 && letters.every((c) => c === c.toUpperCase() && c !== c.toLowerCase())) return null;
    if (/\p{Ll}\p{Lu}/u.test(token)) return null;
    if (keptHere.has(token.toLowerCase())) return null;
    const context = text.slice(0, -1).slice(-contextLength);
    return { word: token, ender, context };
  }

  function send(message, answered) {
    if (!alive()) return stop();
    try {
      chrome.runtime.sendMessage(message, (answer) => {
        void chrome.runtime.lastError;
        if (answered) answered(answer);
      });
    } catch {
      stop();
    }
  }

  function onInput(event) {
    if (fixing) return;
    if (!alive()) return stop();
    lastFix = null;
    if (event.isComposing || event.inputType !== "insertText" || !event.data || event.data.length !== 1) return;
    const box = editableBox(focused());
    if (!fixable(box)) return;
    const before = beforeCursor(box);
    const found = before && finishedWord(before.text);
    if (!found) return;
    send({ type: "spell.check", word: found.word, text: found.context }, (answer) => {
      if (answer && typeof answer.fix === "string" && answer.fix && answer.fix !== found.word) apply(box, found, answer.fix);
    });
  }

  function apply(box, found, fix) {
    if (editableBox(focused()) !== box) return;
    const now = beforeCursor(box);
    const typed = found.word + found.ender;
    if (!now || !now.text.endsWith(typed)) return;
    fixing = true;
    try {
      now.replace(typed.length, fix + found.ender);
    } finally {
      fixing = false;
    }
    const after = beforeCursor(box);
    if (!after || !after.text.endsWith(fix + found.ender)) return;
    lastFix = { box, original: found.word, fixed: fix, ender: found.ender, at: Date.now() };
    mark(after.rect(fix.length + found.ender.length, found.ender.length));
  }

  // Delete straight after a fix: your word back, with the space, and kept from then on.
  // On keydown, in the capture phase of the window, so it comes before any editor's own
  // Backspace handling.
  function onKeyDown(event) {
    if (fixing || !lastFix) return;
    if (["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(event.key)) return;
    const fix = lastFix;
    lastFix = null;
    if (event.key !== "Backspace" || event.metaKey || event.altKey || event.ctrlKey || event.shiftKey || event.isComposing || event.repeat) return;
    if (Date.now() - fix.at > takeBackWithin || editableBox(focused()) !== fix.box) return;
    const now = beforeCursor(fix.box);
    if (!now || !now.text.endsWith(fix.fixed + fix.ender)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    fixing = true;
    try {
      now.replace(fix.fixed.length + fix.ender.length, fix.original + fix.ender);
    } finally {
      fixing = false;
    }
    unmark();
    keptHere.add(fix.original.toLowerCase());
    send({ type: "spell.kept", word: fix.original });
  }

  // MARK: The dotted line (pick 02)

  let markHost = null;
  let markTimer = null;

  function mark(rect) {
    unmark();
    if (!rect || rect.width <= 0) return;
    markHost = document.createElement("div");
    markHost.style.cssText = "all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none";
    const root = markHost.attachShadow({ mode: "closed" });
    const line = document.createElement("div");
    line.style.cssText = `position:fixed;left:${rect.left}px;top:${rect.bottom - 1}px;width:${rect.width}px;height:0;` +
      "border-bottom:1.5px dotted #8a8a8a;pointer-events:none;transition:opacity .2s";
    root.append(line);
    document.documentElement.append(markHost);
    markTimer = setTimeout(() => {
      line.style.opacity = "0";
      markTimer = setTimeout(unmark, 200);
    }, markHold);
  }

  function unmark() {
    clearTimeout(markTimer);
    markTimer = null;
    if (markHost) markHost.remove();
    markHost = null;
  }

  // Where characters `start` to `end` of a text area or input sit on screen, measured on a
  // copy of the box laid out the same way, since a form field has no ranges to ask.
  function fieldRect(box, start, end) {
    if (start < 0 || end < start) return null;
    const style = getComputedStyle(box);
    const copy = document.createElement("div");
    for (const name of ["boxSizing", "width", "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
      "borderStyle", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft", "fontStyle", "fontVariant", "fontWeight",
      "fontStretch", "fontSize", "lineHeight", "fontFamily", "textAlign", "textTransform", "textIndent", "letterSpacing",
      "wordSpacing", "tabSize"]) {
      copy.style[name] = style[name];
    }
    const single = box.tagName === "INPUT";
    Object.assign(copy.style, {
      position: "absolute", visibility: "hidden", left: "-9999px", top: "0", overflow: "hidden",
      whiteSpace: single ? "pre" : "pre-wrap", overflowWrap: single ? "normal" : "break-word",
    });
    copy.textContent = box.value.slice(0, start);
    const word = document.createElement("span");
    word.textContent = box.value.slice(start, end) || ".";
    copy.append(word);
    document.body.append(copy);
    const outer = box.getBoundingClientRect();
    const left = outer.left + parseFloat(style.borderLeftWidth) + word.offsetLeft - box.scrollLeft;
    let top = outer.top + parseFloat(style.borderTopWidth) + word.offsetTop - box.scrollTop;
    if (single) top = outer.top + (outer.height - word.offsetHeight) / 2;
    const rect = { left, top, width: word.offsetWidth, bottom: top + word.offsetHeight };
    copy.remove();
    if (rect.left < outer.left - 1 || rect.left + rect.width > outer.right + 1 || rect.top < outer.top - 1 || rect.bottom > outer.bottom + 1) return null;
    return rect;
  }

  const onMouseDown = () => { lastFix = null; };
  document.addEventListener("input", onInput, true);
  window.addEventListener("keydown", onKeyDown, true);
  window.addEventListener("mousedown", onMouseDown, true);
  window.addEventListener("scroll", unmark, true);

  function stop() {
    lastFix = null;
    unmark();
    document.removeEventListener("input", onInput, true);
    window.removeEventListener("keydown", onKeyDown, true);
    window.removeEventListener("mousedown", onMouseDown, true);
    window.removeEventListener("scroll", unmark, true);
  }
})();
