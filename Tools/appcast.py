#!/usr/bin/env python3
"""Adds this release to appcast.xml, newest first. Run by `make release`, never by hand.

    appcast.py APPCAST INFO_PLIST 'sparkle:edSignature="..." length="..."'

The version, build number and minimum macOS come from the Info.plist that was built; the
signature and length are what Sparkle's sign_update printed for the DMG. The DMG's address is
the GitHub release's, under exactly the name the README's Download button uses.
"""
import email.utils
import plistlib
import re
import sys

REPO = "itsgrj/SigmaFlow"


def main() -> None:
    appcast_path, plist_path, signed = sys.argv[1:4]
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    minimum = info.get("LSMinimumSystemVersion", "26.0")

    match = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', signed)
    if not match:
        sys.exit(f"appcast.py: no signature in {signed!r}")
    signature, length = match.groups()

    with open(appcast_path, encoding="utf-8") as f:
        appcast = f.read()
    if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in appcast:
        sys.exit(f"appcast.py: {version} is already in {appcast_path}")

    item = f"""    <item>
      <title>SigmaFlow {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/{REPO}/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/{REPO}/releases/download/v{version}/SigmaFlow.dmg" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
"""
    # Newest first: before the first release already listed, or at the end of the channel.
    anchor = appcast.find("    <item>")
    if anchor < 0:
        anchor = appcast.find("  </channel>")
    if anchor < 0:
        sys.exit(f"appcast.py: no <channel> in {appcast_path}")
    with open(appcast_path, "w", encoding="utf-8") as f:
        f.write(appcast[:anchor] + item + appcast[anchor:])
    print(f"appcast.xml: added SigmaFlow {version} (build {build})")


if __name__ == "__main__":
    main()
