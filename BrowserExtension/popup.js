// The toolbar card (pick 07): connected or not, and one switch that turns SigmaFlow off on
// the site in front. Off means SigmaFlow still types there; it just never reads the page.
// Under it, while SigmaFlow is open, the switch for fixing spelling as you type
// (docs/mockups/browser-autocorrect.html, 06): the same setting as SigmaFlow's Settings,
// Connections, so it reads and writes the app's value, never one of its own.

const ON = "Learns from your fixes, and Autowrite reads the page.";
const ON_FIXING = "Fixes your spelling, learns from your fixes, and Autowrite reads the page.";
const OFF = "Off here. SigmaFlow still types, it just doesn’t read this site.";
const NOTHING = "Nothing to read on this page.";

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

let fixing = false;

function showSwitch(isOn) {
  const button = document.getElementById("switch");
  button.hidden = false;
  button.setAttribute("aria-checked", String(isOn));
  document.getElementById("line").textContent = isOn ? (fixing ? ON_FIXING : ON) : OFF;
}

function showSpelling(browser) {
  document.getElementById("spelling").hidden = false;
  document.getElementById("spellingSwitch").setAttribute("aria-checked", String(fixing));
  document.getElementById("spellingLine").textContent = browser ? `On every site in ${browser}.` : "On every site.";
}

async function main() {
  const status = document.getElementById("status");
  const answer = await new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: "status" }, (answer) => {
      void chrome.runtime.lastError;
      resolve(answer || {});
    });
  });
  const connected = !!answer.app;
  status.textContent = connected ? "Connected" : "SigmaFlow isn’t open";
  status.classList.toggle("on", connected);
  fixing = connected && !!answer.fixSpelling;
  if (connected) {
    showSpelling(answer.browser);
    document.getElementById("spellingSwitch").addEventListener("click", () => {
      chrome.runtime.sendMessage({ type: "fixSpelling.set", on: !fixing }, (reply) => {
        void chrome.runtime.lastError;
        fixing = !!(reply && reply.fixSpelling);
        showSpelling(answer.browser);
        if (!document.getElementById("switch").hidden) {
          showSwitch(document.getElementById("switch").getAttribute("aria-checked") === "true");
        }
      });
    });
  }

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const host = tab && hostOf(tab.url || "");
  if (!host) {
    document.getElementById("host").textContent = NOTHING;
    return;
  }
  document.getElementById("host").textContent = `On ${host}`;
  let isOn = !(await offSites()).includes(host);
  showSwitch(isOn);

  document.getElementById("switch").addEventListener("click", async () => {
    isOn = !isOn;
    const off = new Set(await offSites());
    if (isOn) off.delete(host); else off.add(host);
    await chrome.storage.local.set({ off: [...off] });
    showSwitch(isOn);
  });
}

document.getElementById("open").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "openApp" }, () => {
    void chrome.runtime.lastError;
    window.close();
  });
});

main();
