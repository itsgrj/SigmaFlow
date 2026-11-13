# SigmaFlow on the Chrome Web Store

What the developer dashboard asks for, field by field, ready to paste. The upload is
`make extension-zip FIRST=1` the first time (it carries the private key so the store keeps the
ID `gcaepogaaolbllpamlfmbdnliikmmgfj`), then `make extension-zip` for every update. Raise
`version` in `BrowserExtension/manifest.json` for each update.

Once it is published, set `BrowserBridge.storeURL` to the listing's address, and Add in
Settings opens the store in place of the Developer mode steps.

## Store listing

**Name:** SigmaFlow

**Summary** (132 characters at most, the manifest's description):
Learns from your fixes on websites, and lets Autowrite read the whole conversation. Works with SigmaFlow on your Mac.

**Description:**

SigmaFlow types what you say, anywhere on your Mac. This extension makes it just as good in
your browser.

Learns from your fixes. When you correct a word SigmaFlow got wrong in Gmail, a chat or a help
desk, SigmaFlow remembers it, and gets it right next time. Your saved dictation keeps the words
you actually sent.

Autowrite reads the whole conversation. Hold the Autowrite key and say what you want written.
SigmaFlow reads the whole thread, not just what fits on your screen, and writes a reply that
fits.

Works with SigmaFlow for Mac, free and open source: github.com/itsgrj/SigmaFlow

Switch it off for any site from its toolbar button. It never reads password boxes, and it sends
nothing over the internet: what it reads goes to SigmaFlow on your Mac.

**Category:** Productivity, Tools
**Language:** English

**Pictures:**
- Icon: `BrowserExtension/icons/128.png`
- Screenshots: 1280 x 800, at least one, up to five
- Small promo tile: 440 x 280

## Privacy tab

**Single purpose:**
Gives the SigmaFlow Mac app the text box it just typed into and, while the Autowrite key is
held, the words of the page, so it can learn from corrections and write replies that fit.

**Permission justifications:**

- `nativeMessaging`: the only way the extension talks to the SigmaFlow app on the same Mac.
  Nothing it reads leaves through any other route.
- `scripting`: reads the focused text box after SigmaFlow types into it, and the page's words
  while the Autowrite key is held, only when the SigmaFlow app asks.
- `storage`: keeps the list of sites the person switched the extension off for.
- `alarms`: reconnects to the SigmaFlow app if it was quit and opened again.
- Host permission `<all_urls>`: SigmaFlow types into any website the person uses (mail, chat,
  help desks, documents), so the extension has to be able to read the box it typed into on any
  of them. Each site can be switched off from the toolbar.

**Remote code:** No, I am not using remote code.

**Data usage:** Website content (the text box SigmaFlow typed into, and the page's words for
Autowrite). Not sold to third parties; not used or transferred for purposes unrelated to the
single purpose; not used to determine creditworthiness or for lending.

**Privacy policy:** https://github.com/itsgrj/SigmaFlow/blob/main/PRIVACY.md
