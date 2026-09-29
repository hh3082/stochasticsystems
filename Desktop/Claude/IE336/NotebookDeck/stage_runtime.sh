#!/bin/zsh
# Populates ./Runtime with everything the bundled notebooks need. Run once (or after
# changing versions); build.sh copies the result into the app.
#
#   Runtime/python        relocatable CPython 3.12 (python-build-standalone, via uv)
#                         + numpy scipy matplotlib jupyterlab requests torch transformers
#                         + ipywidgets (the prompt box in the ch03 lab; the runtime sets
#                           PYTHONNOUSERSITE=1, so a --user install on the host is invisible
#                           to the kernel and it has to be staged here)
#   Runtime/ollama        official Ollama macOS CLI tarball (universal binary + ggml/MLX libs)
#   Runtime/models/hf     Hugging Face cache with distilbert-base-uncased (ch02 lab)
#
# No Ollama models are staged: the app downloads the course models (Resources/course_models.json)
# from the Models window, and build.sh leaves Runtime/models/ollama out of the app.
#
# ARCH=x86_64 stages the Intel runtime into ./Runtime-x86_64 instead (ARCH=x86_64 ./build.sh
# copies it into the Intel app). It differs from the default (ARCH=arm64) in three ways:
#   * Python is the x86_64 python-build-standalone build, and pip runs under Rosetta
#     (arch -x86_64), so every package is an x86_64 wheel. Wheels only (no source builds),
#     and none that needs a macOS newer than 14: pip first downloads the wheels with
#     --platform macosx_14_0_x86_64, then installs from that folder alone.
#   * The package set is requirements-lock-x86_64.txt. torch 2.2.2 is the last PyTorch with
#     macOS x86_64 wheels; it is built against numpy 1.x, so numpy stays below 2, and
#     transformers 5.1 and later require torch 2.4, so transformers stays at 5.0. debugpy
#     (ipykernel's debugger) stays at 1.8.16, the last release built for macOS 14.
#   * Ollama and the Hugging Face cache are copied from ./Runtime when it is staged (the
#     Ollama binaries are universal), otherwise fetched as for arm64. The mlx_metal_v4
#     folder is left out: its libraries are arm64 only, as Metal 4 exists only on Apple silicon.
#
# Requires: uv (https://docs.astral.sh/uv/) and curl; for ARCH=x86_64 on Apple silicon, Rosetta 2.
set -euo pipefail
cd "$(dirname "$0")"
ARCH=${ARCH:-arm64}
case "$ARCH" in
    arm64)  R="$PWD/Runtime";        UVARCH=aarch64; LOCK=requirements-lock.txt;        RUN=() ;;
    x86_64) R="$PWD/Runtime-x86_64"; UVARCH=x86_64;  LOCK=requirements-lock-x86_64.txt; RUN=(arch -x86_64) ;;
    *) echo "ARCH must be arm64 or x86_64, not $ARCH" >&2; exit 1 ;;
esac
PYVER=${PYVER:-3.12.13}
OLLAMA_VER=${OLLAMA_VER:-v0.33.3}
OLLAMA_MODELS_TO_BUNDLE=()      # none: build.sh does not copy Runtime/models/ollama into the app
HF_MODELS=(distilbert-base-uncased)

mkdir -p "$R"

if [[ ! -x "$R/python/bin/python3" ]]; then
    echo "== Python $PYVER ($ARCH)"
    rm -rf "$R/python-dl"
    uv python install "cpython-$PYVER-macos-$UVARCH-none" --install-dir "$R/python-dl"
    mv "$R/python-dl/cpython-$PYVER-macos-$UVARCH-none" "$R/python"
    rm -rf "$R/python-dl"
    rm -f "$R"/python/lib/python3.*/EXTERNALLY-MANAGED
fi
# ipykernel's kernelspec launches a bare "python"; make sure the bundle has one.
[[ -e "$R/python/bin/python" ]] || ln -s python3 "$R/python/bin/python"
PY="$R/python/bin/python3"
"${RUN[@]}" "$PY" -m pip install --quiet --upgrade pip
if [[ "$ARCH" == arm64 ]]; then
    if [[ -f "$LOCK" && -z "${UPGRADE:-}" ]]; then
        "$PY" -m pip install --quiet -r "$LOCK"      # the exact versions that were tested
    else
        "$PY" -m pip install --quiet --upgrade "numpy>=1.24" "scipy>=1.10" "matplotlib>=3.7" "jupyterlab>=4.0" \
            "requests>=2.28" "torch>=2.0" "transformers>=4.40" "ipywidgets>=8.0"
        "$PY" -m pip freeze --exclude-editable > "$LOCK"
    fi
else
    if [[ -f "$LOCK" && -z "${UPGRADE:-}" ]]; then
        REQS=(-r "$LOCK")                             # the exact versions that were tested
    else
        REQS=("numpy>=1.24,<2" "scipy>=1.10" "matplotlib>=3.7" "jupyterlab>=4.0" "requests>=2.28"
              "torch==2.2.2" "transformers>=4.40,<5.1" "ipywidgets>=8.0" "debugpy<1.8.17")
    fi
    WHEELS=$(mktemp -d)
    trap 'rm -rf "$WHEELS"' EXIT
    "${RUN[@]}" "$PY" -m pip download --quiet --only-binary=:all: --platform macosx_14_0_x86_64 \
        --dest "$WHEELS" "${REQS[@]}"
    "${RUN[@]}" "$PY" -m pip install --quiet --upgrade --no-index --find-links "$WHEELS" "${REQS[@]}"
    [[ "${REQS[1]}" == -r ]] || "${RUN[@]}" "$PY" -m pip freeze --exclude-editable > "$LOCK"
fi

# Python writes a missing or out-of-date __pycache__/*.pyc next to a module the first time it
# imports it. In the app that would add files to the signed bundle and break its seal. pip
# compiles the packages it installs, but python-build-standalone ships most of the standard
# library without bytecode, so the standard library is compiled here. Unchecked hash-based
# .pyc files are used without comparing them to the source, so they stay valid whatever
# modification times a copy or an unzip leaves.
echo "== bytecode"
"${RUN[@]}" "$PY" -m compileall -q -f -j0 --invalidation-mode unchecked-hash -x '/site-packages/' \
    "$R/python/lib/python${PYVER%.*}"

if [[ ! -x "$R/ollama/ollama" ]]; then
    if [[ "$ARCH" == x86_64 && -x Runtime/ollama/ollama ]]; then
        echo "== Ollama (copied from ./Runtime/ollama)"
        mkdir -p "$R/ollama"
        rsync -a --exclude '/mlx_metal_v4/' Runtime/ollama/ "$R/ollama/"
    else
        echo "== Ollama $OLLAMA_VER"
        mkdir -p "$R/ollama"
        curl -sSL -o "$R/ollama/ollama-darwin.tgz" \
            "https://github.com/ollama/ollama/releases/download/$OLLAMA_VER/ollama-darwin.tgz"
        tar xzf "$R/ollama/ollama-darwin.tgz" -C "$R/ollama"
        rm "$R/ollama/ollama-darwin.tgz"
        if [[ "$ARCH" == x86_64 ]]; then rm -rf "$R/ollama/mlx_metal_v4"; fi
    fi
fi
if [[ "$ARCH" == x86_64 ]]; then
    for f in "$R"/ollama/**/*(.); do
        archs=$(lipo -archs "$f" 2>/dev/null) || continue      # not a Mach-O file
        if [[ " $archs " != *" x86_64 "* ]]; then
            echo "$f has no x86_64 code ($archs); the Intel runtime cannot use it." >&2
            exit 1
        fi
    done
fi

echo "== Ollama models"
if (( ${#OLLAMA_MODELS_TO_BUNDLE[@]} )); then
    echo "OLLAMA_MODELS_TO_BUNDLE must stay empty: build.sh does not copy Runtime/models/ollama into the app." >&2
    exit 1
fi
echo "  none bundled; the Models window downloads the course models"
if [[ -d "$R/models/ollama" ]]; then
    echo "  $R/models/ollama is left from an earlier staging and is not copied into the app; delete it to free $(du -sh "$R/models/ollama" | cut -f1 | tr -d " ")."
fi

echo "== Hugging Face models"
mkdir -p "$R/models/hf/hub"
if [[ "$ARCH" == x86_64 && -d Runtime/models/hf/hub ]]; then
    # The cache the arm64 app ships; the weights and tokenizer files do not depend on the architecture.
    # xet/ holds only hf_xet's logs, which build.sh leaves out of the app.
    rsync -a --exclude '.locks' --exclude '/xet/' Runtime/models/hf/ "$R/models/hf/"
fi
for m in "${HF_MODELS[@]}"; do
    n="models--${m//\//--}"
    d="$HOME/.cache/huggingface/hub/$n"
    if [[ "$ARCH" == x86_64 && -d "$R/models/hf/hub/$n" ]]; then
        :   # copied from ./Runtime above
    elif [[ ! -d "$d" ]]; then
        echo "  downloading $m into the bundled cache"
        HF_HOME="$R/models/hf" "${RUN[@]}" "$PY" -c "from transformers import AutoTokenizer, AutoModel; AutoTokenizer.from_pretrained('$m'); AutoModel.from_pretrained('$m')"
    else
        rsync -a --exclude '.locks' "$d" "$R/models/hf/hub/"
    fi
    echo "  bundled $m"
done

echo "== manifest"
case "$ARCH" in
    arm64)  DESC="macOS arm64" ;;
    x86_64) DESC="macOS x86_64, Intel; Ollama runs on the CPU" ;;
esac
{
  echo "NotebookDeck bundled runtime ($DESC), generated $(date -u +%Y-%m-%dT%H:%MZ)"; echo
  echo "Python: $("${RUN[@]}" "$PY" --version)"; echo "Ollama: $("${RUN[@]}" "$R/ollama/ollama" --version 2>/dev/null | tail -1 | sed 's/.*version is //')"; echo
  echo "Ollama models:"; echo "  none bundled (Models > Manage Models… downloads the course models)"; echo
  echo "Hugging Face models:"; for d in "$R"/models/hf/hub/models--*; do echo "  $(basename $d | sed 's/^models--//; s/--/\//g')"; done; echo
  echo "Python packages ($(ls -d "$R"/python/lib/python3.*/site-packages/*.dist-info | wc -l | tr -d ' ')):"; "${RUN[@]}" "$PY" -m pip freeze | sed 's/^/  /'
} > "$R/MANIFEST.txt"
echo "Runtime staged: $(du -sh "$R" | cut -f1)"
