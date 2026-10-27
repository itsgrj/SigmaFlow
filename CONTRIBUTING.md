# Contributing to SigmaFlow

Thanks for helping. SigmaFlow is small and opinionated, so a short talk first saves you work.

## Report a bug

Open an [issue](https://github.com/itsgrj/SigmaFlow/issues) with what you did, what you
expected, and what happened. Your macOS version and Mac model help.

## Suggest something

Open an issue before you write code. SigmaFlow cuts features as often as it adds them; a quick
yes saves a wasted pull request.

## Build it

```bash
make install   # build, sign, copy to /Applications, open
```

Other targets: `make build`, `make app`, `make run`, `make dmg`, `make clean`.

Never bare `swift build`. The Makefile builds under `~/Library/Caches/SigmaFlowBuild`, because a
synced folder (Desktop and Documents on many Macs) changes files mid-build and breaks the
signature. [AGENTS.md](AGENTS.md) lists the things that look like bugs and are not; read it
before you chase one. [CLAUDE.md](CLAUDE.md) holds the architecture and the rules each part
keeps.

### When a permission gets stuck

macOS remembers Accessibility and Microphone by the app's signature. If a switch shows as on
but SigmaFlow can't hear the key, reset just SigmaFlow's row and turn it on again. Always pass
the bundle ID; a bare reset clears every app on the Mac.

```bash
tccutil reset Accessibility com.grj.sigmaflow
tccutil reset Microphone    com.grj.sigmaflow
```

Then quit System Settings (⌘Q) before you open it again.

## Tests

```bash
swift test --filter VectorTests
```

The dictionary's behaviour is written down in
`Tests/SigmaFlowDictionaryTests/dictionary-test-vectors.json`. Change the vectors first, watch
the test fail, then change the code. The tests need full Xcode; GitHub runs them on every push.

## House rules

- Every colour, size and duration is a token in `Sources/SigmaFlow/UI/DesignSystem.swift`.
  Views carry no literal values.
- The app is monochrome, with sharp edges, no gradients, and nothing that blinks.
- Words in the app follow [docs/copy-voice.md](docs/copy-voice.md).
- One change per pull request, with a plain description of what it does for the person using
  SigmaFlow.

By sending a pull request you agree that your work is released under the
[GPL v3](LICENSE), like the rest of SigmaFlow, and that you follow the
[code of conduct](CODE_OF_CONDUCT.md).
