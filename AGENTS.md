# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Swift 6, SwiftUI, Apple `SpeechAnalyzer` or Parakeet via FluidAudio.

**The app works and is in daily use.** A Windows port (C# / Avalonia) existed in this repo
until September 2026 and was removed on purpose; do not rebuild it.

---

## The one rule that matters

**`Tests/SigmaFlowDictionaryTests/dictionary-test-vectors.json` is the specification for
correction behaviour.** If you change how corrections work, change the vectors first, watch
the test go red, then make it green.

```bash
swift test --filter VectorTests
```

---

## Things that look like bugs and are not

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**"Pause media while recording" goes through `/usr/bin/perl`, and that is not a hack to
remove.** Since macOS 15.4, MediaRemote (the Now Playing framework) answers "nothing playing"
to any process without Apple's private entitlement, and pause commands from such a process
go nowhere — a YouTube tab keeps playing while the checkbox says it shouldn't. Apple's own
platform binaries pass the check, and perl will `dlopen` an arbitrary dylib because its
DynaLoader exists to load CPAN extensions. `Sources/SigmaFlowMediaHost/MediaHost.c` is that
dylib; the Makefile stages it into `Contents/Frameworks` and signs it before the bundle;
`Core/MediaPauser.swift` spawns perl per command (~25 ms). A bare `swift build` binary has no
bundle, so the feature silently does nothing there. Don't "simplify" it back to
`MRMediaRemoteGetNowPlayingApplicationIsPlaying` in-process, and don't replace it with the
NX_KEYTYPE_PLAY media key: a blind toggle starts playback in a quiet room.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

---

## Design system

`Sources/SigmaFlow/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it.

The direction is **monochrome**: white is the only ink, the dark *Death of Socrates* render sits
behind the content at full strength with no scrim, a solid black sidebar carries the block
wordmark, IBM Plex Sans for prose and Plex Mono for data, IBM Carbon icons drawn as template
images. Sharp edges (radius tokens resolve to 0), no gradients, nothing blinks. Recording reads
through weight, not colour. The one exception is the live audio meter, which is system green.

Explicitly ruled out: neon, vaporwave, gradients, glowing text, toasts, blinking indicators.

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility com.grj.sigmaflow
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Regex, if you touch the dictionary

**NFC normalization stays.** macOS returns decomposed strings, so without it an accented
trigger silently never fires. Keep patterns inside the plain subset: `\b`, `\d`, `\w`, `\s`,
character classes, quantifiers, alternation, named groups, lookaround, `\p{L}`.

---

## What isn't built

1. **Onboarding**: a first-run window walking through the macOS permissions.
2. **Notarization**: the app is signed but not notarized, so friends hit Gatekeeper once.
