// SigmaFlow in the page (docs/mockups/browser-extension.html, picks 01 02 04 07 09).
//
// Nothing here runs by itself. The background asks, through chrome.scripting, and only
// when SigmaFlow on the Mac asks it: right after a dictation lands (the text box it went
// into, so a fix can be learned and the saved transcript can follow it), and while the
// Autowrite key is held (the page's words). Nothing is kept, and nothing leaves the Mac.
//
// The background's calls run in this same isolated world, which is how they reach
// `globalThis.sigmaflow`. A frame answers only when it has the focus, so of all the
// frames on a page exactly one speaks for the text box.

(() => {
  if (globalThis.sigmaflow) return;

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
})();
