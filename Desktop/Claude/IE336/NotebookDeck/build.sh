#!/bin/zsh
# Builds NotebookDeck.app into ./build using only the Xcode Command Line Tools.
#
# If ./Runtime exists (see stage_runtime.sh) it is copied into the bundle as
# Contents/Resources/runtime, making the app self-contained: Python, Jupyter, the
# notebook packages, Ollama, and the distilbert weights of the ch02 lab. Ollama models
# are not bundled: Runtime/models/ollama, if an earlier stage_runtime.sh left one, is
# not copied, and students download the course models from the Models window, which
# reads their list from Hugging Face and falls back to the saved copy, then to
# Resources/course_models.json (copied below). NOTEBOOKS_DIR (default: the
# StochMod book's notebooks folder) is copied to Contents/Resources/notebooks.
#
# The bundle is written to ~/Applications (override with APP_DIR). This folder is
# outside the iCloud-synced Desktop: a synced folder keeps re-stamping Finder
# metadata on the .app, which makes codesign refuse it, and it would also try to
# upload the 2 GB runtime.
#
# ARCH=x86_64 builds the Intel app instead: the Swift code is compiled for x86_64 (in
# .build-x86_64, so the arm64 build products are left alone), ./Runtime-x86_64 (see
# ARCH=x86_64 ./stage_runtime.sh) takes the place of ./Runtime, and the bundle goes to
# ~/Library/Caches/NotebookDeck-intel unless APP_DIR says otherwise, so that it never
# replaces the arm64 app in ~/Applications. The build then checks that every Mach-O file
# in the bundle has x86_64 code that runs on the app's minimum macOS (LSMinimumSystemVersion).
set -euo pipefail
cd "$(dirname "$0")"

: ${ARCH:=arm64}
case "$ARCH" in
    arm64)  RUNTIME=Runtime;        STAGE="./stage_runtime.sh";             SWIFT_ARGS=()
            : ${APP_DIR:="$HOME/Applications"} ;;
    x86_64) RUNTIME=Runtime-x86_64; STAGE="ARCH=x86_64 ./stage_runtime.sh"; SWIFT_ARGS=(--arch x86_64 --scratch-path .build-x86_64)
            : ${APP_DIR:="$HOME/Library/Caches/NotebookDeck-intel"} ;;
    *) echo "ARCH must be arm64 or x86_64, not $ARCH" >&2; exit 1 ;;
esac
: ${NOTEBOOKS_DIR:="/Users/harsha/Desktop/Claude/StochModBook/6a5e0b2f65dfe2cef5b7967a/notebooks"}

swift build -c release "${SWIFT_ARGS[@]}"
BIN=$(swift build -c release "${SWIFT_ARGS[@]}" --show-bin-path)/NotebookDeck

mkdir -p "$APP_DIR"
APP="$APP_DIR/NotebookDeck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotebookDeck"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cp Resources/runtime_check.py "$APP/Contents/Resources/"
cp Resources/course_models.json "$APP/Contents/Resources/"

if [[ ! -d "$RUNTIME" && -z "${ALLOW_SLIM:-}" ]]; then
    echo "No ./$RUNTIME: the app would depend on the machine's own Python and Ollama." >&2
    echo "Run $STAGE first, or set ALLOW_SLIM=1 to build without the runtime." >&2
    exit 1
fi
if [[ -d "$RUNTIME" ]]; then
    echo "Syncing runtime into bundle…"
    # models/ollama stays out, and so does models/hf/xet, which holds only the logs hf_xet wrote
    # while the runtime was staged (the app sends them to HF_XET_CACHE in Application Support).
    # --delete-excluded removes the copies an earlier build put in the bundle.
    rsync -a --delete --delete-excluded --exclude '/models/ollama/' --exclude '/models/hf/xet/' \
        "$RUNTIME/" "$APP/Contents/Resources/runtime/"
    if [[ -d "$RUNTIME/models/ollama" ]]; then
        echo "Left out $RUNTIME/models/ollama ($(du -sh "$RUNTIME/models/ollama" | cut -f1 | tr -d " ")): Ollama models are not bundled; delete it to free the space."
    fi
    # A manifest staged before the models were unbundled still lists them; the bundle's copy says none are.
    M="$APP/Contents/Resources/runtime/MANIFEST.txt"
    if [[ -f "$M" ]]; then
        awk '/^Ollama models:/ { print "Ollama models:"; print "  none bundled (Models > Manage Models… downloads the course models)"; skip = 1; next }
             skip && /^$/ { skip = 0 }
             !skip' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
    fi
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

if [[ "$ARCH" == x86_64 ]]; then
    # The files sign_and_notarize.sh signs: executables, .so and .dylib files that are Mach-O.
    MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
    autoload -Uz is-at-least
    n=0; bad=()
    while IFS= read -r -d '' f; do
        archs=$(lipo -archs "$f" 2>/dev/null) || continue      # not a Mach-O file
        n=$((n + 1))
        if [[ " $archs " != *" x86_64 "* ]]; then bad+=("no x86_64 code ($archs): $f"); continue; fi
        # awk reads to the end: an early exit would stop otool with SIGPIPE, which pipefail turns into a failure.
        v=$(otool -arch x86_64 -l "$f" | awk '$1 == "cmd" { c = $2 }
            v == "" && c == "LC_BUILD_VERSION" && $1 == "minos" { v = $2 }
            v == "" && c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { v = $2 }
            END { print v }')
        if [[ -n "$v" ]] && ! is-at-least "$v" "$MINOS"; then bad+=("needs macOS $v: $f"); fi
    done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
    if (( ${#bad[@]} )); then
        printf '%s\n' "${bad[@]}" >&2
        echo "${#bad[@]} of $n Mach-O files cannot run on an Intel Mac with macOS $MINOS." >&2
        exit 1
    fi
    echo "All $n Mach-O files have x86_64 code for macOS $MINOS or earlier."
fi

codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "signature verified"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
