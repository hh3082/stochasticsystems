#!/bin/zsh
# Populates ./Runtime with everything the bundled notebooks need. Run once (or after
# changing versions); build.sh copies the result into the app.
#
#   Runtime/python        relocatable CPython 3.12 (python-build-standalone, via uv)
#                         + numpy scipy matplotlib jupyterlab requests torch transformers
#   Runtime/ollama        official Ollama macOS CLI tarball (universal binary + ggml/MLX libs)
#   Runtime/models/ollama qwen2.5:0.5b and qwen2.5:3b, copied from ~/.ollama/models
#   Runtime/models/hf     Hugging Face cache with distilbert-base-uncased (ch02 lab)
#
# Requires: uv (https://docs.astral.sh/uv/), curl, and an Ollama install that has
# already pulled the two models (`ollama pull qwen2.5:0.5b`, `ollama pull qwen2.5:3b`).
set -euo pipefail
cd "$(dirname "$0")"
R="$PWD/Runtime"
PYVER=${PYVER:-3.12.13}
OLLAMA_VER=${OLLAMA_VER:-v0.33.3}
OLLAMA_MODELS_TO_BUNDLE=(qwen2.5:0.5b qwen2.5:3b)
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
"$PY" -m pip install --quiet "numpy>=1.24" "scipy>=1.10" "matplotlib>=3.7" "jupyterlab>=4.0" \
    "requests>=2.28" "torch>=2.0" "transformers>=4.40"

if [[ ! -x "$R/ollama/ollama" ]]; then
    echo "== Ollama $OLLAMA_VER"
    mkdir -p "$R/ollama"
    curl -sSL -o "$R/ollama/ollama-darwin.tgz" \
        "https://github.com/ollama/ollama/releases/download/$OLLAMA_VER/ollama-darwin.tgz"
    tar xzf "$R/ollama/ollama-darwin.tgz" -C "$R/ollama"
    rm "$R/ollama/ollama-darwin.tgz"
fi

echo "== Ollama models"
"$PY" - "$R/models/ollama" "${OLLAMA_MODELS_TO_BUNDLE[@]}" <<'PYEOF'
import json, os, shutil, sys
dst = sys.argv[1]; home = os.path.expanduser("~/.ollama/models")
for spec in sys.argv[2:]:
    name, tag = spec.split(":")
    mf = f"{home}/manifests/registry.ollama.ai/library/{name}/{tag}"
    if not os.path.exists(mf):
        sys.exit(f"{spec} is not pulled locally; run: ollama pull {spec}")
    os.makedirs(f"{dst}/manifests/registry.ollama.ai/library/{name}", exist_ok=True)
    os.makedirs(f"{dst}/blobs", exist_ok=True)
    shutil.copy2(mf, f"{dst}/manifests/registry.ollama.ai/library/{name}/{tag}")
    m = json.load(open(mf))
    for layer in m["layers"] + [m["config"]]:
        b = layer["digest"].replace(":", "-")
        if not os.path.exists(f"{dst}/blobs/{b}"):
            shutil.copy2(f"{home}/blobs/{b}", f"{dst}/blobs/{b}")
    print("  bundled", spec)
PYEOF

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

echo "Runtime staged: $(du -sh "$R" | cut -f1)"
