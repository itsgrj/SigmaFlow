# SigmaFlow 0.6

Released 2 September 2026. Requires macOS 26.

Version 0.5 gave SigmaFlow Styles, a Claude connection, and the frosted HUD. Version 0.6 is about the dictionary: making it learn from you instead of asking you to type what the engine got wrong, and letting the app carry everything you have taught it to another Mac.

## New

### Learn from corrections
SigmaFlow now notices when you fix a word it got wrong. After it types into an app, it watches that text field for fifteen seconds. Change one short phrase inside what it wrote, say "sigma flo" to "SigmaFlow", and that fix becomes a dictionary rule on the spot. A one-line notice appears where the HUD lives:

    sigma flo → SigmaFlow │ Undo

The rule is already saved when the line appears. A hairline along its bottom edge drains over three seconds; click Undo or press ⌥⌫ before it is gone to take the rule back. Rules learned this way carry a LEARNED tag in the Dictionary so you can see which ones you never typed, and delete any the learner got wrong.

Works wherever an app exposes its text through Accessibility, which is Apple's own apps and most native Mac apps. Electron apps and browser fields mostly do not, and there it simply never fires. It reads only the field it just typed into, and stops the moment it has learned one rule. Off switch: Settings ▸ Output ▸ Learn from corrections.

### Say the word instead of typing it
The "When you say" field on the Dictionary page has a microphone in it. Click it, say the word the way you always do, and the field fills with what the engine actually heard, misheard form included. That is the string a rule needs and the one nobody remembers. A small line underneath says which model heard it.

### Snippets
A new page between Dictionary and Styles. Save text you type over and over, give it a short phrase, and say the phrase while dictating: SigmaFlow drops the full text in its place. "my work email" becomes the address; "intro line" becomes the paragraph. Triggers match as whole phrases anywhere in a sentence, case does not matter, and the text can run to as many lines as you like. Two words or more keeps a trigger from firing by accident.

### Your data, portable
Settings ▸ Your data lists exactly what SigmaFlow keeps about you, the file behind each item, and how many of each there are. Export everything writes a folder to your Desktop with your transcripts, dictionary, snippets, styles and settings. On another Mac, Import a folder reads it back and asks whether to merge it into what is there or replace everything. Your Anthropic key stays in the Keychain and is never exported; speech models are downloads and are fetched again on the other side.

### MCP block in Settings
The Claude connection has grown into an MCP block. Claude Desktop has an Add to Claude button and shows CONNECTED once it is done. Claude Code gets a Copy command button. Any other app that speaks MCP gets the helper path and three short steps. Everything still runs on your Mac; nothing is hosted.

## Changed

↳ Hands-free recording (double-tap the hotkey to latch) now also stops when you press any ordinary key, not only the hotkey. Typing means you are done talking. Esc still abandons the recording.
↳ The Test connection button on the Styles page is a real bordered button now, and the result reads ✓ CONNECTED or ✕ with the reason, so you can tell the outcome from the control.
↳ Identity-linked Anthropic API keys work. If your key needs a workspace, paste the workspace ID in the field under the key; the error that used to appear mid-rewrite now tells you exactly that.
↳ Row hover highlights on the Dictionary, Snippets and Transcriptions pages no longer touch the text.

## Fixed

↳ Dictionary rows were drawn offset from their column headers. They sit under them now.
↳ The Anthropic key field gave no sign that a pasted key had been saved. It now shows "Saved to Keychain · ends in xxxx" the moment anything is entered.

## Removed

↳ Reveal dictionary.txt is gone from the Dictionary page. The file is still there, still watched, and still hand-editable; find it under Settings ▸ Your data ▸ Reveal in Finder.

## Notes for upgraders

↳ macOS will ask for your login password once after installing, because the Keychain ties your saved key to the app's signature and the signature changed. Choose Always Allow and it will not ask again for this build.
↳ Learned rules are written to dictionary.txt as a trailing `# learned YYYY-MM-DD` comment. If you also use the Windows port and share a dictionary between the two, its parser has not learned that syntax yet.
