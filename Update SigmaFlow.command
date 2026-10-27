#!/bin/bash
# Double-click this file in Finder to rebuild SigmaFlow from the current source and
# relaunch it. It is `make install` with a friendlier face: quits the running app,
# builds, signs, copies to /Applications, opens it, and leaves this window up only
# when something went wrong.

cd "$(dirname "$0")" || exit 1

echo "SigmaFlow: rebuilding from $(pwd)"
echo "This usually takes one to three minutes. Leave this window alone until it says done."
echo

LOG="$(mktemp -t sigmaflow-build)"
if make install >"$LOG" 2>&1; then
    echo "Done. SigmaFlow has been rebuilt, installed to /Applications and relaunched."
    echo
    echo "Last commit built:"
    git log -1 --format='  %h  %s  (%ad)' --date=short 2>/dev/null
    echo
    echo "If the hotkey does nothing after a rebuild, the Accessibility grant needs a"
    echo "re-tick: System Settings > Privacy & Security > Accessibility, toggle SigmaFlow"
    echo "off and on, then quit System Settings."
    echo
    echo "You can close this window."
    rm -f "$LOG"
    exit 0
fi

echo "The build failed. Nothing was installed; the previous SigmaFlow is untouched."
echo
echo "Copy everything between the lines and paste it into the Claude chat:"
echo "------------------------------------------------------------"
grep -E "error:|fatal|warning: unable|codesign|No such file|failed" "$LOG" | tail -25
echo "..."
tail -15 "$LOG"
echo "------------------------------------------------------------"
echo "Full log: $LOG"
exit 1
