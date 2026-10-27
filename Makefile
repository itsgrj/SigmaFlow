EXEC     := SigmaFlow
MCPEXEC  := SigmaFlowMCP
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/SigmaFlowBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)
MCPBUILD := $(SCRATCH)/$(CONFIG)/$(MCPEXEC)
## The MediaRemote bridge /usr/bin/perl loads for "pause media while recording".
MEDIAHOST  := libSigmaFlowMediaHost.dylib
MEDIABUILD := $(SCRATCH)/$(CONFIG)/$(MEDIAHOST)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/SigmaFlowBuild
APPNAME  := SigmaFlow.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC and the keychain both key their grants to the code signature, so an ad-hoc
## signature — which changes on every build — makes the user re-grant Accessibility and
## re-approve keychain reads after every `make`. Any *stable* identity fixes that: a
## Developer ID if one is present, otherwise the self-signed "SigmaFlow Dev" code-signing
## certificate in the login keychain (create it once via Keychain Access ▸ Certificate
## Assistant, type Code Signing). Falls back to ad-hoc ("-") on a machine with neither.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep -E "Developer ID Application|SigmaFlow Dev" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build app run install clean dmg

all: app

## C and C++ are optimised even in the debug build: MLX (picture descriptions) is C++, and
## at -O0 it is several times slower; Swift stays unoptimised and quick to build.
build:
	swift build -c $(CONFIG) -Xcc -O2 -Xcxx -O2 --scratch-path "$(SCRATCH)"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@# The MCP helper Claude Desktop launches. In MacOS/ so codesign covers it as
	@# nested code rather than treating it as a stray resource.
	@if [ -f $(MCPBUILD) ]; then cp $(MCPBUILD) "$(CONTENTS)/MacOS/sigmaflow-mcp"; fi
	@# The MediaRemote bridge, loaded by /usr/bin/perl rather than by the app — see
	@# Sources/SigmaFlowMediaHost/MediaHost.c. Missing file = pause-media silently off.
	@if [ -f $(MEDIABUILD) ]; then \
		mkdir -p "$(CONTENTS)/Frameworks"; cp $(MEDIABUILD) "$(CONTENTS)/Frameworks/$(MEDIAHOST)"; \
	fi
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@# Geist Pixel, Geist Mono and Geist (OFL) — registered via ATSApplicationFontsPath in Info.plist.
	@if [ -d Resources/Fonts ]; then cp -R Resources/Fonts "$(CONTENTS)/Resources/Fonts"; fi
	@# The window background: the Death of Socrates in colour (public domain, Wikimedia Commons).
	@if [ -f Resources/background-colour.jpg ]; then cp Resources/background-colour.jpg "$(CONTENTS)/Resources/"; fi
	@# IBM Carbon icons (Apache 2.0), loaded by name as template images.
	@if [ -d Resources/Icons ]; then cp -R Resources/Icons "$(CONTENTS)/Resources/Icons"; fi
	@# First-party provider marks shown in the Styles engine picker.
	@if [ -d Resources/ProviderMarks ]; then cp -R Resources/ProviderMarks "$(CONTENTS)/Resources/ProviderMarks"; fi
	@# The screenshot in Claude Desktop's Install box for SigmaFlow (Sources/SigmaFlow/Support/
	@# ClaudeConnection.swift): Figma 3.24, a made-up meeting, never a real recording.
	@if [ -d Resources/ClaudeExtension ]; then cp -R Resources/ClaudeExtension "$(CONTENTS)/Resources/ClaudeExtension"; fi
	@# Covers for the bookshelf on Transcriptions > Insights, one Open Library cover per book
	@# (Sources/SigmaFlow/Support/UsageInsights.swift). They belong to their publishers.
	@if [ -d Resources/BookCovers ]; then cp -R Resources/BookCovers "$(CONTENTS)/Resources/BookCovers"; fi
	@# The language check for Tamil meetings: SpeechBrain VoxLingua107 ECAPA (Apache 2.0) as
	@# CoreML, compiled by the app on first use (Sources/SigmaFlow/Meetings/LanguageCheck.swift).
	@if [ -d Resources/LanguageCheck ]; then cp -R Resources/LanguageCheck "$(CONTENTS)/Resources/LanguageCheck"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@# Nested executables must be signed BEFORE the bundle that contains them. Signing
	@# only the outer bundle leaves sigmaflow-mcp as an unsigned Mach-O inside a sealed
	@# bundle, which invalidates the app's signature — and an app with a broken signature
	@# is refused Accessibility by TCC, so every hotkey silently dies.
	@if [ -f "$(CONTENTS)/MacOS/sigmaflow-mcp" ]; then \
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none \
			"$(CONTENTS)/MacOS/sigmaflow-mcp"; \
	fi
	@if [ -f "$(CONTENTS)/Frameworks/$(MEDIAHOST)" ]; then \
		codesign --force --sign "$(SIGN_ID)" --timestamp=none \
			"$(CONTENTS)/Frameworks/$(MEDIAHOST)"; \
	fi
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@codesign --verify --strict "$(BUNDLE)" && echo "signature verified"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the SigmaFlow executable — never the separate `sigmaflow` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

## A shareable disk image: Release build, your icon, drag-to-Applications layout.
## Lands as SigmaFlow.dmg next to this Makefile — that's the file you send.
##
## Friends will hit Gatekeeper on first open ("Open Anyway" lives in System Settings ▸
## Privacy & Security) because the app isn't notarized. Expected without a paid
## Developer ID; tell them once and it never asks again.
dmg:
	@$(MAKE) app CONFIG=release
	@rm -rf "$(STAGE)/dmg" "$(EXEC).dmg"
	@mkdir -p "$(STAGE)/dmg"
	@cp -R "$(BUNDLE)" "$(STAGE)/dmg/$(APPNAME)"
	@ln -s /Applications "$(STAGE)/dmg/Applications"
	@hdiutil create -volname "$(EXEC)" -srcfolder "$(STAGE)/dmg" -ov -format UDZO "$(EXEC).dmg" >/dev/null
	@rm -rf "$(STAGE)/dmg"
	@echo "wrote $(EXEC).dmg — that's the file to send"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
