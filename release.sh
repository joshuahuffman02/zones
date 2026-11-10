#!/bin/zsh
# Publishes a new Zones version on GitHub Releases. Every installed copy picks it up within the hour
# (or right away from Check for Updates…) and installs it once you've stepped away for 30 seconds.
#
#   ./release.sh "What changed"
#
# Releases only committed code: commit first. Needs the gh CLI signed in, and the update signing key
# in this Mac's login keychain (Sparkle account "zones"; created by
# .build/artifacts/sparkle/Sparkle/bin/generate_keys --account zones). Back it up with
#   generate_keys --account zones -x zones-update-key.txt
# and keep that file out of the repo: without it, installed copies can't be updated.
set -euo pipefail
cd "${0:A:h}"

NOTES="${1:?Say what changed: ./release.sh \"Gap handles work on stacked windows\"}"
REPO="joshuahuffman02/zones"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first:"; git status --short; exit 1; }
git push -q origin HEAD

swift test 2>&1 | grep -E "Test run|✘" || true
swift test >/dev/null 2>&1 || { echo "Tests failed; not releasing."; exit 1; }

# Next build number = newest release + 1.
LATEST=$(gh release list -R "$REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null | grep -o '[0-9]*$' || true)
BUILD=$(( ${LATEST:-0} + 1 ))
VERSION="1.0.$BUILD"
echo "Releasing Zones $VERSION"

BUILD=$BUILD ./build.sh >/dev/null
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent build/Zones.app "$OUT/Zones-$VERSION.zip"
cp "$OUT/Zones-$VERSION.zip" "$OUT/Zones.zip"

# Sparkle checks this signature before installing anything.
SIG=$("$SPARKLE_BIN/sign_update" --account zones "$OUT/Zones-$VERSION.zip")

python3 -I - "$OUT/appcast.xml" "$REPO" "$VERSION" "$BUILD" "$SIG" "$NOTES" <<'PY'
import email.utils, html, sys
out, repo, version, build, sig, notes = sys.argv[1:7]
open(out, "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Zones</title>
    <item>
      <title>Zones {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
      <enclosure url="https://github.com/{repo}/releases/download/v{version}/Zones-{version}.zip" {sig} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
""")
PY

gh release create "v$VERSION" -R "$REPO" --title "Zones $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)" \
  "$OUT/Zones-$VERSION.zip" "$OUT/Zones.zip" "$OUT/appcast.xml"

LIVE=$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" | grep -o '<sparkle:version>[0-9]*' | grep -o '[0-9]*$')
[[ "$LIVE" == "$BUILD" ]] || { echo "Released, but the feed still shows build $LIVE."; exit 1; }
echo "Zones $VERSION is live. Installed copies update on their own."
echo "First install: https://github.com/$REPO/releases/latest/download/Zones.zip"
