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
# Requires: uv (https://docs.astral.sh/uv/) and curl.
set -euo pipefail
cd "$(dirname "$0")"
R="$PWD/Runtime"
PYVER=${PYVER:-3.12.13}
OLLAMA_VER=${OLLAMA_VER:-v0.33.3}
OLLAMA_MODELS_TO_BUNDLE=()      # none: build.sh does not copy Runtime/models/ollama into the app
HF_MODELS=(distilbert-base-uncased)

mkdir -p "$R"

if [[ ! -x "$R/python/bin/python3" ]]; then
    echo "== Python $PYVER"
    rm -rf "$R/python-dl"
    uv python install "$PYVER" --install-dir "$R/python-dl"
    mv "$R/python-dl/cpython-$PYVER-macos-aarch64-none" "$R/python"
    rm -rf "$R/python-dl"
    rm -f "$R"/python/lib/python3.*/EXTERNALLY-MANAGED
fi
# ipykernel's kernelspec launches a bare "python"; make sure the bundle has one.
[[ -e "$R/python/bin/python" ]] || ln -s python3 "$R/python/bin/python"
PY="$R/python/bin/python3"
"$PY" -m pip install --quiet --upgrade pip
if [[ -f requirements-lock.txt && -z "${UPGRADE:-}" ]]; then
    "$PY" -m pip install --quiet -r requirements-lock.txt      # the exact versions that were tested
else
    "$PY" -m pip install --quiet --upgrade "numpy>=1.24" "scipy>=1.10" "matplotlib>=3.7" "jupyterlab>=4.0" \
        "requests>=2.28" "torch>=2.0" "transformers>=4.40" "ipywidgets>=8.0"
    "$PY" -m pip freeze --exclude-editable > requirements-lock.txt
fi

if [[ ! -x "$R/ollama/ollama" ]]; then
    echo "== Ollama $OLLAMA_VER"
    mkdir -p "$R/ollama"
    curl -sSL -o "$R/ollama/ollama-darwin.tgz" \
        "https://github.com/ollama/ollama/releases/download/$OLLAMA_VER/ollama-darwin.tgz"
    tar xzf "$R/ollama/ollama-darwin.tgz" -C "$R/ollama"
    rm "$R/ollama/ollama-darwin.tgz"
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
for m in "${HF_MODELS[@]}"; do
    d="$HOME/.cache/huggingface/hub/models--${m//\//--}"
    if [[ ! -d "$d" ]]; then
        echo "  downloading $m into the bundled cache"
        HF_HOME="$R/models/hf" "$PY" -c "from transformers import AutoTokenizer, AutoModel; AutoTokenizer.from_pretrained('$m'); AutoModel.from_pretrained('$m')"
    else
        rsync -a --exclude '.locks' "$d" "$R/models/hf/hub/"
    fi
    echo "  bundled $m"
done

echo "== manifest"
{
  echo "NotebookDeck bundled runtime (macOS arm64), generated $(date -u +%Y-%m-%dT%H:%MZ)"; echo
  echo "Python: $("$PY" --version)"; echo "Ollama: $("$R/ollama/ollama" --version 2>/dev/null | tail -1 | sed 's/.*version is //')"; echo
  echo "Ollama models:"; echo "  none bundled (Models > Manage Models… downloads the course models)"; echo
  echo "Hugging Face models:"; for d in "$R"/models/hf/hub/models--*; do echo "  $(basename $d | sed 's/^models--//; s/--/\//g')"; done; echo
  echo "Python packages ($(ls -d "$R"/python/lib/python3.*/site-packages/*.dist-info | wc -l | tr -d ' ')):"; "$PY" -m pip freeze | sed 's/^/  /'
} > "$R/MANIFEST.txt"
echo "Runtime staged: $(du -sh "$R" | cut -f1)"
