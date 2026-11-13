# Privacy

SigmaFlow runs on your Mac. It has no account, no server of its own and no analytics. This
page covers the SigmaFlow app and the SigmaFlow browser extension.

## The browser extension

The extension helps the SigmaFlow app on your Mac in two moments, and does nothing at any
other time.

- **Right after SigmaFlow types into a text box on a website.** It reads that one box for up
  to three minutes, so SigmaFlow can learn when you fix a word it got wrong, and so your
  saved dictation matches what you sent. It never reads password boxes.
- **While you hold the Autowrite key.** It reads the words on the page in front of you, so
  SigmaFlow can write a reply that fits the whole conversation, not only the part on your
  screen.

What it reads goes to the SigmaFlow app on the same Mac, through your browser's own
connection to it (native messaging). The extension sends nothing over the internet, and it
keeps nothing except the list of sites you switched it off for, saved in your browser.

You can switch it off for any site from its toolbar button, or remove it from SigmaFlow's
Settings, Connections.

## What the SigmaFlow app does with it

- A fix you make can become a word in your SigmaFlow dictionary, which you can see and
  delete on the Dictionary page. Your dictations are saved as files in the SigmaFlow folder
  in your home folder.
- Autowrite gives the page to the AI model you chose on SigmaFlow's Styles page. With Apple's
  model or your own model on this Mac, it stays on your Mac. With Claude or OpenRouter, it is
  sent to that company with your own key, under that company's terms, and only while you
  hold the key and ask.

SigmaFlow never sells, shares or uses any of this for advertising, and nobody at SigmaFlow
can see it.

## Questions

Open an issue at [github.com/itsgrj/SigmaFlow](https://github.com/itsgrj/SigmaFlow/issues).
