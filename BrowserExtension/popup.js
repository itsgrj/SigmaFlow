// The toolbar card (pick 07): connected or not, and one switch that turns SigmaFlow off on
// the site in front. Off means SigmaFlow still types there; it just never reads the page.

const ON = "Learns from your fixes, and Autowrite reads the page.";
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

function showSwitch(isOn) {
  const button = document.getElementById("switch");
  button.hidden = false;
  button.setAttribute("aria-checked", String(isOn));
  document.getElementById("line").textContent = isOn ? ON : OFF;
}

async function main() {
  const status = document.getElementById("status");
  chrome.runtime.sendMessage({ type: "status" }, (answer) => {
    void chrome.runtime.lastError;
    const connected = !!(answer && answer.app);
    status.textContent = connected ? "Connected" : "SigmaFlow isn’t open";
    status.classList.toggle("on", connected);
  });

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
