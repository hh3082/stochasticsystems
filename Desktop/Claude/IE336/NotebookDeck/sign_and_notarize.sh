#!/bin/zsh
# Signs ~/Applications/NotebookDeck.app with a Developer ID, notarizes it with Apple, staples
# the ticket, and writes a distributable zip. Needs (one time, done by you):
#
#   1. A "Developer ID Application" certificate in your login keychain
#      (developer.apple.com/account > Certificates; see README).
#   2. Notarization credentials stored under a keychain profile:
#        xcrun notarytool store-credentials NotebookDeck --apple-id YOU@purdue.edu --team-id TEAMID
#      (it prompts for an app-specific password from account.apple.com).
#
# Usage:  ./sign_and_notarize.sh                  # auto-detects the Developer ID identity
#         ./sign_and_notarize.sh --dry-run        # only lists what would be signed
#         IDENTITY="Developer ID Application: Name (TEAMID)" PROFILE=NotebookDeck ./sign_and_notarize.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=${APP:-"$HOME/Applications/NotebookDeck.app"}
PROFILE=${PROFILE:-NotebookDeck}
ENT="$PWD/Resources/entitlements.plist"
OUT="$HOME/Desktop/NotebookDeck-mac.zip"
DRY=${1:-}

[[ -d "$APP" ]] || { echo "No app at $APP; run ./build.sh first." >&2; exit 1; }

# Every Mach-O inside the bundle (real files only; symlinks are skipped), deepest first so
# nested code is sealed before what contains it. The main executable is signed last.
find_machos() {
    find "$APP/Contents" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 \
      | xargs -0 file --no-pad | grep -E ': *Mach-O' | cut -d: -f1 | grep -v "/Contents/MacOS/NotebookDeck$" \
      | awk '{ print gsub("/","/"), $0 }' | sort -rn | cut -d' ' -f2-
}

if [[ "$DRY" == "--dry-run" ]]; then
    n=$(find_machos | wc -l | tr -d ' ')
    echo "Would sign $n nested Mach-O files plus the app, with entitlements $ENT"
    find_machos | sed "s|$APP/Contents/||" | awk -F/ '{print $1"/"$2"/"$3}' | sort | uniq -c | sort -rn | head -8
    { security find-identity -v -p codesigning | grep -c "Developer ID Application" || true; } | sed 's/^/Developer ID identities in keychain: /'
    exit 0
fi

IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }
echo "Signing with: $IDENTITY"

# Signing rewrites files inside Resources; strip metadata that codesign refuses first.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete

echo "== signing nested binaries"
i=0
find_machos | while read -r f; do
    codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$f" 2>&1 | grep -v "replacing existing signature" || true
    i=$((i+1)); (( i % 50 == 0 )) && echo "  $i signed…"
done

echo "== signing the app"
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
spctl --assess --type execute --verbose=1 "$APP" 2>&1 | tail -1 || true   # "rejected" is expected before notarization

echo "== notarizing (uploads $(du -sh "$APP" | cut -f1); this takes a while)"
TMPZIP=$(mktemp -d)/NotebookDeck.zip
ditto -c -k --keepParent "$APP" "$TMPZIP"
xcrun notarytool submit "$TMPZIP" --keychain-profile "$PROFILE" --wait --timeout 3h
rm -f "$TMPZIP"

echo "== stapling and packaging"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" | tail -1
# Gatekeeper's own verdict. On a Mac whose policy is "App Store only" spctl says "rejected
# source=Notarized Developer ID" for every notarized app (Chrome included), so this is
# informational: the ticket validation above is the real proof of notarization.
spctl --assess --type execute --verbose=1 "$APP" 2>&1 || echo "(spctl rejected: check System Settings > Privacy & Security > Allow applications from; notarization itself succeeded)"
rm -f "$OUT"
# --norsrc --noextattr --noqtn: no AppleDouble "._" metadata entries. Archive Utility folds
# those back into attributes, but other unzippers leave them as files inside the bundle,
# which breaks the code seal and makes Gatekeeper report the app as "damaged".
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$OUT"
echo "Done: $OUT ($(du -sh "$OUT" | cut -f1)) — notarized, opens on any Apple silicon Mac with macOS 14+ without warnings."
