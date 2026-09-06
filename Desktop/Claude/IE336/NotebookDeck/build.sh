#!/bin/zsh
# Builds NotebookDeck.app into ./build using only the Xcode Command Line Tools.
#
# If ./Runtime exists (see stage_runtime.sh) it is copied into the bundle as
# Contents/Resources/runtime, making the app self-contained: Python, Jupyter, the
# notebook packages, Ollama, and the model weights. NOTEBOOKS_DIR (default: the
# StochMod book's notebooks folder) is copied to Contents/Resources/notebooks.
#
# The bundle is written to ~/Applications (override with APP_DIR). This folder is
# outside the iCloud-synced Desktop: a synced folder keeps re-stamping Finder
# metadata on the .app, which makes codesign refuse it, and it would also try to
# upload the 4 GB runtime.
set -euo pipefail
cd "$(dirname "$0")"

: ${APP_DIR:="$HOME/Applications"}
: ${NOTEBOOKS_DIR:="/Users/harsha/Desktop/Claude/StochModBook/6a5e0b2f65dfe2cef5b7967a/notebooks"}

swift build -c release
BIN=$(swift build -c release --show-bin-path)/NotebookDeck

mkdir -p "$APP_DIR"
APP="$APP_DIR/NotebookDeck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotebookDeck"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -d Runtime ]]; then
    echo "Syncing runtime into bundle…"
    rsync -a --delete Runtime/ "$APP/Contents/Resources/runtime/"
    xattr -dr com.apple.quarantine "$APP/Contents/Resources/runtime" 2>/dev/null || true
else
    rm -rf "$APP/Contents/Resources/runtime"
fi

if [[ -d "$NOTEBOOKS_DIR" ]]; then
    rsync -a --delete --exclude '.ipynb_checkpoints' --include '*.ipynb' --exclude '*' \
        "$NOTEBOOKS_DIR/" "$APP/Contents/Resources/notebooks/"
else
    rm -rf "$APP/Contents/Resources/notebooks"
fi

# codesign refuses bundles containing Finder metadata / AppleDouble files; strip them.
xattr -cr "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "signature verified"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
