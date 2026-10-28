# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read AGENTS.md first

[AGENTS.md](AGENTS.md) is the hard-won list of "things that look like bugs and are not" —
TCC/code-signing behaviour, the iCloud build race, `MainActor.assumeIsolated`. Don't
rediscover any of it. This file
covers commands, current architecture, and the places the prose docs have drifted.

## Commands

```bash
make            # = make app: build, assemble .app, sign, verify
make build      # swift build only
make run        # build + bundle + launch from the staging dir
make install    # build + bundle + copy to /Applications + launch  ← the normal loop
make dmg        # Release build → SigmaFlow.dmg at the repo root
make clean
```

`Update SigmaFlow.command` at the repo root is `make install` for double-clicking from Finder;
it is how Gokul rebuilds after Claude commits a change. Keep it working when the Makefile
targets change.

**Always build through `make`, never bare `swift build`.** The Makefile redirects the
scratch path and the bundle staging dir to `~/Library/Caches/SigmaFlowBuild`. This tree is
under `~/Desktop`, which is file-provider synced; the sync engine mutates files mid-compile
("input file was modified during the build") and stamps `com.apple.FinderInfo` onto bundle
contents faster than `codesign` will tolerate. If you must call `swift build` directly, pass
`--scratch-path "$HOME/Library/Caches/SigmaFlowBuild/scratch"`.

Tests:

```bash
swift test --filter VectorTests                          # the dictionary test vectors
```

`swift test` needs a real Xcode for the swift-testing `Testing` module. This machine has
only `/Library/Developer/CommandLineTools`, so it fails locally with `no such module
'Testing'` — that is the environment, not the code. CI (`.github/workflows/macos.yml`,
macos-26, since mlx-swift needs Swift 6.3) selects the newest Xcode and is the actual gate. The app target itself builds
fine locally; it's only the test target that needs Xcode.

CI runs `swift test --filter VectorTests` and nothing else on macOS — the app target needs
macOS 26 + Speech, which the runner image lacks. `SigmaFlowDictionary` is a separate,
platform-neutral target precisely so the contract can be tested anywhere.

The benchmark under [bench/](bench/) is its own SwiftPM package; `cd bench && swift run bench …`.

## Architecture

One utterance, end to end, all in [Core/DictationController.swift](Sources/SigmaFlow/Core/DictationController.swift)
(the state machine and the only file that knows the whole flow):

```
HotkeyMonitor (CGEventTap)                     Settings.shared (@Observable, UserDefaults)
      │ press/release/esc/style-key                   │ read per-utterance, not cached
      ▼                                               ▼
DictationController  ── state: idle → starting → listening → finishing → idle
      │
      ├─► AudioCapture ─ AsyncStream<AudioChunk> ─► single drain task ─► TranscriptionEngine
      │                                                                      │
      │                                                          TranscriptionChunk (full text,
      │                                                          not a delta) → HUD
      ▼
 on release:  TextFormatter (rule-based | FoundationModels) → DefaultStyle → DictionaryCorrector
                                                                                   │
                                                                       SnippetStore.expand → RunLog
                                                                        │
                                                                  TextInjector → focused app
```

Load-bearing invariants, all with a failure mode that is silent rather than loud:

- **Audio ordering is explicit.** One `AsyncStream` drained by one task. A `Task` per buffer
  compiles, runs, and produces word-salad transcripts.
- **`runGeneration` is the cancellation token.** Every async tail re-checks it before
  touching shared state, so an abandoned run (Esc, tap fragment, watchdog) can't clobber the
  session that replaced it. Add the guard to any new async tail.
- **Watchdog on `.finishing`** — `min(180, max(30, audioSeconds * 3))`, then abandon with a
  visible reason. A hung batch model must never own the screen forever.
- **`endDictation` refuses re-entry while `.finishing`.** `.finishing` counts as active; the
  window is seconds wide (batch transcription + up to 4s of LLM cleanup) and a second press
  would paste the same utterance twice.
- **The dictionary runs last and unconditionally**, after cleanup, even when cleanup is off.
  Engine biasing only shifts odds; `DictionaryCorrector` is the pass that guarantees.
- **The default style runs before the dictionary**, never after. `Formatting/DefaultStyle.swift`
  (Formal / Casual / the third tile) touches only capitals and punctuation; running it after the
  dictionary would lowercase the names the dictionary just guaranteed. It is skipped when
  cleanup is Off ("typed exactly as heard").
- **Snippets expand after the dictionary**, never before. A trigger the engine mishears gets
  rescued by a correction first ("my work e mail" → "my work email"), and only then matches.
  Swapping the order makes every snippet hostage to the engine hearing its trigger perfectly.
- **`CorrectionLearner` adds when the bar ends; Not now is the only way to stop it.**
  Decided 10 Oct 2026, reversing the September ask-first design (docs/DESIGN-SPEC.md §3,
  "The HUD"). Silence is yes, and that is bearable only because four guardrails hold: the
  bar freezes while the pointer is on the card, the added rule shows ADDED with an Undo for
  two seconds, learned rules carry the LEARNED tag in the Dictionary, and Delete all learned
  is one click. Do not remove any of the four. If repeated undoing shows up, the default is
  wrong, not the timer. Both clocks, the bar and the expiry, are one piece of state on the
  notice's model so the card never flips while the bar shows time left.
- **The saved transcript follows the user's edits** (17 Oct 2026, Gokul: "capture the
  corrected transcript only"). The learner's watch on the field also runs with learning
  off, for 60 s; each settled edit replaces that run's `text` in `runs.jsonl` with what now
  stands in the dictation's place, rewording included. Nothing in between is kept, only
  the latest. It gives up, leaving the last good text, when the text around the dictation
  changes, the dictation is emptied or mostly gone, or much more was typed than said.
  Fields Accessibility can't read (most browsers, Electron) keep the text as typed, and a
  power-mode send is never followed.
- **Nothing is injected when SigmaFlow is the front app** (`!NSApp.isActive`) — that's how
  you test without typing into your own window.
- **Hold to talk on Settings is a preview run** (`DictationController.isPreview`, drawn by
  `UI/OverlayChooser.swift`): the full pipeline, but the panel stays hidden, nothing is typed,
  nothing goes to `runs.jsonl`, and the result lands in `previewText` for the two overlay
  tiles. The push-to-talk key is deliberately not wired to the tiles (11 Oct 2026, Gokul):
  it would bring up the real overlay too, three on screen at once.
- **Power mode sends on release** (`Settings.powerMode`, Right ⌘ push-to-talk only): Right ⌥
  held with Right ⌘ at the moment of release means `TextInjector` presses Return after the
  text lands. The decision is taken in `endDictation` before the latch clears; the monitor
  reads Right ⌥ from the device-dependent bit on every `flagsChanged`, so the ⌘ release event
  already carries it. The Return is posted with no flags (Option-Return is a new line in chat
  apps). Hands-free and previews never send; a sent message is not watched by the learner.
  The overlay label reads REC IN POWER MODE while it holds, with the ordinary dot.
- **`HUDPanel` must never become key** (`.nonactivatingPanel`, `canBecomeKey == false`). If
  it did, the target text field loses focus and there is nothing left to inject into.

### Hotkey grammar

`Core/HotkeyMonitor.swift`, a session `CGEventTap` (Accessibility required — `NSEvent`
global monitors can't discriminate left/right modifiers). Right ⌥ / Right ⌘ ride
`.flagsChanged` and match on the **device-dependent** NX_DEVICE\* raw masks, not
`CGEventFlags.maskAlternate`; the union mask makes a release invisible while the other-side
key is held. Custom combos ride keyDown/keyUp instead.

Hold = push-to-talk. Sub-300ms = a tap, discarded, and arms a 350ms double-tap window that
latches hands-free recording. Esc abandons. Option+1…5 are style shortcuts, dispatched
through `onStyleKey` and ignored while the mic is open. ⌃⌥M toggles a meeting recording
(`onMeetingKey`) — a separate pipeline from dictation, see Meetings below. ⌃⌥N opens and stops
live notes (`onNotesKey`), see Live notes. The Meetings page
shows the shortcut under Record meeting. The right-hand modifier that isn't push-to-talk
(`WriteKey`: Right ⌥, or Right ⌘ when Right ⌥ is push-to-talk) holds Autowrite open, see
below; down while push-to-talk is already held it is Power mode's companion instead.

### The two protocol seams

- `TranscriptionEngine` (actor) — `preferredInputFormat / start / feed / finish`.
  Implementations: `AppleSpeechEngine` (SpeechAnalyzer, macOS 26, no download),
  `ParakeetEngine` (FluidAudio/CoreML, batch), and `UnifiedEngine` / `NemotronEngine` /
  `CohereEngine` in [ModelEngines.swift](Sources/SigmaFlow/Transcription/ModelEngines.swift).
  `SpeechModelID` in [ModelCatalog.swift](Sources/SigmaFlow/Transcription/ModelCatalog.swift)
  is the catalog; `SpeechModelStores` maps a model to download / warm / engine; `ModelLibrary`
  owns on-disk state and download progress. Adding a model means touching exactly those three.
- `TextFormatter` — `RuleBasedFormatter` (deterministic, always the fallback) and
  `FoundationModelFormatter` (on-device LLM, gated by `Settings.smartCleanup`).

Engines are constructed **per utterance** from the current setting, so a picker change
applies on the next hold with no restart. Note `engineForCurrentSetting` is at file scope,
not a static on the `@MainActor` class, so it can be `@Sendable`.

The engine dictates the capture format: SpeechAnalyzer *crashes the process* on non-int16
input, so `preferredInputFormat` is asked before the mic opens, never assumed.

Compare mode (one recording replayed through every engine, results side by side) was removed
on 6 Sep 2026 as a feature nobody used past setup. Old `runs.jsonl` lines may still carry a
`group` key; the decoder ignores it. Don't rebuild it as a mode — if the question "which
model is faster?" comes back, answer it from the timings already in the run log.

### Media pausing

`Core/MediaPauser.swift` + `Sources/SigmaFlowMediaHost/MediaHost.c`. MediaRemote refuses
unentitled processes since macOS 15.4, so the query and the pause/play commands run inside
`/usr/bin/perl`, which loads the C dylib from `Contents/Frameworks`. One process per command,
one-word protocol (`status` / `pause` / `play`), documented in the C file. AGENTS.md has the why.

### Styles

[Styles/](Sources/SigmaFlow/Styles/) — a named prompt + composable `StyleRule` toggles +
few-shot examples of the user's own writing, bound to Option+1…5. `SelectionRewriter` reads
the selection by synthesizing ⌘C (there is no cross-app "read selection" API), watching the
pasteboard's `changeCount` rather than its contents, then pastes the rewrite back and
restores what was there. `StyleRewriting` has three backends (`StyleEngineChoice`): Apple
FoundationModels on-device, the Anthropic API, or OpenRouter's free-model router
(`openrouter/free`, never a paid model). Both cloud calls go through
`Support/CloudTextClient.swift` with the user's own key from `Styles/Keychain.swift`; an
Anthropic key tied to a workspace also needs the workspace ID stored beside it. 30s timeout,
and on any failure the user's text is left untouched.

Provider marks on the Styles page load from `Resources/ProviderMarks/` as template images,
so they render in the current ink and stay inside the monochrome rule.

### Meetings

**Back on 13 Oct 2026, deliberately small** (Gokul: "do the simplest thing beautifully, then
make it better little by little"). Three things only: record a meeting, it is transcribed on
this Mac the moment you stop, and the audio and transcript sit together in a folder you can open
without the app. Spec: [docs/mockups/meetings-simple.html](docs/mockups/meetings-simple.html),
picks 1C 2A 3B 4A 5D 6A. Lenses, meeting types, automatic titles, a player and Sarvam were all
removed on purpose; each comes back only as its own ask (speaker names came back that way
on 14 Oct 2026, automatic titles on 16 Oct 2026). Don't add features
here "while you're in there".

It is a **second pipeline that shares nothing with dictation** — different capture, different
engine, different storage. Don't unify them: dictation is latency-bound and streaming, this is
throughput-bound and batch.

```
MeetingSession (page button / ⌃⌥M)  ─►  MeetingRecorder ─► staging .m4a (Application Support)
a file dropped on the page  ─►  MeetingImport (a copy, 16 kHz mono AAC) ─┘
                                              │ Stop: moved into the SigmaFlow folder
                                              ▼
MeetingLibrary.file ─► MeetingLibrary.transcribe (one at a time) ─► MeetingProcessor
      Parakeet V3, whole file, word timings ─► MeetingRouting (Tamil? see below) ─┐
      OfflineDiarizer, whole file  ───────────────────────────────────────────────┴─► words to speakers ─► rows ─► <name>.md
```

- **The folder is the record.** `~/SigmaFlow/Meetings/<yyyy>/<MM Month>/<name>/` holds
  `<name>.m4a` and `<name>.md` (plus `Photos/` and `Screens/` folders for live notes),
  nothing else, no database anywhere. `MeetingLibrary.reload()`
  rescans on page appear and app activation, so a Finder rename, move or delete is the app's
  rename, move or delete. The .md is parsed back for the page (`MeetingMarkdown`), so a hand
  edit shows up in the app too. Keep the format round-trippable.
- **The SigmaFlow folder lives in the home folder, not Documents**: Desktop and Documents sync
  to iCloud on Gokul's Mac, and meetings must not leave it unless the user moves the folder into
  a synced one. It is found by a bookmark (`Settings.sigmaFlowFolderBookmark`); when it cannot
  be found the app says so and asks (Find it), and never makes a new empty folder behind the
  user's back. Created on the first launch.
- **Record outside, move at Stop.** A synced folder must never see a growing file. A staged
  file left by a quit or crash is filed at the next launch (`recoverUnfiled`), with Try again.
- **Dropped recordings** (15 Oct 2026, [docs/mockups/meeting-drop-audio.html](docs/mockups/meeting-drop-audio.html),
  picks 1A 2B 3A 4B): any file AVFoundation can open (video too, sound only), dragged onto the
  list page, becomes a meeting dated the moment it was dropped, titled with the file's name,
  and transcribed like a recording. `MeetingImport` converts a **copy** into the recorder's
  exact format (`MeetingRecorder.fileSettings`), staged as `<uuid>.import.m4a` and moved in;
  the original is only read. Mono on purpose: a two-channel file reads as a call
  (`MeetingAudio.isTwoSided`) and would be split down the middle. Ogg and Opus can't be
  opened and say so. The drop target is left off in snapshot runs (the renderer paints it as
  its "unsupported" stand-in over the whole page).
- **Four ways in besides the drop** (28 Oct 2026, [docs/mockups/meeting-drop-discover.html](docs/mockups/meeting-drop-discover.html),
  picks 05 15 16 17 19; Figma 3.1 to 3.22, 3.7, 0.19): **Upload meeting** (Carbon `upload`) beside
  Record meeting opens a file picker into `MeetingLibrary.add(recordings:)`; the drop veil names
  the held file and its length, read off the system's drag pasteboard (`MeetingImport.dragged`);
  a file dropped on the **Dock icon** or opened with SigmaFlow (`CFBundleDocumentTypes`, audio and
  video at Alternate rank, so never the default app) and Finder's right-click **Transcribe with
  SigmaFlow** (an `NSServices` entry; `AppDelegate.transcribeRecordings`) both file it and bring
  Meetings forward, opening the window through `openMainWindow` if it was closed; and the first
  open ends on a Meetings step whose right tile takes a real drop. `make install` re-registers the
  app with Launch Services and refreshes the Services menu, or neither shows up. Where Finder lists
  the service (Quick Actions or Services) depends on macOS; a true Quick Action needs an app
  extension, which SwiftPM can't build.
- **Names**: `[ 13 Oct ] Tue 2.30 pm - 48 min`, English, en_US_POSIX; a rename keeps that and
  adds ` - <title>` (`MeetingNaming`). Renaming moves the folder, both files, and the .md's
  heading and Audio line.
- **Transcription is whole-file, then joined.** Parakeet V3 hears the entire recording once
  (disk-backed for long files) and returns word timings; FluidAudio's **offline** diarizer
  reads the whole file separately; each word goes to the voice talking at its midpoint. The
  earlier version sliced audio per speaker stretch and saved empty transcripts, and the live
  `DiarizerManager` merged the two main voices of a 115-minute meeting into one. Measured on
  this Mac: 115 min in about 100 s, about 1 GB peak.
- **The file is the recording.** `MeetingRecorder` streams straight to AAC 32 kbps @ 16 kHz
  mono, nothing buffered in memory. Same real-time-thread contract as `AudioCapture`: tap
  state sits behind `nonisolated(unsafe)` and is touched only there.
- **Speaker names** (14 Oct 2026, [docs/mockups/meeting-speaker-names.html](docs/mockups/meeting-speaker-names.html),
  picks 1B 2B 3B): the speakers sit in a row under the title; click one, type, Return renames
  every line of that speaker in the .md, an empty name goes back to its number. Names look the
  same as numbers. Two speakers given one name stay two: the `Speakers:` line is written at
  transcription and never recounted from labels.
- **Named voices are remembered, invisibly** (Gokul: a hidden feature, nothing in the UI).
  `VoiceMemory` keeps one voiceprint (the offline diarizer's cluster centroid) per named voice
  per meeting in `Application Support/SigmaFlow/voiceprints.json`, rebuilt for that meeting on
  every rename by diarizing its audio again and matching clusters to the renamed rows. Every
  transcription after that names a voice at cosine 0.72+ and 0.1 ahead of the next name.
  Measured on Gokul's recordings: same person a day apart 0.74 to 0.80, different people in one
  room 0.57 to 0.68, so the margin is thin; a missing name beats a wrong one. `voices.json`
  beside it belongs to the old Meetings page; don't touch it.
- **Open problem, raised by Gokul 14 Oct 2026**: lines tagged to the wrong speaker. One
  laptop mic in a room of five came out as two voices. No plan yet; bring it up when Meetings
  work resumes.
- **Play plays inside SigmaFlow** (`MeetingPlayer`, AVAudioPlayer). It used to hand the .m4a
  to the default app, which on Gokul's Mac is Music: sound with no window and nothing to stop
  it (16 Oct 2026). Never open audio with `NSWorkspace.open`. Since 20 Oct 2026
  ([docs/mockups/conversation-playback.html](docs/mockups/conversation-playback.html), picks
  2A 3A 4A 5B; Figma 4.21 and 4.22) it is one button: Pause and the time, then Play and the
  time carries on from there; leaving the transcript stops it and forgets the place. The line
  the sound is in is filled like a search moment and always scrolled into view. A click
  anywhere on a line plays from its time; a drag still selects words. That click is
  `ClickArea` (UI/PhotoPeek.swift), an app-wide mouse watcher, because selectable `Text`
  swallows the release and SwiftUI's tap gestures never hear it.
- **Deleting is hard to find on purpose** (16 Oct 2026, [docs/mockups/delete-recordings.html](docs/mockups/delete-recordings.html)
  round 2; Gokul: making delete easy is "a stupid product decision"). Faint text in the
  card's fixed footer, under the rows and never scrolled with them (18 Oct 2026), turns tick
  boxes on (Transcriptions too, which adds Select all and keeps Delete on every row); a transcript's delete sits after its last line; a
  picture's is a faint bin on its hover view, which waits `DS.Motion.peekLinger` for the
  pointer. Nothing on rows, nothing near Play. Every delete stops at `DeleteQuestionView`
  (centred, Cancel is default for Return and Esc, Delete live after `deleteArm`). Files go
  to the Mac's Trash and Undo shows for `undoHold`; the UI never says "Trash". A picture's
  delete edits only its mark out of the .md (`MeetingLibrary.removing`). A deleted meeting's
  voiceprints are set aside and restored by Undo.
- **Automatic titles** (16 Oct 2026, Gokul: apply it, four to six words).
  `MeetingTitler` asks Apple's on-device model once a transcript is written, then renames
  through `rename`, exactly like a typed title. Only a meeting still under its date name
  (`Meeting.hasDateName`, " 2" included) is named, checked again when the title comes back;
  a dropped file already has its file name as title. Tamil and English recordings go to
  Gemma 4 E2B instead (20 Oct 2026, pick 1A; Apple's model refuses Tamil), only when search
  has already downloaded it, after waiting like `PictureReader`: up to 40,000 characters in
  even pieces, an English title. The 29 minute Tamil conversation took 7 s, 1.5 GB.
  `SigmaFlow --title-check FOLDER` prints the title a recording would get, renaming nothing.
  For English, up to 3,000 words go in whole; longer ones are read in
  2,000-word pieces, one topic line each, then titled from the topics (Gokul asked for 30
  minute pieces; that is past the model's window). About 1 s per 1,000 words. No model,
  no title. `meeting(_:)` follows the rename so an open transcript stays open.
- **The list's footer shows where the files are** (27 Oct 2026, [docs/mockups/meetings-folder-path.html](docs/mockups/meetings-folder-path.html),
  picks 1B 2C 3C 4B; Figma component Path bar): `PathBar` (UI/Equipment.swift), Home › SigmaFlow ›
  Meetings at the left, as faint as Delete, on Conversations too. Each part shows that folder
  selected in the one around it (`activateFileViewerSelecting`), so the last part opens the
  SigmaFlow folder with Meetings selected; Home opens Home. It stays while ticking and after a
  delete, the count moving beside the buttons; none while the folder can't be found.
  Transcriptions has the same, Home › SigmaFlow › Dictations (`RunLog.dictationsFolder`).
- **Progress and failures live only in memory.** After a relaunch, an .m4a with no .md beside
  it shows Try again.
- `--snapshot-dir … --pages meetings/transcript` draws the newest meeting's transcript.
- `SigmaFlow --transcribe-meeting AUDIO OUT.md [--language english|tamil]` transcribes a file
  exactly as Stop does and quits, instead of starting the app: no hotkeys, no call watching,
  no SigmaFlow folder. Safe to run beside the installed copy.

**Tamil** (13 Oct 2026, [docs/mockups/meeting-language.html](docs/mockups/meeting-language.html),
picks 1B 2B 3A 4B). Parakeet has no Tamil, so Tamil-English meetings came out as English
nonsense. Tested on a real 12-minute meeting against Whisper large-v3 (14 to 18 min, loops,
invents polite Tamil), Meta Omnilingual 1B (fast, drops letters; 3B swaps this Mac to a halt)
and Apple (no Tamil at all on this Mac); AI4Bharat's IndicConformer 600M won. Sarvam is out:
no key. All of it stays on this Mac.

- `MeetingRouting` (in `MeetingLanguage.swift`) cuts each side into 4 to 8 s stretches at the
  quietest 100 ms, raises the level (that meeting sat at -44 dB) and asks `LanguageCheck` per
  stretch. A meeting is Tamil when at least 10% of stretches are Tamil at 0.9+ (that meeting
  24%, an Indian-accented English one 0%). Cutting at pauses alone failed on non-stop talk.
- In a Tamil meeting a stretch stays Parakeet's when Parakeet's mean token confidence is 0.85+,
  the check gives Tamil under 0.5, and Parakeet heard at least 0.7x IndicConformer's words:
  a whole English sentence. Every other stretch is `TamilSpeech`'s. English words inside a
  Tamil sentence come out in Tamil letters; that is the model, accepted.
- `LanguageCheck` is SpeechBrain VoxLingua107 ECAPA (Apache 2.0), converted to CoreML and
  shipped as `Resources/LanguageCheck/LanguageID.mlpackage` (41 MB float16; int8 changed 2 of 133
  calls). CPU only: its pooling shape follows the input length, which the GPU path refuses.
  It never hears Indian English as English, hence Parakeet's confidence for that side.
- `TamilSpeech` is the CoreML copy `phequals/indic-conformer-600m-multilingual-coreml-rnnt`,
  revision pinned, 0.6 GB, downloaded to `Application Support/SigmaFlow/Models/IndicConformer/`
  the first time a meeting is heard as Tamil, never otherwise. Offline then, the meeting keeps
  Parakeet's transcript and Transcribe again retries. Three things that look like bugs:
  the prediction net takes the Tamil head's own token id (0 to 255), not the shared id, or it
  repeats every sound ten times; the INT8 model hears nothing in some windows depending only on
  the start offset, hence the nudge-then-split retry (empty stretches 13 to 4); and every
  prediction leaks an IOSurface into the autorelease pool unless each step has its own pool
  (the first 12-minute run crashed). The front end is NeMo's, matched to the TorchScript to 5e-6.
- Speed: 12 min in about 53 s in the debug build `make install` makes, 38 s in release.
  The hot loops are vDSP so a debug build is not 3x slower; keep them that way.
- The .md has `Language: English` or `Language: Tamil and English`, shown beside Speakers.
  Transcribe again (a ghost menu on the transcript bar) redoes a meeting the other way and
  replaces the .md, hand edits included, with no Undo (Gokul, 4B).

**Calls** (13 Oct 2026, [docs/mockups/meeting-call-detect.html](docs/mockups/meeting-call-detect.html),
picks A A A B):

- `CallWatcher` polls Core Audio's process list every 2 s for a call app reading the mic
  (bundle-id prefixes for Zoom, Teams, FaceTime, Slack, Webex, Discord; never WhatsApp or
  Telegram, whose voice notes would ask; never SigmaFlow itself). **Any browser** counts:
  a process is known by the outermost `.app` it sits in, and that app is a browser when it
  is on the list of about 25 or Launch Services says it opens https links. Safari's mic
  is held by `com.apple.WebKit.GPU`, which sits in no app; it is named after the browser
  in front. Until 19 Oct 2026 browsers matched by the helper's own label, case-sensitively,
  and Dia (`company.thebrowser.browser.helper`, lowercase b) never asked once. A call ends
  when its app has let go of the mic for 5 s. `CallPrompter` shows `CallPromptPanel` above
  the Dock: the app's name, "Record this meeting?", Record meeting / Not now. It stops a
  recording it started when that call ends; a recording started by hand never auto-stops.
  `Settings.askToRecordCalls`, on by default, on the Dictation tab.
- **Every** meeting recording also runs `SystemAudioTap`: a Core Audio process tap on
  everything the Mac plays except SigmaFlow, so the other side is heard even through
  AirPods. Needs `NSAudioCaptureUsageDescription`; refused, it records silence and the
  meeting is the mic alone. At Stop a call side that heard anything is merged with the mic
  into one stereo file (`MeetingAudio`): **mic left, call right, never mixed**.
- A two-sided file is transcribed per side, and **both** sides are diarized: everyone is
  Speaker 1, 2, 3, numbered across both sides by first word. The mic side is not labelled
  with the user's name: any sound the Mac plays makes a room meeting two-sided, and on
  14 Oct 2026 that put five people in a room under "GRJ" (Gokul asked for numbers instead).
  Echo through laptop speakers is removed word by word (a mic word the call side also has
  within 1 s goes). Rows break at 1.5 s pauses.
- UI copy here is titles and buttons only. No how-it-works, privacy or consent lines
  (Gokul, 13 Oct 2026, emphatically).

Old recordings from before 13 Oct 2026 are still under `Application Support/SigmaFlow/Meetings/<id>/`
with `meeting-types.json` and `voices.json` beside them. Nothing reads them; moving any of them
into the SigmaFlow folder is Gokul's call, recording by recording.

### Live notes and Conversations

**Conversations** (16 Oct 2026, [docs/mockups/notes-home.html](docs/mockups/notes-home.html),
picks 1B 2C, photos C+D, logo 05 A) is live notes' home: its own sidebar page under Meetings
(Carbon `notebook`), its own folder `~/SigmaFlow/Conversations/<yyyy>/<MM Month>/<name>/`, laid
out exactly like Meetings. `MeetingLibrary.conversations` follows `MeetingLibrary.shared` for
the SigmaFlow folder; both reload when the app comes to the front. The page is `MeetingsPage(kind:
.conversations)`: Take notes and ⌃⌥N in place of Record meeting, no recording drops, and each row
shows `PhotoStacks` before Open transcript: three stacks, up to nine photos picked at random
(a seeded shuffle, renewed each time the page appears, still while you look), dealt one to each
stack in turn, +N for the rest; the photo under the pointer rises and comes to the front. The
list reads 96 px copies (`ThumbCache.small`), never the full photos. The transcript view takes
the library it belongs to and names its back button after the page. A notes recording left by a
quit is filed as a conversation (its `.photos`/`.screens` staging folders give it away).
Conversations recorded before this page sit in Meetings; each moves only with Gokul's yes.
The sidebar's wordmark has the app icon beside it, as a rounded tile with a thin edge.

### Live notes

16 Oct 2026, [docs/mockups/live-notes.html](docs/mockups/live-notes.html) (picks across five
rounds; the final ones are in the mockup's header). ⌃⌥N opens a card in the top right corner
that writes down a conversation **in the room** as it happens; Stop files it as a meeting.
Built in steps, each installed for Gokul to try: (1) the card, live English, Stop to a meeting;
(2) Tamil a line at a time; (3) a camera photo every 30 s; (4) screenshots, Right ⌘ + S;
(5) dictation alongside with dictated words left out. All five exist (16 Oct 2026).

- **Microphone only, never the call tap.** Calls are Meetings' job (Gokul: "strictly for
  in-person conversations"). Notes and a meeting recording refuse to run at the same time.
- `NotesSession` records with `MeetingRecorder` into the staging folder (so a crash leaves a
  file `recoverUnfiled` turns into a meeting) and hands every 16 kHz buffer, through one
  `AsyncStream` drained by one task, to `NotesTranscriber`. Stop files the audio exactly as a
  meeting's Stop does and transcribes it again whole; the live lines are a draft and are not
  saved.
- `NotesTranscriber` owns its **own** `StreamingUnifiedAsrManager`, loaded at ⌃⌥N and released
  at Stop. Dictation's shared one (`UnifiedModels`) holds one conversation's state and can't
  serve both. Measured: 515 s of speech decoded in 33 s, 155 MB peak with both loaded.
- **Lines follow the voice, not the words.** Silero VAD (FluidAudio, threshold 0.5, 1 s of
  silence ends a line; Gokul asked for 1 s, a meeting's rows use 1.5) opens and closes lines,
  and each English token goes into the line it was spoken in. Tested on the 13 Oct Tamil
  meeting: Parakeet Unified writes nothing at all for long Tamil stretches, so lines made
  from its words left whole minutes out. A word piece without a leading space follows the
  previous piece's line ("cust" + "omer"). A long line ends at a sentence end after 12 s,
  and anywhere after 20 s. The VAD model downloads (a few MB) the first time notes open.
- **Tamil, a line at a time** (step 2). Once a line has ended and 2 s have passed (the
  streaming model hears about a second behind), its audio, raised to -20 dB as
  `MeetingSamples` does, goes to `LanguageCheck`. Surely Tamil (0.9+), or maybe (0.5+) with
  Parakeet unsure (<0.85): IndicConformer hears the line and replaces it. From the second
  surely-Tamil line on, the conversation is Tamil and every line follows `MeetingRouting`'s
  rule (English only for a confident, whole English sentence), and lines already left as
  English are heard again while their audio is kept. While a line is spoken, the check runs
  every 2.5 s; once surely Tamil, its English guess gives way to grey blocks, one per second
  of speech, until the Tamil lands (2.5 s alone is too little: 0.00 at 2.5 s for a line that
  was 0.93 whole). Three dots read as stopped; the blocks, with no word saying Tamil, were
  Gokul's pick ([docs/mockups/live-notes-tamil-wait.html](docs/mockups/live-notes-tamil-wait.html), round 1 C). On that meeting: 55 of 68 lines
  Tamil, the first line matching the saved transcript; English recordings: 0 lines Tamil.
  740 s decoded in 48 s, 274 MB peak. Audio is kept only back to the oldest undecided line.
- `NotesPanel` never becomes key, like the HUD: the app in front keeps the keyboard. Fixed
  width, the height is the user's (the bar at the bottom), the status row drags it; it reopens
  where it was left for the rest of that run. Pause stops writing and feeding, so the file and
  the line times share one clock with no gap.
- The line being spoken uses the dictation overlay's `WordFlowText` (one word every 130 ms,
  blurring in); older lines pass `returning`, so a line scrolled back into view doesn't replay
  its entrance. The HUD never passes it.
- **The cursor needs a private switch.** macOS ignores `NSCursor.set()` from an app that isn't
  in front, which SigmaFlow never is while the card floats over someone's work (tested 16 Oct:
  nothing changed). `NotesPanel` turns on SkyLight's `SetsCursorInBackground` for our own
  connection, and `CursorArea` tracking views set the open hand (move) and up-down arrows
  (height). Without the switch everything works; the cursor just doesn't change.

- **Camera photos** (step 3): `NotesCamera` runs the camera the whole time it is on (the
  green light is honest) and takes a photo at 2 s, then every 30 s of recording; each is
  shrunk to 960 px JPEG (about 100 KB) into `Recording/<id>.photos/00-30.jpg`. The camera
  button starts on at every ⌃⌥N and is faint while off. At Stop, `MeetingLibrary.movePhotos`
  renames them `[ 16 Oct ] Fri 10.32 am - 00-30.jpg` into `<meeting>/Photos/`; renaming the
  meeting changes none of them. A photo belongs to the row being spoken when it was taken
  (the last row starting at or before it; the first row takes earlier ones), the same rule
  on the card and in `placingPhotos`, which reads the Photos folder every time a transcript
  is written, so Transcribe again keeps them. The .md carries them in the time cell,
  `| [00:30] ![](<Photos/… - 00-30.jpg>) | **Speaker 1:** … |`, so any Markdown app shows
  them; the row parser and speaker rename were changed to read past it.
- `PhotoThumb` / `PhotoPeek` (UI/PhotoPeek.swift): hover a photo and a 256×160 view opens
  in its own small window, left of the notes card or right of a transcript row, so nothing
  clips it. Hover tracking uses `PointerArea` (`.activeAlways`), because SwiftUI's hover
  doesn't fire while SigmaFlow isn't the app in front. Snapshot runs leave the tracker out.
  Hardened runtime: the camera needs `com.apple.security.device.camera` and
  `NSCameraUsageDescription`.
- **Screenshots** (step 4): `NotesScreen` (ScreenCaptureKit) captures the screen the pointer
  is on with SigmaFlow's own windows excluded, so the card never covers what was shown. JPEG,
  1920 px at most (a Retina PNG every 15 s would pass a gigabyte an hour). The laptop button
  turns one every 15 s on (off at every start); a timed one identical to the last (32×20 grey
  print, mean difference under 2) is not kept. **Right ⌘ + S** takes one whenever, only while
  notes are open (`HotkeyMonitor.onScreenshotKey`, device bit, so Left ⌘ + S stays Save).
  Right ⌘ is also the push-to-talk key: its press has already begun a dictation, so
  `DictationController.screenshotKeyPressed` cancels it, ignores the coming release, and
  clears the double-tap window (two quick screenshots must not latch hands-free). The HUD can
  flash for a moment; Gokul accepted that and may ask for another key later. Screenshots are
  rows of their own (`MeetingLine.screens`, empty text, no speaker), `| [00:45] | ![](<Screens/…>) |`
  in the .md, put back by `placingScreens` after `placingPhotos` every time a transcript is
  written; photos never attach to a screenshot row. Screen Recording is asked for at the
  first press of the button or the key.
- **Dictating while notes run** (step 5, 7B): both work at once, each with its own mic
  engine and its own Parakeet Unified copy; the HUD shows above the Dock as always. While
  dictation's mic is open (`DictationController.state` is `.starting` or `.listening`, a
  `didSet` tells `NotesSession.dictationChanged`), `MeetingRecorder.isMuted` writes zeros in
  place of sound: the line never appears live, the saved meeting (transcribed from the file)
  has no words there, and the file holds nothing of what was dictated. The clock runs on, so
  photo and screenshot times stay right. Anyone else talking meanwhile is left out too
  (accepted). The card's meter falls flat while muted.
- The card's row holds four buttons beside REC, timer and meter in 400 pt, so its buttons
  are `AppButton(compact: true)` (26 pt) and the meter has 6 dots.

### Insights

A second tab on Transcriptions (History | Insights, 18 Oct 2026,
[docs/mockups/insights.html](docs/mockups/insights.html), picks 2A 3A 5A 7A 8B, 9A 10B 11B 12B).
`Support/UsageInsights.swift` works the numbers out from `runs.jsonl` every time the tab draws,
nothing stored; `UI/InsightsView.swift` draws three cards (rethought 21 Oct 2026,
[docs/mockups/insights-revamp.html](docs/mockups/insights-revamp.html), A written as A1 Plain):
Today, a year of GitHub-green squares headed by the time saved a day, and a
bookcase of 31 famous books (`FamousBook.all`, covers in `Resources/BookCovers/`, from Open
Library, which belong to their publishers). Time saved is words at 40 a minute less talking and
waiting. Dictations only, never meetings.

- **Fun facts, never goals** (Gokul, angrily, 18 Oct 2026): no streak, no "next book", no
  progress colour, no Matched label, nothing that drops after a missed day. The covers are all
  black and white; books shorter than the user's words are bright, longer ones dark.
- **A shelf must never be wider than the width it was measured from.** The window's
  `.contentMinSize` grows the window to fit rigid content, so a gap computed from the width that
  overshoots by a point widens the window, which widens the gap: an endless layout loop that
  freezes the app on launch. Widths are read off an empty strip, gaps round down.
- **Today leads** (21 Oct 2026, Gokul: people hold today and this week, not 3,574): "SigmaFlow
  wrote 97% of your words today", then the day as a sum, written with SigmaFlow + typed by you
  = your words today, then "Without SigmaFlow, you'd have typed all N" and how long that would
  have taken at 40 a minute. Never "you said": the words are SigmaFlow's. The all-time words and
  dictations live in the bookcase's sentence; the squares' heading is the time back a day, with
  the working under it in three numbers that add up (`UsageInsights.averageDay`). The four
  tiles, words a minute and the next-100,000 line are gone.
- **Typed words**: `Support/TypedWords.swift` counts typing from `HotkeyMonitor`'s tap
  (`onTyping`), which already sees every key in every app: a word is letters then a space,
  Return, Tab, an arrow or a ⌘/⌃ shortcut, as a dictation's words are counted by spaces; Delete
  back into a word just ended uncounts it. Only the number is kept, one a day, in
  `typed-words.json`, never the keys. Password fields never reach the tap (Secure Input).
  SigmaFlow's own keys (the paste, Power mode's Return, a style's ⌘C) carry
  `TypedWords.ownEventMark` in `eventSourceUserData` so they never count; a new synthesized key
  must carry it too. Always on, no switch. Counting began 21 Oct 2026.

### Search

Meetings and Conversations search by meaning, and a conversation's photos and screenshots by
what is in them (19 Oct 2026, [docs/mockups/picture-search.html](docs/mockups/picture-search.html),
picks 01 B 02 A 03 B 04 A 05 B; the 18 and 19 Oct tests are in memory, not the repo). Gokul's
test case: ten conversations, two with a red t-shirt, "red t-shirt" must find both.

- **Three readings of every picture**, by `Search/PictureReader.swift`, quietly after each
  transcript is written and for older recordings after launch: the words on it (Apple
  Vision, `PictureText`; exact for codes like INV-20431, blind to Tamil), what is in it
  (`PictureDescriber`, Gemma 4 E2B 4-bit in MLX, about 2 s a picture, 4 GB while loaded, let
  go after), and how it looks (`SearchEncoder`, EmbeddingGemma 2, text and pictures in one
  768-number space). Descriptions alone missed one of the two red t-shirts; the look found
  both. Every spoken line gets a vector too. Nothing shows while it works (04 A); it waits
  while a recording, notes, a transcription or dictation runs.
- **The index is a cache**: `Application Support/SigmaFlow/Search/<Meetings|Conversations>/<date
  name>.json` (`SearchIndex`), line vectors keyed by the words, pictures by path and file
  size. Deleting it costs a re-read. **The descriptions are also the .md's image text**,
  `![a whiteboard with …](<Photos/…>)` (`MeetingMarkdown.image`/`images`/`describing`): written
  only where a picture has none, so a hand edit wins and is what search uses. The MCP
  helper parses and searches them too; keep both parsers in step.
- **Scoring** (`SearchIndex`): exact words always count; by meaning, a moment counts at
  0.70 and up and within 0.08 of the search's best; a picture's look is lifted 0.06 before
  comparing (it runs lower than words). Tuned with `--search-check`; retune there, not by eye.
- **The list** stays a list of recordings; up to three moments under each, best first then
  in time order, then "N more" in place. A picture opens large (`PictureViewer`), Go to this
  moment opens the transcript there with the row filled; a line opens it directly. The
  exact words answer at once, meaning after `DS.Motion.searchPause`.
- **Models**, downloaded on first need into `Application Support/SigmaFlow/Models/`, pinned:
  EmbeddingGemma 2 (FluidInference's Core ML copy, 0.9 GB, text and vision only; the first
  load compiles for the Neural Engine, about 90 s once), Gemma 4 E2B (3.3 GB, only once a
  recording has pictures), and MLX's GPU kernels (64 MB). **SwiftPM on the command line
  cannot compile Metal**, so `mlx.metallib` comes from the PyPI wheel `mlx-metal` of the
  exact MLX version mlx-swift is built on (mlx-swift 0.32.3 = MLX 0.32.2), and
  `mlx_metal_set_metallib_path` points MLX at it before any operation. Bumping mlx-swift
  means bumping that wheel's URL and checksum with it. The Makefile builds C and C++ with
  -O2 even in debug: MLX at -O0 is several times slower.
- `EmbeddingGemma2Tokenizer.swift` and the text half of `EmbeddingGemma2.swift` are adapted
  from FluidInference/FluidUse (Apache 2.0); the picture half follows the model card and
  matches sentence-transformers to cosine 0.997.
- `SigmaFlow --search-check FOLDER QUERIES.txt [--raw]` reads every recording under FOLDER as
  the app does, writes descriptions into those .md files, and prints each query's moments with
  scores. Its index is `Application Support/SigmaFlow/SearchCheck`; point it at a copy.

### First open

19 Oct 2026, [docs/mockups/onboarding.html](docs/mockups/onboarding.html) round 6, picks 1A 2B
3A 8E. A fresh install opens on a setup window of its own (`UI/OnboardingView.swift`, logic in
`Support/FirstOpen.swift`), a SwiftUI `Window` scene with id `welcome`; the main window's
launch is suppressed until `Settings.firstOpenDone`. Steps: Welcome, Two quick permissions,
Hold Right ⌘ and talk, Tap Right ⌘ twice (hands free), the folder, Meetings, two ways (28 Oct
2026: record one, or drop a file on the right tile to file it as a meeting), then Open SigmaFlow
lands on Transcriptions, or on Meetings when a recording was dropped. Onboarding is the one place a step carries a line or two under its title.

- **The talking steps are real dictations**, not previews: SigmaFlow is in front, so the
  overlay shows, nothing is typed, and each run is saved, which is why the app opens with
  them as its first transcriptions (8E). `DictationController.lastLanding` tells the window
  what landed and whether it was hands free.
- **Parakeet Unified EN downloads from launch, never named** (Gokul, 18 Oct 2026), and becomes
  the model unless another was picked meanwhile. Until it lands, `waitsForModel` holds the key
  back and the field shows a nameless line (2B); a failed download offers Try again and lets
  Continue through.
- A first open also makes Right ⌘ the key (the default otherwise is Right ⌥) and does not
  fire the system Accessibility prompt at launch; the permissions step asks instead and
  brings the window back to the front once the switch is on.
- An install that already has a remembered page counts as set up. App menu: Welcome to
  SigmaFlow opens the window again, changing nothing.
- Draw it: `--snapshot-dir DIR --pages welcome/welcome,welcome/talk` (steps: welcome,
  permissions, talk, handsFree, folder, meetings). Run it as a fresh install without touching settings:
  `-firstOpenDone NO -ApplePersistenceIgnoreState YES` on the staged binary (restored windows
  skip the launch rules).

### Autowrite

23 Oct 2026 as Write for me, renamed **Autowrite** on 26 Oct 2026
([docs/mockups/write-a-reply.html](docs/mockups/write-a-reply.html): round 1 picks 1A 2B 3B 4C 5B
reframed it; round 2 1A 2A 3B 4A; round 3 1-19 2-A 3-C 4 = 01+09+11). Hold the write key and
say what you want written ("reply to Priya, Thursday works but not before eleven"); SigmaFlow
reads the screen and types the writing where the cursor is. It never presses Return.
`Core/Autowrite.swift` holds the key, the screen, the prompt and the engines;
`DictationController` runs it as a dictation whose transcript is the ask (`isWriting`).
**Figma is behind** (still Write for me, still the try): the Figma connector was down on 26 Oct
2026; redraw section 8 and O6 from the app when it is back.

- **You can tell it from a dictation three ways** (round 3, 4-01, 4-09, 4-11): a pen in place of
  the dot and AUTOWRITE in place of REC; the screen it read, small, beside your words
  (`screenPicture`, from the same capture the engine gets, so it appears a beat after the key);
  and `UI/Spotlight.swift`, a click-through window per screen that dims everything but the front
  app's front window from the moment the key counts until the writing lands or is copied. The
  spotlight is SigmaFlow's own window, so the capture never has it in. It lights the window the
  words go into; the capture is still the whole screen under the pointer, which the picture shows.
- **The page** (27 Oct 2026, [docs/mockups/autowrite-page.html](docs/mockups/autowrite-page.html),
  round 1 1-03 2A 3A, round 2 B down the page, round 3 words): four numbered steps down the
  left, on the painting with no card (click where the text should go; hold the key and say it;
  let go; check it and send it yourself). **Steps never get a card; only what you can change
  does** (Gokul: one look for two things confuses). On the right, Key, AI model (the Styles
  page's engine, changed there) and Custom instructions. The copy is plain and complete on
  purpose (Gokul, angrily, at the clipped round 2 words); keep it that way.
- **Custom instructions** (`Settings.autowriteInstructions`, exported with the settings): one
  box, type or paste, how SigmaFlow should write for you, never about you and with no names in
  the placeholder. Kept only on **Save** (27 Oct 2026, Gokul: typing gave no sign it was kept;
  pick A over a Saved word or a toast): live once the box differs, then Saved with a tick for
  `statusHold`; leaving the page drops an unsaved edit, like a style. A click anywhere outside
  the box (Save too) takes the cursor out of it (`ClickOutsideEndsEditing`); AppKit won't. Autowrite only: styles
  and smart cleanup never read it (3A). A cloud model
  gets it whole in the system prompt; Apple's model gets the first 300 words
  (`WritePrompt.appleInstructionWords`) in the message beside the ask, where it follows them
  (in the system prompt it ignored them), and only then does a line under the box say so.
  Tested with `--write-check`: "Always write in French" held 3 of 3 on Apple; a different
  sign-off name fought the prompt's own first-name sign-off and held 1 of 2. **There is no
  built-in sign-off since 27 Oct 2026**: it signed with the Mac account's first name, GRJ on
  Gokul's Mac, and Apple's model put it under Cliq messages written like letters (5 of 20).
  Now 0 of 40; "Sign emails as Gokul." in the box signs 3 of 5 emails on Apple.
- **"Sure, here's the text for the box:"** Apple's model put that line in front of 20 of 50
  replies (27 Oct 2026). Every engine is wrapped in `WithoutPreamble`, which drops one short
  first line ending in a colon that both opens like one (Sure, Here is…) and names the writing
  (text, reply, the box…), and holds the overlay back while the first line could still be one:
  0 of 50 after, 83 of 83 cut across 250 saved replies, layout kept. Don't fix it in the
  prompt: rewording the last line wrote shorter replies and still did it (17 of 50), naming
  "Sure" and "Here is" made it 46 of 50, and a one-field (guided) reply dropped every line
  break and typed Priya's message back to her in 4 of 10. `@Generable` needs Xcode's macro
  plugin anyway; a `DynamicGenerationSchema` builds without it.

- **The screen and nothing else.** `ScreenReader` reads the screen the pointer is on with
  SigmaFlow's windows left out (`NotesScreen.image`), as Vision text, plus a JPEG for Anthropic
  only (OpenRouter's free router may pick a model that can't see). Captured when the key
  counts, while you talk. **No meetings, conversations or dictations** (Gokul, 21 Oct): a
  transcript can tag a line to the wrong speaker and a reply would repeat it as fact. User-written
  .md notes may come later (Figma 8.6, drawn, not built).
- **The engine is the Styles page's** (`Settings.styleEngine`), shown on the page and changed
  only there. Apple's model gets the screen's words cut to fit its window; it echoed the ask
  back until the instruction was fenced and named as one (`WritePrompt.user`).
- **The key counts after `DS.Motion.writeArm` (0.3 s) with no other key.** Right ⌥ and Right ⌘
  are half of everyday shortcuts (⌥1 to ⌥5 styles, accents, ⌘C); a key pressed while it is held
  calls `onWriteInterrupted`, which drops the run and lets the key through. The cost is the
  first 0.3 s of speech. No double tap, no hands free.
- **After release** the run stays `.finishing` (Esc abandons it, a second press is refused) and
  `writing` drives the overlay: what you asked, dim, over the writing as it streams; then the
  dictionary over the result, then `TextInjector.focus()`: a clear no (or SigmaFlow in front)
  copies it and shows it under COPIED for 5 s; anything else types it. Couldn't write shows the
  reason for 4 s. Its own 60 s watchdog; the dictation watchdog ends at the ask.
- **Not saved to Transcriptions**, not watched by the learner, never Power mode.
- `SigmaFlow --write-check "ASK" [--engine apple|claude|openRouter] [--sample chat]` writes against that sample
  (an email in Mail, or a letter-like Cliq message)
  and prints it as it streams. A cloud engine reads its key from the Keychain, which asks for
  permission from any copy but the one that saved it; check Claude in the app itself.

### Snippets

`Snippets/SnippetStore.swift` — a trigger phrase → saved text, matched whole-phrase and
case-insensitively anywhere in the utterance. It is a pipeline stage, not a UI feature; see the
ordering invariant above.

### Persistence and the MCP helper

`~/Library/Application Support/SigmaFlow/`:

```
dictionary.txt          plain text, file-watched so hand edits and the UI stay in sync both ways
runs.jsonl              only dictations waiting while the SigmaFlow folder can't be found (see Dictations below)
runs before the SigmaFlow folder.jsonl   the history as it was before the 19 Oct 2026 move, kept until Gokul says it can go
snippets.json           trigger → text
typed-words.json        words typed by hand per day, for Insights' Today card; counts only
Recording/              a meeting while it records (mic, plus <id>.call.m4a, or live notes' <id>.photos/
                        and <id>.screens/);
                        moved into ~/SigmaFlow at Stop
Search/                 search's index, a rebuildable cache (see Search above)
Models/                 IndicConformer, EmbeddingGemma2, Gemma4E2B, MLX kernels
```

Meetings themselves live in the user-visible `~/SigmaFlow/Meetings/` (see Meetings above).

**Dictations live in the SigmaFlow folder too** (19 Oct 2026,
[docs/mockups/dictations-folder.html](docs/mockups/dictations-folder.html), picks 1B 2A 3A 4A; 2A on 20 Oct):
`~/SigmaFlow/Dictations/2026/10 October.md`, one Markdown file a month, newest day first, each
day a `| Time | Dictation |` table (files from 19 Oct with a Length column are still read, by header) (`Support/DictationFiles.swift`), and beside them the
hidden `Dictations/.dictations.jsonl`, the old runs.jsonl format (id, timings, model,
corrections), appended per dictation and rewritten for a delete or a followed edit. That file
is what RunStore, Insights, export and SigmaFlowMCP read; `RunLog.runsURL` names it.
- **Hand edits come back (3A).** Before any month is written, its file is read back
  (`RunLog.loadTakingHandEdits`) and the words of each row, matched in order by day and time,
  replace the dictation's; also on app activation. Only words can be edited: a row deleted or
  changed beyond its words is written back. Keep the format round-trippable.
- **The move** (`RunLog.settle`, at launch and on Change / Find it): dictations in the app's
  `runs.jsonl` join the folder's, verified by id before the waiting file is let go; the first
  time it is renamed `runs before the SigmaFlow folder.jsonl` and kept. While the folder is
  missing, `runsURL` is that waiting file. Changing to a folder without dictations takes the
  history along; the old folder keeps its copy.

A stale `dashboard.html` may sit beside them from before September 2026; nothing reads or
writes it any more. Models live under `Application Support/FluidAudio/Models/`.

`Support/DataPortability.swift` exports five of these (transcripts, dictionary, snippets,
styles, settings) as a folder you can carry to another Mac, and imports it merging or
replacing. The Anthropic and OpenRouter keys stay in the Keychain and are deliberately
not exported; models are re-downloaded on the other side.

`SigmaFlowMCP` is a second executable — no AppKit, no FluidAudio — that Claude Desktop
launches over stdio and that reads `runs.jsonl` to answer questions about past dictations.
Since 16 Oct 2026 (Gokul: "maximum context") it also reads every meeting and conversation in
the SigmaFlow folder (`Sources/SigmaFlowMCP/Recordings.swift`): `list_recordings`,
`search_recordings` (matching lines with the lines around them), `read_recording` (the whole
transcript, or a stretch by time, pictures placed at their moments, then an index of them)
and `get_pictures` (photos and screenshots as image content, up to 8 a call, at most 1568 px).
It finds the folder through the app's `sigmaFlowFolderPath` preference
(`CFPreferencesCopyAppValue`), falling back to ~/SigmaFlow, and parses the .md itself; keep
it in step with `MeetingMarkdown` when the format changes. Claude Desktop reads the tool list
when it starts, so new tools need a restart of Claude Desktop. Since 16 Oct 2026 `initialize`
also sends `instructions` (`main.swift`), a briefing Claude reads before every chat: what the
three kinds of record are, that speaker numbers are per recording and the user isn't labelled,
that attribution can be wrong, Tamil in Tamil letters. Chosen over a Claude skill because it
ships with the app and needs no install. It describes the data, so it changes with it.
`Support/ClaudeConnection.swift` (an `@Observable` singleton) adds it to Claude Desktop as an
extension: it writes `Application Support/SigmaFlow/Claude/SigmaFlow.mcpb` (manifest 0.4, a binary
server with an absolute path, the screenshot from `Resources/ClaudeExtension/`, a made-up meeting)
and opens it with Claude, which installs it with no restart; Claude's "not verified" warning shows
once. An old `claude_desktop_config.json` entry still counts as connected and is removed once the
extension is in (that file needs a Claude restart, and nobody quits Claude).

**Ask Claude** (23 Oct 2026, [docs/mockups/ask-claude.html](docs/mockups/ask-claude.html), picks
1B 2A 3C 4C; Figma 3.21 to 3.24, 4.23, 4.24; `UI/AskClaude.swift`), tried and passed by Gokul
27 Oct. Two places, two jobs: Meetings and Conversations carry `ClaudeAskBar` at the foot of the
page until Claude has SigmaFlow (one click, for every recording; gone for good after, nothing when
Claude isn't installed), and every transcript has Ask Claude beside Play, whose first click adds
SigmaFlow. Its questions are copied with the recording's name and Claude opens on a new chat
(`claude://claude.ai/new?surface=chat`; without `surface=chat` it may open in Cowork). Not `?q=`:
Claude prefills it but shows a red caution banner every time, so the question goes by the
clipboard. Untested: Disconnect with the extension re-opens the .mcpb, assuming Claude's page for
it offers Uninstall. It deliberately
redeclares its own minimal `Transcript` type rather than depending on the app target; keep it
that way. The Makefile signs it *before* the enclosing bundle — an unsigned nested Mach-O
invalidates the app signature, which costs Accessibility, which kills every hotkey silently.

### Dictionary vectors

`Tests/SigmaFlowDictionaryTests/dictionary-test-vectors.json` is the specification for
correction behaviour. Change vectors first, watch the test go red, then fix the code.
Its `learningCases` are the other contract in the same file: which edits `LearnedCorrection`
may offer as a rule and, mostly, which it must refuse. `LearnedCorrection` lives in the
platform-neutral target for exactly this reason — it is a heuristic, and CI can only gate it
there. Loosening it is how the Dictionary page fills up with rules nobody wanted.
The Windows port and its `shared/` vectors folder were removed in September 2026; do not
recreate either.

## Design system

[UI/DesignSystem.swift](Sources/SigmaFlow/UI/DesignSystem.swift) (`DS`) holds every color,
size, radius, duration and material token. **Views must not contain literal values** — add a
token instead.

The current direction is **monochrome**: white is the only ink, the dark *Death of Socrates*
render sits behind the content at full strength with no scrim, a solid black sidebar carries
the ASCII wordmark, IBM Plex Sans for prose and Plex Mono for data. Sharp edges (radius
tokens exist but resolve to 0), no gradients, nothing blinks. The one exception to
monochrome is the live audio meter, which reads system green. Recording reads through
weight, not color.

`UI/MainWindow.swift` is the shell: nine pages in the reviewed order — Models, Transcriptions,
Meetings, Conversations, Dictionary, Snippets, Styles, Autowrite, Settings — each its own file (`DictionaryPanel.swift` and
`SettingsWindow.swift` keep their old names), each an IBM Carbon icon in the sidebar. Add a
page by adding a `Section` case there; nothing else routes. The last page and the open tab of
each page persist in `Settings.lastPage` / `Settings.openTabs`.

**Words follow [docs/copy-voice.md](docs/copy-voice.md)** (19 Oct 2026, Gokul: written the way
tryvoiceink.com is written). Say what the person gets, in plain words, with SigmaFlow doing
the work. How much text a screen carries is still screen by screen.

**No page scrolls as a whole** (Gokul, 16 Oct 2026, the rule Meetings set). A page with tabs
uses `PageScroll { header and TabStrip } content: { … }`, so only what is under the strip
scrolls. A list page uses `ListPage`: its header, search and the card's editor stay put, and
the rows scroll inside the card through `CardScroll`. A new page follows one of the two.
Every scroll view takes `.scrollEdgeFade()`: the content fades out at an edge with more
beyond it (Gokul asked, 16 Oct 2026). It fades the content, it paints nothing, so the
no-gradients rule still holds.

**The design lives in the Figma file "[ SIGMAFLOW ]"** (key `ucHDq8KTA5W3xmG1ssf1mX`,
made 20 Oct 2026 from main): every screen, tab, state and flow, built from components and
variables named after `DS`. Since 20 Oct 2026 (Gokul) a change to how the app looks or behaves is
drawn there first, then the code follows; when they disagree, update whichever is behind before
anything else. How it is built and redrawn: [docs/figma/README.md](docs/figma/README.md). The earlier
file "SigmaFlow 1.0" (`TX8R9zWm5H3YS9WaqO3JBJ`, drawn by `docs/mockups/figma/`) is history. Page furniture
(`PageHeader`, `TabStrip`, `SearchBox`, `ListToolbar`, `EditorRow`, `PopupButton`,
`GrowingTextArea`, `GaugeLine`, `ProgressLine`, `CopyButton`) lives in `UI/Equipment.swift`.

Where things moved on 10 Oct 2026: the rewrite engine and its key are on the Styles page
(Custom styles tab), the learning switch is in the Dictionary footer, cleanup is one popup
in Settings, and Settings has three tabs (Dictation, Connections, Your data). Nothing shows
a Learned tag, a toast, or an engineering fact. Since 13 Oct 2026 Your data opens with the
SigmaFlow folder card (the path opens Finder, Change re-points it); its old "Show the folder"
button, which opened the hidden Application Support folder, is gone.

**Comparing a build against the Figma window:** screen recording is not granted to the
shell, so the app draws itself.
`/Applications/SigmaFlow.app/Contents/MacOS/SigmaFlow --snapshot-dir DIR --pages models,styles/custom`
writes `DIR/<page>[-<tab>].png` at 1160×760 through SwiftUI's `ImageRenderer` and quits;
`--snapshot-size 980x620` draws at the window's minimum instead, which is where a page
built for the Figma width breaks first.
Text fields and switches render as the renderer's yellow stand-in and the sidebar loses its
vibrancy; everything else is the real layout. Pages lay out flat (no scroll view) in that
mode via `\.isSnapshotting`, and lists show `DS.Material.snapshotRows` rows.

> AGENTS.md now describes the same monochrome system. `DS` remains the source of truth.

## Docs that have drifted

- README was rewritten for going public on 21 Oct 2026
  ([docs/mockups/readme-public.html](docs/mockups/readme-public.html), picks 1A 2B 3B 4A 5B):
  centred icon and name, coloured shields.io badges, one Download for Mac button, GPL v3. The
  button downloads `releases/latest/download/SigmaFlow.dmg` directly (27 Oct 2026), so every
  release must carry the installer under exactly that name, as `make dmg` writes it. The
  Homebrew line came out on 27 Oct 2026: the tap `itsgrj/homebrew-tap` was never made, so the
  command failed; put it back with the tap.
- **The README shows every feature as a moving picture the app drew itself** (28 Oct 2026,
  [docs/mockups/readme-showcase.html](docs/mockups/readme-showcase.html), rounds 1 to 5):
  picture on the left, words on the right (`align="left"`, then `<br clear="left">`), in three
  groups, then the AI-ready folder and the local models. Examples are sales, marketing and
  developers' work, all made up (Northwind, Maya Chen, Vercel, Q1 launch). Gokul caught hand-drawn
  pictures not matching the app, so `SigmaFlow --readme-frames DIR [--scenes a,b]`
  (`Support/ReadmeFrames.swift`) plays each scene through the real overlay, cards and pages,
  driven by the `stageForPicture` hooks, over a made-up SigmaFlow folder in the temp folder
  (the real one is never read), and writes `docs/readme/<scene>.png` as animated PNGs
  (`Support/AnimatedPNG.swift`, changed rectangles only). Run it from the staged build with
  `lastPage` set away from styles; it shows on screen for about two minutes. Redraw only the
  scenes a change touches: git keeps every copy (about 22 MB for all eleven). What a dictation
  lands is the real rule cleanup and dictionary, never a sentence written by hand.
  `SigmaFlow --cleanup-check "TEXT" …` prints what both cleanups make of a line; tested 28 Oct,
  Smart cleanup kept "five, no, ten" and "Tuesday, actually Wednesday" as said (only its own
  prompt's example worked), so the README does not claim changing your mind mid-sentence.
  Icons are Carbon SVGs in `docs/readme/icons/`, a `-dark` and `-light` copy behind `<picture>`.
- **Public since 27 Oct 2026, from a fresh start** (Gokul's pick). The 190 commits before it
  held colleagues' names, work topics and a work email in old mockups, so they live only in the
  private `itsgrj/SigmaFlow-history` (remote `private`, local branch `history`); the public
  `itsgrj/SigmaFlow` begins with one commit of the cleaned tree. Commit hashes quoted in this file
  or in old notes from before that day are in the history copy. Mockups stay public: anything
  real in a new one (a colleague, a customer, a work topic, the work email) is replaced with a
  made-up stand-in before it is committed, the way picture search's Kettle and Brewly are. Its pictures live in `docs/readme/`
  (`icon.png` is the app icon masked the way the Dock rounds it). CONTRIBUTING.md,
  CODE_OF_CONDUCT.md (no contact email, Gokul's call: reports go through GitHub) and LICENSE
  sit beside it, which is what gives GitHub its tabs above the README. The README is for
  people using SigmaFlow and points here for architecture; the developer notes it used to
  carry moved to CONTRIBUTING.md.
- **The app icon is `Resources/AppIcon.icns`**, Gokul's gradient sigma; `AppIcon.iconset` is
  the same picture as PNGs. `Tools/makeicon.swift` and `make icon` drew an older flat sigma and
  would have overwritten the real one, so both were retired on 21 Oct 2026. A new icon means
  a new .icns from Gokul, then the iconset and `docs/readme/icon.png` redone from it. Note the app is a regular app (`LSUIElement` false,
  `.regular` activation policy) with the menu bar item as a secondary surface — some older
  prose elsewhere calls it a menu-bar accessory.
- `_to_delete/` was deleted in the September 2026 cleanup; the removed `WisprReader` /
  `WisprTrigger` files live only in the 29 Aug 2026 commit.

## Environment notes

- Bundle ID `com.grj.sigmaflow`. Not sandboxed by design — a `CGEventTap` and system-wide AX
  access are both impossible inside the App Sandbox.
- Never run the `.app` from this folder; `make install` puts the live copy in `/Applications`.
- `log` is shadowed in this shell. Use `/usr/bin/log show --predicate 'subsystem == "com.grj.sigmaflow"'`.
- `tccutil reset Accessibility com.grj.sigmaflow` — **always with the bundle ID**; a bare
  reset wipes every app on the machine.
- `CFBundleShortVersionString` is `1.0.1` since 28 Oct 2026 (1.0.0 was the first public build); the sidebar foot reads it.
