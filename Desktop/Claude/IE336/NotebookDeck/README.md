# NotebookDeck

A macOS app that shows a live Jupyter notebook and a slide deck side by side in one
window, for lecture demos. Built self-contained, it also carries everything the IE 336
lab notebooks need: Python, the packages, Ollama, and the model weights. No install
steps on the presenting machine.

## Build

Needs only the Xcode Command Line Tools (no Xcode.app). To build the self-contained
version you also need `uv` and an Ollama install that has pulled `qwen2.5:0.5b` and
`qwen2.5:3b`.

```bash
./stage_runtime.sh   # once: downloads Python + packages + Ollama, copies the models (~4.3 GB into ./Runtime)
./build.sh           # writes ~/Applications/NotebookDeck.app
```

Without `./Runtime` the build is a 1 MB app that uses whatever `jupyter` and Ollama the
machine already has. `build.sh` copies the notebooks from the StochMod book's
`notebooks/` folder (override with `NOTEBOOKS_DIR=...`).

## What is inside the self-contained app

| Piece | Where | Size |
|---|---|---|
| CPython 3.12 (python-build-standalone) with numpy, scipy, matplotlib, jupyterlab, requests, torch, transformers | `Contents/Resources/runtime/python` | 1.3 GB |
| Ollama 0.33.3 command-line server (official tarball) | `Contents/Resources/runtime/ollama` | 0.5 GB |
| `qwen2.5:0.5b`, `qwen2.5:3b` weights | `Contents/Resources/runtime/models/ollama` | 2.2 GB |
| `distilbert-base-uncased` (chapter 2 fine-tune) | `Contents/Resources/runtime/models/hf` | 0.3 GB |
| The seven lab notebooks | `Contents/Resources/notebooks` | tiny |

## Use

* **Bundled notebooks.** File > Bundled Notebooks lists the labs. Picking one copies all
  of them to `~/Documents/NotebookDeck Notebooks` (existing files are never
  overwritten, so edits survive), starts the bundled JupyterLab rooted there, and opens
  the notebook. "Reset Bundled Notebooks…" restores the originals after confirmation.
* **Any other notebook.** ⌘O or drop a `.ipynb` on the left pane; the bundled server
  restarts rooted at that folder. ⌘L loads an arbitrary URL (a server you started
  yourself, JupyterHub, nbviewer).
* **Ollama.** When a notebook opens, the app checks port 11434 (the address the labs
  hard-code). If your own Ollama is already there it is left alone and the toolbar
  warns if it lacks the two models; otherwise the bundled server starts from the
  bundled, read-only model store. Nothing is downloaded.
* **Slides.** ⇧⌘O or drop a PDF on the right pane. One slide at a time, fitted; the
  "Scroll" toggle gives continuous scrolling. Arrow keys / space when that pane is
  focused, or the Slides menu (⌥⌘→ / ⌥⌘←, ⌘G go to slide). Position is remembered per
  file. `.pptx` / `.key` open through Quick Look without page controls.
* **Layout.** View menu: Swap Panes (⇧⌘S), Side by Side / Stacked, Show Toolbars
  (⇧⌘T), Presentation Mode (⇧⌘P = toolbars off + full screen).
* Last notebook and deck reopen at launch. Quitting stops the servers the app started;
  a watchdog also kills them if the app dies any other way.

## Isolation

The bundled Jupyter and its kernels run with `PYTHONNOUSERSITE=1`, no `PYTHONPATH`, and
their own `JUPYTER_DATA_DIR` / `JUPYTER_CONFIG_DIR` / `IPYTHONDIR` / `MPLCONFIGDIR` under
`~/Library/Application Support/NotebookDeck`, so nothing from the machine's own
Python, conda, or Jupyter setup leaks in. Hugging Face runs offline against the bundled
cache (`HF_HUB_OFFLINE=1`). Ollama's model store is read straight from the bundle.

## Giving the app to someone else

```bash
ditto -c -k --keepParent ~/Applications/NotebookDeck.app NotebookDeck.zip
```

The app is ad-hoc signed, not notarized, so the first launch on another Mac needs
right-click > Open. Apple silicon only.

## Troubleshooting

* File > Show Jupyter Log and File > Show Ollama Log open the servers' output.
  `~/Library/Logs/NotebookDeck/app.log` records what the app opened and started.
* File > Restart Jupyter Server and File > Restart Ollama restart the bundled servers.
* If you built without `./Runtime` and the app cannot find `jupyter`, use
  File > Set Jupyter Executable….
