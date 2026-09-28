# NotebookDeck

A macOS app that shows a live Jupyter notebook and a slide deck side by side in one
window, for lecture demos. Built self-contained, it also carries what the IE 336 lab
notebooks need: Python, the packages, Ollama, and the distilbert weights of the chapter 2
lab. The Qwen models that the other labs ask Ollama for are not bundled; students download
them once from the Models window (Models > Manage Models…, "Course models"). No other
install steps on the presenting machine.

## Build

Needs only the Xcode Command Line Tools (no Xcode.app). To build the self-contained
version you also need `uv`.

```bash
./stage_runtime.sh   # once: downloads Python + packages + Ollama and the distilbert cache (~2 GB into ./Runtime)
./build.sh           # writes ~/Applications/NotebookDeck.app
```

`stage_runtime.sh` stages no Ollama models, and `build.sh` leaves `Runtime/models/ollama`
out of the app even when an earlier staging left one there (it prints its size; delete it
to free the space). A bundle built before this change loses its `models/ollama` folder at
the next build.

Without `./Runtime` the build is a 1 MB app that uses whatever `jupyter` and Ollama the
machine already has. `build.sh` copies the notebooks from the StochMod book's
`notebooks/` folder (override with `NOTEBOOKS_DIR=...`).

## What is inside the self-contained app

| Piece | Where | Size |
|---|---|---|
| CPython 3.12 (python-build-standalone) with numpy, scipy, matplotlib, jupyterlab, requests, torch, transformers, ipywidgets | `Contents/Resources/runtime/python` | 1.3 GB |
| Ollama 0.33.3 command-line server (official tarball) | `Contents/Resources/runtime/ollama` | 0.5 GB |
| `distilbert-base-uncased` (chapter 2 fine-tune) | `Contents/Resources/runtime/models/hf` | 0.3 GB |
| The course model list (`course_models.json`) | `Contents/Resources` | tiny |
| The lab notebooks | `Contents/Resources/notebooks` | tiny |

The app comes to about 2.1 GB. The course models are downloaded into the per-user store
instead: `qwen2.5:0.5b` (0.4 GB), `qwen2.5:3b` (1.9 GB) and `qwen2.5-3b-distilled`
(3.3 GB, the chapter 5 lab).

## Use

* **Ready on launch.** Opening the app starts the bundled JupyterLab on the notebooks
  folder and shows its file browser, starts Ollama, and imports every required Python
  package once in the background (numpy, scipy, matplotlib, requests, jupyterlab, torch,
  transformers, ipywidgets). The toolbar reports "Python deps OK" or names what is missing, and
  File > Check Python Environment… shows the versions. The import pass also warms the disk
  cache, so the first `import torch` in a notebook takes a second instead of ten.
  ⇧⌘N returns to the file browser at any time.
* **Bundled notebooks.** File > Bundled Notebooks lists the labs. Picking one copies all
  of them to `~/NotebookDeck Notebooks` (existing files are never
  overwritten, so edits survive), starts the bundled JupyterLab rooted there, and opens
  the notebook. "Reset Bundled Notebooks…" restores the originals after confirmation.
* **Any other notebook.** ⌘O or drop a `.ipynb` on the left pane; the bundled server
  restarts rooted at that folder. ⌘L loads an arbitrary URL (a server you started
  yourself, JupyterHub, nbviewer).
* **Ollama.** When a notebook opens, the app checks port 11434 (the address the labs
  hard-code). If your own Ollama is already there it is left alone; otherwise the bundled
  server starts with a writable per-user store
  (`~/Library/Application Support/NotebookDeck/ollama/models`). The app ships no Ollama
  models, so a new store starts empty and `app.log` records that no models are bundled. A
  store from an earlier version, into which the bundled `qwen2.5:0.5b` and `qwen2.5:3b` were
  copied, is used as it is, and those two models show as installed. With either server, the
  toolbar names the course models it lacks, e.g. "Ollama: bundled, course models missing:
  qwen2.5-3b-distilled (Models > Manage Models…)".
* **Course models.** The Models window opens in front of the main window each time the app starts, so students can check which course models are installed and download the missing ones first; the checkbox "Show this window when NotebookDeck opens" at the bottom of the window turns this off. Models > Manage Models… (⇧⌘M) opens the Models window at any time. Its first
  section, "Course models", has one row per model the labs use: the name notebooks ask for,
  its size, its status, and a Download button; "Download All" fetches every row that is not
  installed. The status is "Installed" or "Not installed" (the running server lists the
  model as `name` or `name:latest`) once the server has listed its models; before that it
  reads "Checking…", or "Unknown" when the server does not answer, and the buttons are
  disabled. They are also disabled while a download runs and until the list has been read
  again after it. A download first checks that the disk holding the models has the model's
  size plus 1 GB free (for Download All, the sizes added up). The check counts the space
  free now, as `df` reports it; when only the space macOS can reclaim (local snapshots,
  cached files) makes it fit, the window asks before downloading, and otherwise it gives
  both figures and does not download. The model is then pulled from its Hugging Face repo
  (`hf.co/purdue-ie336/...`) through Ollama with a progress bar and a Cancel button. Cancel
  disappears once Ollama reports that it is verifying the files, since from then on Ollama
  finishes the pull even when the app stops waiting for it. The app gives the model the
  notebook name (`/api/copy`), removes the `hf.co/...` name (`/api/delete`) so the list
  shows the notebook name alone, and checks with `/api/show` that the notebook name answers.
  A `hf.co/...` name that a stopped or failed download leaves behind is removed too, at once
  when Ollama already lists it and otherwise by the next Download. Download on an installed
  row replaces that model after a confirmation; Download All asks the same about a model
  that turns out to be installed when its turn comes. A replacement copies the installed
  model to `NAME-replaced`, copies the download over `NAME`, and deletes `NAME-replaced`,
  which frees the files that only the old model used; if the copy over `NAME` fails, `NAME`
  keeps the old model. The repos carry Ollama's `template` and `system` files (the
  distilled model's repo has a `params` file too), so these models need no chat-format step.
  Each step is logged in `app.log`. The list lives in `Resources/course_models.json`
  (fields `name`, `source`, `size` in bytes), which `build.sh` copies into
  `Contents/Resources`; the app reads it once and falls back to the same list compiled into
  `CourseModels.swift` when the file is missing or malformed (for instance a size above
  1 TB, or one model listed twice). It is never fetched from the network. To change the
  list, edit both.
* **Adding other models.** The table below the course models lists what the running
  server has, with parameter count, quantization, and size. Type a name from
  [ollama.com/library](https://ollama.com/library) (for example `llama3.2:1b` or
  `qwen2.5:7b`) and press Pull to download it with a progress bar; "Import GGUF…"
  registers a `.gguf` file from disk under a name you choose; the trash button deletes a
  model after confirmation. The window manages whichever server is answering on 11434,
  so with your own Ollama.app running it adds to that store instead. Notebooks pick a
  model by the name shown in the first column, e.g. `"model": "llama3.2:1b"`.
* **Models from Hugging Face.** Under "Download from Hugging Face", enter a GGUF repo as
  `hf.co/OWNER/REPO`, `OWNER/REPO`, or a huggingface.co link; a link to one `.gguf` file
  selects that file. A `:TAG` suffix picks a quantization such as `:Q4_K_M`, or a file by
  its full name. Look Up lists the repo's `.gguf` files with their sizes, and says so when
  the repo does not exist, is private, or has no GGUF file. Files split into parts
  (`...-00001-of-00002.gguf`) are not listed, since Ollama cannot download a split GGUF from
  Hugging Face. Download pulls `hf.co/OWNER/REPO:TAG` through Ollama with a progress bar and
  a Cancel button; without a tag Ollama picks the quantization itself (Q4_K_M when the repo
  has it as a single file). For a file picked from the list, the tag is its quantization
  name when Hugging Face serves the file under that name, and its full file name otherwise
  (Hugging Face refuses a few quantization names, such as Q4_K_L, as tags). Ollama applies
  the repo's own `template`, `system` and `params` files when present. The model is listed
  under its full `hf.co/...` name; "Name for notebooks" gives it a second, shorter name, and
  both names share the same files.
* **GGUF files from a link.** "Download a GGUF from a link" takes an https link, and stops
  if the server redirects it to a plain http address. Hugging Face `/blob/` pages and
  Dropbox share links are rewritten to direct downloads; Google Drive links are refused
  (download the file in a browser, then use Import GGUF…). When the server reports the file
  size, before or at the start of the transfer, the download goes ahead only if the disk has
  three times that size plus 1 GB free: room for the file and for the two copies Ollama
  0.33.3 writes while importing it. As for the course models, the space free now is what
  counts; when only the space macOS can reclaim makes it fit, the window asks first (a size
  the server first gives at the start of the transfer is not asked about). Any download
  stops if the free space falls below 1 GB, which also covers a server that reports no
  size. The file is saved in
  `~/Library/Application Support/NotebookDeck/downloads` and deleted at once if it does not
  start with the GGUF signature (the link led to a web page, for instance). Otherwise it is
  imported under a name you choose, as with Import GGUF…, and deleted after a successful
  import, since Ollama keeps its own copy. If the import fails or is declined, the file stays
  in that folder and the window gives its path.
* **Chat format of imported files.** After Import GGUF… or a download from a link, the app
  reads `tokenizer.chat_template` from the file's GGUF header. When that template uses
  ChatML (`<|im_start|>`, as Qwen models and many fine-tunes do), the model is recreated
  with Ollama's Go template for Qwen2.5 and, when the file's template contains it, the
  default Qwen system message ("You are Qwen, created by Alibaba Cloud. You are a helpful
  assistant."), unless `/api/show` already reports that template and that system message.
  A FROM-only import under Ollama 0.33.3 keeps the file's own Jinja template instead;
  with the Go template an imported Qwen model has the chat format of the course models,
  whose repos carry the same template and system files. For a file whose template is not ChatML, the model is
  left as imported; when Ollama reports no template for it (an empty one or
  `{{ .Prompt }}`), the window notes that chat requests may not behave as intended (raw
  prompts are unaffected). `app.log` records what was done.
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
cache (`HF_HUB_OFFLINE=1`). Ollama serves from the per-user store; the bundle itself is
never written to.

## Everything is inside the app

The application depends on nothing installed on the machine beyond macOS itself; the
course models are the one thing it downloads after installation, from the Models window.
This is checked, not assumed:

* `File > Audit Bundled Runtime…` imports the top-level module of all 268 installed
  Python packages under an isolated interpreter (`python -I`) and confirms that `sys.path`
  and every loaded module lie inside the app. The same script, `Resources/runtime_check.py`,
  can be run by hand.
* At build time, `otool -L` over the 288 native binaries in the bundle shows no link to
  anything outside the bundle or `/usr/lib` and `/System`.
* `Contents/Resources/runtime/MANIFEST.txt` lists the Python version, Ollama version,
  the bundled models (no Ollama models; `build.sh` rewrites that line in a manifest staged
  before the change), and every package with its version. `requirements-lock.txt` in this folder
  pins the same package set for `stage_runtime.sh`, so a rebuild gets the versions that
  were tested (set `UPGRADE=1` to refresh them).
* `build.sh` refuses to produce an app without `./Runtime` unless `ALLOW_SLIM=1` is set.

## Giving the app to someone else

For students, sign and notarize it so macOS opens it without any warning. One-time setup
with your Apple Developer account (no Xcode needed; the Command Line Tools have
`notarytool` and `stapler`):

1. **Certificate.** Open Keychain Access > Certificate Assistant > Request a Certificate
   From a Certificate Authority; enter your email, choose "Saved to disk". At
   developer.apple.com/account > Certificates click +, choose **Developer ID
   Application**, upload the request, download the `.cer` and double-click it. Check with
   `security find-identity -v -p codesigning` that a "Developer ID Application" line
   appears. If codesign later complains about the chain, install Apple's "Developer ID
   G2" intermediate from apple.com/certificateauthority.
2. **Notarization password.** At account.apple.com > Sign-In and Security > App-Specific
   Passwords create one, then run
   `xcrun notarytool store-credentials NotebookDeck --apple-id YOU@purdue.edu --team-id TEAMID`
   (the team ID is on developer.apple.com/account under Membership) and paste it when asked.

Then, after every `./build.sh`:

```bash
./sign_and_notarize.sh
```

It signs all ~290 binaries inside the bundle and the app itself with the hardened runtime
and the entitlements in `Resources/entitlements.plist`, uploads the app to Apple's notary
service, waits for the ticket, staples it, and writes `~/Desktop/NotebookDeck-mac.zip`,
which opens on any Apple silicon Mac with macOS 14+ with no prompts. The zip is written
without AppleDouble metadata so it survives any unzipper; a zip made with plain
`ditto -c -k` verifies only when unpacked by Archive Utility, and otherwise produces the
"NotebookDeck is damaged and can't be opened" error. `--dry-run` only
lists what would be signed. Notarization of the 2 GB upload typically takes 15–60 minutes.

Without this, the app is ad-hoc signed: it runs here, but a downloaded copy needs System
Settings > Privacy & Security > Open Anyway on each Mac. Apple silicon only either way.

## Troubleshooting

* File > Show Jupyter Log and File > Show Ollama Log open the servers' output.
  `~/Library/Logs/NotebookDeck/app.log` records what the app opened and started.
* File > Restart Jupyter Server and File > Restart Ollama restart the bundled servers.
* If you built without `./Runtime` and the app cannot find `jupyter`, use
  File > Set Jupyter Executable….
