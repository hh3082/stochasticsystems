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

## Intel build

A separate app for Intel Macs (x86_64, macOS 14 or later) is built from the same sources
with `ARCH=x86_64`. It has the same features as the Apple silicon app.

```bash
ARCH=x86_64 ./stage_runtime.sh   # once: x86_64 Python + packages into ./Runtime-x86_64 (~1.9 GB)
ARCH=x86_64 ./build.sh           # writes ~/Library/Caches/NotebookDeck-intel/NotebookDeck.app
```

`stage_runtime.sh` installs the x86_64 build of CPython 3.12 and runs its pip under Rosetta,
so on an Apple silicon Mac it needs Rosetta 2. The packages come from
`requirements-lock-x86_64.txt`, whose versions are set by PyTorch. torch 2.2.2 is the last
PyTorch release with macOS x86_64 wheels, and it is built against numpy 1.x. The pins that
differ from the arm64 lock, and why:

| Package | Intel lock | arm64 lock | Reason |
|---|---|---|---|
| torch | 2.2.2 | 2.14.0 | last PyTorch with macOS x86_64 wheels |
| numpy | 1.26.4 | 2.5.2 | torch 2.2.2 is built against numpy 1.x |
| transformers | 5.0.0 | 5.16.1 | transformers 5.1 and later require torch 2.4 or later |
| tokenizers | 0.22.2 | 0.23.2 | transformers 5.0.0 accepts tokenizers up to 0.23.0 |
| scipy | 1.17.1 | 1.18.1 | scipy 1.18 requires numpy 2 |
| debugpy | 1.8.16 | 1.8.21 | later releases are built for macOS 15 only |

The ch02 lab's training code (`AutoTokenizer`, `AutoModelForSequenceClassification` loaded
offline from the bundled cache, one `torch.optim.AdamW` step) runs with these versions on a
toy batch. pip installs wheels only, and only wheels built for macOS 14 or earlier. It
downloads them with `--platform macosx_14_0_x86_64` and installs from that folder alone.
`UPGRADE=1` re-resolves the lock within these pins.

Ollama and the distilbert cache are copied from `./Runtime` when it is staged; otherwise the
script downloads them. The Ollama binaries are universal. The `mlx_metal_v4` folder is left
out, because its libraries are arm64 only (Metal 4 needs Apple silicon). The x86_64 Ollama
has no Metal backend, so on an Intel Mac the course models run on the CPU (the Ollama log
reports `library=cpu`); expect slower answers than on Apple silicon.

With `ARCH=x86_64`, `build.sh` compiles the Swift code for x86_64 in `.build-x86_64` (the
Command Line Tools suffice), copies `./Runtime-x86_64` into the bundle, and writes to
`~/Library/Caches/NotebookDeck-intel` unless `APP_DIR` is set, so it never replaces the
arm64 app in `~/Applications`. It then checks every Mach-O file that `sign_and_notarize.sh`
signs, and stops if one has no x86_64 code or needs a macOS newer than the app's minimum
(14.0). The Intel app comes to about 1.9 GB. Students with Apple silicon Macs should get
the arm64 app.

## What is inside the self-contained app

| Piece | Where | Size |
|---|---|---|
| CPython 3.12 (python-build-standalone) with numpy, scipy, matplotlib, jupyterlab, requests, torch, transformers, ipywidgets | `Contents/Resources/runtime/python` | 1.3 GB |
| Ollama 0.33.3 command-line server (official tarball) | `Contents/Resources/runtime/ollama` | 0.5 GB |
| `distilbert-base-uncased` (chapter 2 fine-tune) | `Contents/Resources/runtime/models/hf` | 0.3 GB |
| The fallback course model list (`course_models.json`) | `Contents/Resources` | tiny |
| The lab notebooks | `Contents/Resources/notebooks` | tiny |

The app comes to about 2.1 GB. The course models are downloaded into the per-user store
instead: `qwen2.5:0.5b` (0.4 GB), `qwen2.5:3b` (1.9 GB) and `qwen2.5-3b-distilled`
(2.5 GB, the chapter 5 lab).

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
  Each step is logged in `app.log`.
* **The course model list.** The rows come from `course_models.json` in the Hugging Face
  dataset [purdue-ie336/course-models](https://huggingface.co/datasets/purdue-ie336/course-models),
  so editing that one file changes the list in every copy of the app, without a rebuild.
  Each time the Models window refreshes, the app fetches
  `https://huggingface.co/datasets/purdue-ie336/course-models/resolve/main/course_models.json`
  without cookies, cache or stored credentials, allowing 5 seconds and reading at most
  64 KB. The window opens at launch unless "Show this window when NotebookDeck opens" is
  turned off; the list is then fetched when the window is first opened, and until then the
  toolbar's list of missing models uses the saved or built-in list. The fetch follows a
  redirect only to an https address on huggingface.co or one of its subdomains (Hugging Face
  redirects the file to `/api/resolve-cache/...` on the same host), and any other redirect
  stops it. The file must be strict JSON (UTF-8 without a byte-order mark, with no trailing
  commas, comments or other extensions): an array of 1 to 50 objects with the fields `name`
  (the name notebooks ask Ollama for, valid for Ollama and not starting with `-`), `source`
  (the repo to pull, `hf.co/purdue-ie336/REPO` or `hf.co/purdue-ie336/REPO:TAG`, where REPO
  and TAG consist of letters, digits, `.`, `_` and `-` and start with a letter, digit or
  `_`, so the list cannot point outside the course's organization) and `size` (the GGUF
  size in bytes, an integer from 1 to 200,000,000,000 written without a fraction or
  exponent, so `1e3` and `1000.0` are refused). No key may appear twice in an entry. No
  name may appear twice, and no name may equal the source of any entry, its own or
  another's, since a download pulls the source under the source's name and then deletes
  that name. Names are compared as Ollama compares them, ignoring case and a `:latest` tag.
  Other fields are ignored, so a field added later, such as a `note`, does not break older
  copies of the app.
  A list that passes these checks replaces the rows and is saved to
  `~/Library/Application Support/NotebookDeck/course_models.json`. When the fetch fails or
  the list fails a check, the app uses that saved copy if it exists and passes the checks.
  Otherwise it uses the list built into the app, `Contents/Resources/course_models.json`
  (which `build.sh` copies from `Resources/course_models.json`), or, when that file is
  missing or fails a check, the same list compiled into `CourseModels.swift`. The window
  never waits for the network. It shows the saved or built-in list at once and swaps in the
  fetched one when it arrives; a list that arrives while a download (or another operation of
  the window) runs takes effect when it ends. The rows' statuses and the toolbar's list of
  missing models follow the list in use. Once the first fetch has returned, a caption under
  the rows reads "List from Hugging Face", "Saved list (offline)" or "List built into the
  app"; it is hidden before then, since the list shown at launch says nothing about the
  network. "Saved list (offline)" also appears when Hugging Face answers with a list that
  fails a check. `app.log` records which list is in use and why. To change the list for everyone, edit the file on Hugging Face. To change the
  fallback as well, edit `Resources/course_models.json` and `CourseModels.builtIn`, then
  rebuild.
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
cache (`HF_HUB_OFFLINE=1`), and hf_xet keeps its logs in `HF_XET_CACHE` under Application
Support. Ollama serves from the per-user store. The bundle itself is never written to:
pip compiles the packages it installs, `stage_runtime.sh` compiles the standard library
(unchecked hash-based `.pyc` files, valid whatever modification times a copy leaves),
and the app sets `PYTHONDONTWRITEBYTECODE=1`, so Python never adds a `__pycache__` file
to the signed app.

## Everything is inside the app

The application depends on nothing installed on the machine beyond macOS itself; the
course models, and the short list that names them, are the only things it downloads after
installation, from the Models window.
This is checked, not assumed:

* `File > Audit Bundled Runtime…` imports the top-level module of all 268 installed
  Python packages under an isolated interpreter (`python -I -B`) and confirms that `sys.path`
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
service, waits for the ticket, staples it, and writes `~/NotebookDeck-releases/NotebookDeck-mac.zip` (outside the iCloud-synced Desktop),
which opens on any Apple silicon Mac with macOS 14+ with no prompts. The zip is written
without AppleDouble metadata so it survives any unzipper; a zip made with plain
`ditto -c -k` verifies only when unpacked by Archive Utility, and otherwise produces the
"NotebookDeck is damaged and can't be opened" error. `--dry-run` only
lists what would be signed. Notarization of the 2 GB upload typically takes 15–60 minutes.

The Intel app is signed the same way and goes into its own zip, which `OUT` names:

```bash
APP=~/Library/Caches/NotebookDeck-intel/NotebookDeck.app OUT=~/NotebookDeck-releases/NotebookDeck-mac-intel.zip ./sign_and_notarize.sh
```

Without this, the app is ad-hoc signed: it runs here, but a downloaded copy needs System
Settings > Privacy & Security > Open Anyway on each Mac. `NotebookDeck-mac.zip` needs an
Apple silicon Mac; Intel Macs get `NotebookDeck-mac-intel.zip`.

## Troubleshooting

* File > Show Jupyter Log and File > Show Ollama Log open the servers' output.
  `~/Library/Logs/NotebookDeck/app.log` records what the app opened and started.
* File > Restart Jupyter Server and File > Restart Ollama restart the bundled servers.
* If you built without `./Runtime` and the app cannot find `jupyter`, use
  File > Set Jupyter Executable….
