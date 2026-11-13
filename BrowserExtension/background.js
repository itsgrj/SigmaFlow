// SigmaFlow's extension, the background half (docs/mockups/browser-extension.html).
//
// One native port to SigmaFlow on this Mac, through the small helper the browser starts
// (com.grj.sigmaflow, Contents/MacOS/sigmaflow-browser in the app). SigmaFlow asks, this
// answers from the tab in front:
//
//   field.watch  the box it just typed into: remembered under a token, and its text
//   field.read   that box's text now
//   field.forget the learner has stopped watching
//   page.read    the page's words, for Autowrite, while its key is held
//
// Every answer goes back down the same port and nowhere else. A site switched off in the
// toolbar card (pick 07) answers nothing.

const HOST = "com.grj.sigmaflow";

let port = null;
let appConnected = false;
// token -> { tabId, frameId } for the box each watch began on.
const watched = new Map();

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    return;
  }
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    appConnected = false;
    void chrome.runtime.lastError;
  });
}

function send(message) {
  if (port) port.postMessage(message);
}

async function onMessage(message) {
  if (!message || typeof message !== "object") return;
  if (message.type === "status") {
    // From the helper: whether SigmaFlow itself is running and listening.
    appConnected = !!message.app;
    if (appConnected) send({ type: "hello", version: chrome.runtime.getManifest().version });
    return;
  }
  const id = message.id;
  try {
    switch (message.type) {
      case "field.watch":
        send({ id, ...(await watchField(message.token || id)) });
        break;
      case "field.read":
        send({ id, ...(await readField(message.token)) });
        break;
      case "field.forget":
        forgetField(message.token);
        break;
      case "page.read":
        send({ id, ...(await readPage()) });
        break;
      default:
        if (id) send({ id, ok: false, reason: "unknown" });
    }
  } catch (error) {
    if (id) send({ id, ok: false, reason: String(error && error.message || error) });
  }
}

// MARK: The tab and the site

async function frontTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab || null;
}

function hostOf(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? parsed.hostname : null;
  } catch {
    return null;
  }
}

async function offSites() {
  const { off } = await chrome.storage.local.get("off");
  return Array.isArray(off) ? off : [];
}

async function isOff(host) {
  return (await offSites()).includes(host);
}

// Runs one of content.js's functions in the frames of `target`. A tab opened before the
// extension arrived has no content.js yet; it is put in, once, and asked again.
async function call(target, name, args) {
  const run = () => chrome.scripting.executeScript({
    target,
    func: (name, args) => globalThis.sigmaflow ? { value: globalThis.sigmaflow[name](...args) } : { missing: true },
    args: [name, args],
  });
  let results = await run();
  if (results.some((r) => r.result && r.result.missing)) {
    await chrome.scripting.executeScript({ target, files: ["content.js"] });
    results = await run();
  }
  return results.map((r) => ({ frameId: r.frameId, value: r.result ? r.result.value : null }));
}

// MARK: The box SigmaFlow typed into

async function watchField(token) {
  const tab = await frontTab();
  const host = tab && hostOf(tab.url);
  if (!host) return { ok: false, reason: "no-site" };
  if (await isOff(host)) return { ok: false, reason: "off" };
  const results = await call({ tabId: tab.id, allFrames: true }, "watch", [token]);
  const hit = results.find((r) => r.value);
  if (!hit) return { ok: false, reason: "no-box" };
  watched.set(token, { tabId: tab.id, frameId: hit.frameId });
  return { ok: true, host, text: hit.value.text };
}

async function readField(token) {
  const entry = watched.get(token);
  if (!entry) return { ok: false, reason: "gone" };
  try {
    const [result] = await call({ tabId: entry.tabId, frameIds: [entry.frameId] }, "read", [token]);
    if (!result || !result.value) {
      watched.delete(token);
      return { ok: false, reason: "gone" };
    }
    return { ok: true, text: result.value.text };
  } catch {
    // The tab closed or went to another page.
    watched.delete(token);
    return { ok: false, reason: "gone" };
  }
}

function forgetField(token) {
  const entry = watched.get(token);
  watched.delete(token);
  if (entry) {
    call({ tabId: entry.tabId, frameIds: [entry.frameId] }, "forget", [token]).catch(() => {});
  }
}

// MARK: The page, for Autowrite

const pageLongest = 400_000;
const frameShortest = 200;

async function readPage() {
  const tab = await frontTab();
  const host = tab && hostOf(tab.url);
  if (!host) return { ok: false, reason: "no-site" };
  if (await isOff(host)) return { ok: false, reason: "off" };
  const results = await call({ tabId: tab.id, allFrames: true }, "page", []);
  const top = results.find((r) => r.frameId === 0 && r.value);
  // The top frame first, then any frame with real text of its own (a mail body, an
  // embedded conversation), skipping what the top frame already holds.
  const pieces = [];
  if (top && top.value.text) pieces.push(top.value.text);
  for (const r of results) {
    if (r.frameId === 0 || !r.value || r.value.text.length < frameShortest) continue;
    if (pieces.some((piece) => piece.includes(r.value.text))) continue;
    pieces.push(r.value.text);
  }
  const text = pieces.join("\n\n").slice(0, pageLongest);
  if (!text) return { ok: false, reason: "empty" };
  return { ok: true, host, title: (top && top.value.title) || tab.title || "", text };
}

// MARK: The toolbar card

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!message || sender.id !== chrome.runtime.id) return false;
  if (message.type === "status") {
    connect();
    reply({ app: appConnected });
    return false;
  }
  if (message.type === "openApp") {
    send({ type: "openApp" });
    reply({ sent: !!port && appConnected });
    return false;
  }
  return false;
});

// MARK: Staying connected

// Tabs open before the extension arrived get content.js now rather than at their next load.
chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (!hostOf(tab.url || "")) continue;
    chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content.js"] }).catch(() => {});
  }
});

chrome.runtime.onStartup.addListener(connect);
// The open port keeps this worker alive. Should the helper ever be missing (SigmaFlow
// moved or deleted), the alarm tries again each minute instead of spinning.
chrome.alarms?.create("reconnect", { periodInMinutes: 1 });
chrome.alarms?.onAlarm.addListener(connect);
connect();
