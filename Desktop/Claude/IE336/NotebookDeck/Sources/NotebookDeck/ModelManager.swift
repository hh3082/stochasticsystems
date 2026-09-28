import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// State behind the Models window.
@MainActor
final class ModelManager: ObservableObject {
    @Published var models: [OllamaModel] = []
    /// False until /api/tags has answered with a list, and again whenever it does not. The
    /// course rows then show no status and their Download buttons are disabled.
    @Published var modelsKnown = false
    /// Refreshes under way; the course rows read "Checking…" while the list is not yet known.
    @Published private(set) var refreshing = 0
    @Published var serverLabel = "Ollama is not running"
    @Published var storeLabel = ""
    @Published var pullName = ""
    /// True while an operation (a download, an import, a lookup) runs. When it turns false, a
    /// course list that arrived meanwhile takes effect.
    @Published var busy = false {
        didSet {
            if !busy, let list = pendingList {
                pendingList = nil
                useCourseList(list)
            }
        }
    }
    @Published var progressText = ""
    @Published var progressFraction: Double? = nil
    @Published var message: String?
    @Published var canCancel = false

    // Download from Hugging Face
    @Published var hfInput = ""
    @Published var hfFiles: [HFFile] = []
    @Published var hfSelection: String?          // path of the chosen file; nil = Ollama's default choice
    @Published var hfDownloaded: String?         // last model pulled from Hugging Face, offered a second name
    @Published var hfAlias = ""

    // Download a GGUF from a link
    @Published var linkInput = ""

    /// The models the lab notebooks use: the saved or built-in list at first, then the list
    /// from Hugging Face once a refresh has fetched it (CourseModels).
    @Published private(set) var courseModels: [CourseModel]
    /// Where `courseModels` came from, for the caption under the rows.
    @Published private(set) var courseListOrigin: CourseModels.Origin
    /// False until the outcome of this session's first fetch of the course list is shown. The
    /// caption stays hidden until then: the list shown at launch says nothing about the
    /// network, so "Saved list (offline)" would be wrong while the first fetch is under way.
    @Published private(set) var courseListChecked = false

    /// Receives the toolbar's Ollama status line after each refresh.
    var onStatus: ((String) -> Void)?

    private let server: OllamaServer
    private var current: Task<Void, Never>?
    /// Numbers each pull, so progress reports that arrive after it ended are dropped.
    private var pullSerial = 0
    /// The fetch of the course list under way, if any.
    private var listFetch: Task<Void, Never>?
    /// A course list that arrived while an operation ran; it takes effect when the operation ends.
    private var pendingList: CourseModels.Choice?
    /// The server part of the last status line, kept so the line can be redone for a new list.
    private var statusBase: String?

    init(server: OllamaServer) {
        self.server = server
        courseModels = CourseModels.atLaunch.list
        courseListOrigin = CourseModels.atLaunch.origin
    }

    func refresh() async {
        fetchCourseList()
        refreshing += 1
        defer { refreshing -= 1 }
        let status = await server.ensureRunning()
        switch server.mode {
        case .bundled:
            serverLabel = "Bundled Ollama server on port \(OllamaServer.port)"
            storeLabel = "Models are stored in \(OllamaServer.modelStore.path)"
        case .external:
            serverLabel = "Your own Ollama server on port \(OllamaServer.port)"
            storeLabel = "Models are stored in its own store (usually ~/.ollama/models)"
        case .none:
            serverLabel = status
            storeLabel = ""
        }
        let list = await OllamaServer.models()
        models = (list ?? []).sorted { $0.name < $1.name }
        modelsKnown = list != nil
        statusBase = status
        onStatus?(OllamaServer.statusLine(status, installed: list?.map(\.name)))
    }

    /// Fetches the course list from `url` (Hugging Face; tests pass another address) without
    /// holding up the window or the refresh: the rows keep their list until the fetch returns,
    /// and CourseModels.choose then picks the fetched, saved or built-in list. One fetch runs at
    /// a time; the task returned is the one under way.
    @discardableResult
    func fetchCourseList(from url: URL = CourseModels.remoteURL) -> Task<Void, Never>? {
        if let listFetch { return listFetch }
        let task = Task {
            let fetched: Result<Data, Error>
            do { fetched = .success(try await CourseModels.fetch(url)) } catch { fetched = .failure(error) }
            let choice = CourseModels.choose(fetched: fetched)
            listFetch = nil
            offerCourseList(choice)
        }
        listFetch = task
        return task
    }

    /// Shows `choice` at once, or, while an operation such as a download runs, when it ends.
    private func offerCourseList(_ choice: CourseModels.Choice) {
        pendingList = nil
        guard choice.list != courseModels || choice.origin != courseListOrigin else {
            courseListChecked = true
            return
        }
        if busy {
            pendingList = choice
            AppLog.write("course models: an operation is running; the new list takes effect when it ends")
        } else {
            useCourseList(choice)
        }
    }

    /// Makes `choice` the list of the rows and of the toolbar's status line. The rows' statuses
    /// follow, since they come from the installed models and not from the list. While a
    /// refresh runs, the toolbar line is left to it: the refresh ends by setting the line from
    /// its own server status and CourseModels.current, whereas `statusBase` is from the
    /// refresh before and may be out of date (e.g. after Restart Ollama).
    private func useCourseList(_ choice: CourseModels.Choice) {
        CourseModels.setCurrent(choice.list)
        courseModels = choice.list
        courseListOrigin = choice.origin
        courseListChecked = true
        AppLog.write("course models: the Models window now lists \(choice.list.map(\.name).joined(separator: ", ")) (\(choice.origin.caption))")
        if let statusBase, refreshing == 0 {
            onStatus?(OllamaServer.statusLine(statusBase, installed: modelsKnown ? models.map(\.name) : nil))
        }
    }

    /// Runs one model operation at a time behind the progress row, then refreshes the list.
    /// A cancellable operation shows a Cancel button.
    private func perform(cancellable: Bool, _ body: @escaping @MainActor () async -> Void) {
        busy = true
        canCancel = cancellable
        progressFraction = nil
        message = nil
        current = Task {
            await body()
            canCancel = false
            progressText = "Updating the list of models…"
            progressFraction = nil
            // After a Cancel this task is cancelled and its requests fail at once, so the list
            // is refreshed from a task of its own. The buttons stay disabled until it is, so no
            // row offers Download on a status from before the operation.
            await Task { await self.refresh() }.value
            busy = false
            progressText = ""
            current = nil
        }
    }

    /// Cancels the running operation while it shows a Cancel button, and at no later stage.
    func cancel() { if canCancel { current?.cancel() } }

    func pull() {
        let name = pullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy else { return }
        perform(cancellable: true) {
            guard await self.runPull(name) else { return }
            self.message = "Added \(name). Notebooks can now use \"model\": \"\(name)\"."
            self.pullName = ""
        }
    }

    /// Pulls `name` through Ollama with progress. Returns false (with a message) on failure or
    /// cancel. Messages call the model `display` when given; `progressPrefix` leads the progress text.
    private func runPull(_ name: String, as display: String? = nil, progressPrefix: String = "") async -> Bool {
        let shown = display ?? name
        pullSerial += 1
        let serial = pullSerial
        defer { pullSerial += 1 }
        progressText = progressPrefix + "Contacting registry…"
        do {
            try await OllamaServer.pull(name) { status, fraction in
                Task { @MainActor in
                    guard self.pullSerial == serial else { return }
                    self.progressText = progressPrefix + status
                    self.progressFraction = fraction
                    // Once every file has arrived, Ollama finishes the pull even if the
                    // connection closes, so Cancel would no longer stop it.
                    if OllamaServer.pullIsPastDownload(status) { self.canCancel = false }
                }
            }
            AppLog.write("ollama: pulled \(name)")
            return true
        } catch {
            if Task.isCancelled {
                AppLog.write("ollama: pull of \(name) cancelled")
                message = "Stopped pulling \(shown)."
            } else {
                AppLog.write("ollama: pull of \(name) failed: \(error.localizedDescription)")
                message = "Could not pull \(shown): \(error.localizedDescription)"
            }
            return false
        }
    }

    func delete(_ model: OllamaModel) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.name)?"
        alert.informativeText = "This removes the model (\(model.sizeText)) from the store. Pull it again to get it back."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await OllamaServer.delete(model.name)
                AppLog.write("ollama: deleted \(model.name)")
            } catch {
                message = error.localizedDescription
            }
            await refresh()
        }
    }

    func importGGUF() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGUF model file"
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let name = askModelName(for: file) else { return }
        perform(cancellable: false) { _ = await self.importFile(file, as: name) }
    }

    /// Asks for the name notebooks will use; the default is the file name without extension.
    /// A name Ollama would not accept is asked for again.
    private func askModelName(for file: URL) -> String? {
        var name = file.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Name for this model"
            alert.informativeText = (problem.map { $0 + "\n\n" } ?? "") + "The name notebooks will use, e.g. mymodel:7b"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = name
            alert.accessoryView = field
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return nil }
            if OllamaServer.isValidModelName(name) { return name }
            problem = "\(name) is not a valid model name. \(OllamaServer.modelNameRule)"
        }
    }

    /// Runs a modal dialog from the main run loop instead of inside the calling task. A modal
    /// run inside a main-actor task holds up every other main-actor task and main-queue block
    /// until it closes; one started from the run loop (a button action, or this timer) does not.
    private func runOutsideTask<T: Sendable>(_ body: @escaping @MainActor @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            let timer = Timer(timeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { c.resume(returning: body()) }
            }
            RunLoop.main.add(timer, forMode: .default)
        }
    }

    /// Registers `file` as `name`, then sets its chat format (ChatFormat.applyAfterImport).
    /// Returns false (with a message) if the import failed or cannot be confirmed.
    private func importFile(_ file: URL, as name: String) async -> Bool {
        progressText = "Importing \(file.lastPathComponent)…"
        do {
            _ = try await OllamaServer.importGGUF(file: file, as: name)
            AppLog.write("ollama: imported \(file.path) as \(name)")
        } catch {
            message = error.localizedDescription
            return false
        }
        progressText = "Checking the chat format…"
        do {
            let note = try await ChatFormat.applyAfterImport(model: name, source: file)
            message = "Imported \(name)." + (note.map { " " + $0 } ?? "")
            return true
        } catch {
            AppLog.write("ollama: \(name) cannot be shown after the import: \(error.localizedDescription)")
            message = "Ollama reported the import of \(name) as done, but cannot show the model (\(error.localizedDescription)), so its chat format was not checked."
            return false
        }
    }

    // MARK: Course models

    /// True when the running server lists `c` under its notebook name (or name:latest).
    func isInstalled(_ c: CourseModel) -> Bool { c.isInstalled(in: models.map(\.name)) }

    /// The status a course row shows: "Installed" or "Not installed" once the server has
    /// listed its models, "Checking…" before that, "Unknown" when it did not answer.
    func courseStatus(_ c: CourseModel) -> String {
        guard modelsKnown else { return refreshing > 0 ? "Checking…" : "Unknown" }
        return isInstalled(c) ? "Installed" : "Not installed"
    }

    /// Asks whether to replace the installed `c`; true for Replace.
    private func confirmReplace(_ c: CourseModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace \(c.name)?"
        alert.informativeText = "A model named \(c.name) is already installed. Download replaces it with the course's copy from \(c.source) (\(c.sizeText))."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks whether to download although the free space suffices only with the space macOS
    /// can reclaim; true for Download Anyway.
    private func confirmLowSpace(_ title: String, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text + " Emptying the Trash or deleting files first avoids this."
        alert.addButton(withTitle: "Download Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The Download button of a course model's row. An installed model is replaced after confirmation.
    func downloadCourseModel(_ c: CourseModel) {
        guard !busy, modelsKnown else { return }
        var confirmed: Set<String> = []
        if isInstalled(c) {
            guard confirmReplace(c) else { return }
            // Main-actor tasks run while this dialog is open, so a new course list may have
            // taken effect meanwhile. Download only an entry the list still has as the dialog
            // described it (same name, source and size).
            guard courseModels.contains(c) else {
                AppLog.write("course models: the list changed while replacing \(c.name) was being confirmed; not downloaded")
                message = "The course list changed while the dialog was open, so \(c.name) was not downloaded. Check its row and try again."
                return
            }
            AppLog.write("course models: replacing the installed \(c.name), as confirmed")
            confirmed.insert(c.name)
        }
        downloadCourseModels([c], replaceConfirmed: confirmed)
    }

    /// The Download All button: every course model that is not installed.
    func downloadAllCourseModels() {
        guard !busy, modelsKnown else { return }
        downloadCourseModels(courseModels.filter { !isInstalled($0) })
    }

    private enum Outcome { case installed, kept, failed }

    /// Downloads the models in `list` one after another, stopping at the first failure or
    /// Cancel. `replaceConfirmed` names the installed models the user agreed to replace; a
    /// model found installed when its turn comes is asked about then.
    private func downloadCourseModels(_ list: [CourseModel], replaceConfirmed: Set<String> = []) {
        guard !busy, !list.isEmpty else { return }
        perform(cancellable: true) {
            AppLog.write("course models: downloading \(list.map(\.name).joined(separator: ", "))")
            var spaceAccepted = false
            if list.count > 1 {
                var total: Int64 = 0
                for c in list {
                    let (t, overflow) = total.addingReportingOverflow(c.size)
                    total = overflow ? .max : t
                }
                switch await self.checkSpace(for: total, what: "the \(list.count) course models", accepted: false) {
                case .refused: return
                case .accepted: spaceAccepted = true
                case .enough: break
                }
            }
            var installed: [String] = []
            var kept: [String] = []
            var cancelledBefore: String?
            for (i, c) in list.enumerated() {
                if Task.isCancelled { cancelledBefore = c.name; break }
                let step = list.count > 1 ? "(\(i + 1) of \(list.count)) " : ""
                switch await self.installCourseModel(c, step: step, replaceConfirmed: replaceConfirmed.contains(c.name),
                                                     spaceAccepted: spaceAccepted) {
                case .installed:
                    installed.append(c.name)
                case .kept:
                    kept.append(c.name)
                case .failed:
                    if !installed.isEmpty {
                        self.message = "Installed \(installed.joined(separator: ", ")). " + (self.message ?? "")
                    }
                    return
                }
            }
            var parts: [String] = []
            if !installed.isEmpty {
                parts.append("Installed \(installed.joined(separator: ", ")). Notebooks can now use "
                    + installed.map { "\"model\": \"\($0)\"" }.joined(separator: ", ") + ".")
            }
            if !kept.isEmpty { parts.append("Kept the installed \(kept.joined(separator: ", ")).") }
            if let cancelledBefore {
                AppLog.write("course models: cancelled before \(cancelledBefore)")
                parts.append(parts.isEmpty ? "Download cancelled." : "Cancelled before \(cancelledBefore).")
            }
            self.message = parts.joined(separator: " ")
        }
    }

    /// Downloads one course model. It reads the installed models, asks before replacing an
    /// installed `c.name` unless `replaceConfirmed`, checks the free space, pulls `c.source`
    /// with progress and Cancel, then names the result `c.name` (nameCourseModel). A source
    /// name that a stopped or failed pull leaves behind is deleted. Sets the message on failure.
    private func installCourseModel(_ c: CourseModel, step: String, replaceConfirmed: Bool,
                                    spaceAccepted: Bool) async -> Outcome {
        let label = step + c.name
        guard let before = await OllamaServer.models()?.map(\.name) else {
            AppLog.write("course models: \(c.name): Ollama did not list its models; not downloaded")
            message = "Could not read the installed models from Ollama, so \(c.name) was not downloaded. Use Restart Ollama, then try again."
            return .failed
        }
        let replacing = c.isInstalled(in: before)
        if replacing && !replaceConfirmed {
            // The row did not read "Installed" when the button was pressed, so ask now.
            guard await runOutsideTask({ self.confirmReplace(c) }) else {
                AppLog.write("course models: \(c.name) is installed; replacing it was declined")
                return .kept
            }
            AppLog.write("course models: replacing the installed \(c.name), as confirmed")
        }
        switch await checkSpace(for: c.size, what: c.name, accepted: spaceAccepted) {
        case .refused: return .failed
        case .enough, .accepted: break
        }
        canCancel = true
        AppLog.write("course models: \(c.name): pulling \(c.source)")
        guard await runPull(c.source, as: c.name, progressPrefix: label + ": ") else {
            canCancel = false
            if !before.contains(c.source) {
                // Ollama may have registered the source although the pull was stopped. This
                // task may be cancelled, so the request runs in a task of its own.
                await Task { await self.removeSourceName(c, left: "by a stopped or failed download") }.value
            }
            return .failed
        }
        canCancel = false
        // The remaining requests are short and run in a task of their own, so a Cancel that
        // arrived as the pull ended cannot stop them halfway.
        let named = await Task { await self.nameCourseModel(c, label: label, replacing: replacing, before: before) }.value
        return named ? .installed : .failed
    }

    /// Deletes the name `c.source` when the server lists it; a failure is only logged.
    private func removeSourceName(_ c: CourseModel, left: String) async {
        guard let names = await OllamaServer.models()?.map(\.name), names.contains(c.source) else { return }
        do {
            try await OllamaServer.delete(c.source)
            AppLog.write("course models: deleted \(c.source), left \(left)")
        } catch {
            AppLog.write("course models: deleting \(c.source), left \(left), failed: \(error.localizedDescription)")
        }
    }

    /// The steps after the pull. For a new model, /api/copy source -> name. For a replacement,
    /// the installed model is first copied to a backup name, then the source is copied over
    /// the name (Ollama overwrites it), and the backup is deleted, which frees the files that
    /// only the old model used; if the copy fails, the name keeps the old model. Then the
    /// source name is deleted and /api/show confirms that the name answers.
    private func nameCourseModel(_ c: CourseModel, label: String, replacing: Bool, before: [String]) async -> Bool {
        var backup: String?
        if replacing {
            let b = Self.backupName(for: c.name, avoiding: before)
            progressText = "\(label): setting the installed copy aside…"
            do {
                try await OllamaServer.copy(c.name, to: b)
                backup = b
                AppLog.write("course models: copied the installed \(c.name) to \(b)")
            } catch {
                AppLog.write("course models: copying the installed \(c.name) to \(b) failed: \(error.localizedDescription); \(c.name) not replaced")
                message = "Downloaded \(c.name), but could not set the installed copy aside (\(error.localizedDescription)), so the installed \(c.name) was kept. The download is installed as \(c.source); Download again to retry."
                return false
            }
        }
        progressText = "\(label): naming it…"
        do {
            try await OllamaServer.copy(c.source, to: c.name)
            AppLog.write("course models: copied \(c.source) to \(c.name)")
        } catch {
            AppLog.write("course models: naming \(c.source) as \(c.name) failed: \(error.localizedDescription)")
            var kept = ""
            if let backup {
                kept = " The installed \(c.name) was kept."
                // The name should still hold the old model; copying the backup back makes sure.
                do {
                    try await OllamaServer.copy(backup, to: c.name)
                    try await OllamaServer.delete(backup)
                    AppLog.write("course models: restored \(c.name) from \(backup) and deleted \(backup)")
                } catch {
                    AppLog.write("course models: restoring \(c.name) from \(backup) failed: \(error.localizedDescription)")
                    kept = " A copy of the installed \(c.name) is kept under the name \(backup)."
                }
            }
            message = "Downloaded \(c.name), but could not give it that name (\(error.localizedDescription)).\(kept) The download is installed as \(c.source); Download again to retry."
            return false
        }
        if let backup {
            progressText = "\(label): removing the replaced copy…"
            do {
                try await OllamaServer.delete(backup)
                AppLog.write("course models: deleted \(backup), the replaced copy of \(c.name), with the files only it used")
            } catch {
                // Not fatal: the list shows the backup name as well.
                AppLog.write("course models: deleting \(backup) failed: \(error.localizedDescription)")
            }
        }
        progressText = "\(label): removing the name \(c.source)…"
        do {
            try await OllamaServer.delete(c.source)
            AppLog.write("course models: deleted \(c.source); \(c.name) keeps its files")
        } catch {
            // Not fatal: the model is installed under both names.
            AppLog.write("course models: deleting \(c.source) failed: \(error.localizedDescription)")
        }
        progressText = "\(label): checking…"
        do {
            AppLog.write("course models: \(c.name) answers /api/show (\(try await Self.showDetails(c.name)))")
            return true
        } catch {
            AppLog.write("course models: /api/show \(c.name) failed: \(error.localizedDescription)")
            message = "Downloaded \(c.name), but Ollama does not show it (\(error.localizedDescription)). Use Restart Ollama, then Download again."
            return false
        }
    }

    /// A name for the installed copy while it is replaced: `name-replaced` (then
    /// `name-replaced-2`, ...), the first one the server does not list.
    nonisolated static func backupName(for name: String, avoiding names: [String]) -> String {
        let taken = Set(names.map(CourseModel.key))
        for n in 1...100 {
            let b = name + (n == 1 ? "-replaced" : "-replaced-\(n)")
            if OllamaServer.isValidModelName(b), !taken.contains(CourseModel.key(b)) { return b }
        }
        return "notebookdeck-replaced-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Parameter size and quantization of `name` from /api/show; throws when Ollama cannot show it.
    nonisolated private static func showDetails(_ name: String) async throws -> String {
        let details = try await OllamaServer.show(name)["details"] as? [String: Any] ?? [:]
        return "\(details["parameter_size"] ?? "?"), \(details["quantization_level"] ?? "?")"
    }

    /// A folder on the volume that holds the models: the bundled server's store, or else the
    /// home folder, where the user's own Ollama usually keeps them (~/.ollama/models).
    private var storeVolume: URL {
        server.mode == .bundled ? OllamaServer.modelStore : FileManager.default.homeDirectoryForCurrentUser
    }

    private enum SpaceAnswer { case enough, accepted, refused }

    /// Checks that the volume holding the models has room for `bytes` plus 1 GB. `enough`
    /// when it has, or when its free space cannot be read. When only space macOS can reclaim
    /// makes it fit, asks first unless `accepted` says the user already agreed, and answers
    /// `accepted` or `refused`. Sets the message when the download does not go ahead.
    private func checkSpace(for bytes: Int64, what: String, accepted: Bool) async -> SpaceAnswer {
        let f = LinkDownload.bytes
        let volume = storeVolume
        let (need, overflow) = bytes.addingReportingOverflow(LinkDownload.reserve)
        if overflow {
            AppLog.write("course models: \(what): size \(bytes) too large; not downloaded")
            message = "Not enough disk space for \(what): the sizes add up to more than any disk holds."
            return .refused
        }
        let head = "course models: \(what): \(f(bytes)) to download, \(f(need)) needed"
        switch LinkDownload.room(for: need, in: volume) {
        case .unknown:
            AppLog.write("\(head); free space on the volume of \(volume.path) unknown, not checked")
            return .enough
        case .enough(let sp):
            AppLog.write("\(head), \(sp.text)")
            return .enough
        case .short(let sp):
            AppLog.write("\(head), \(sp.text); not downloaded, too little free space")
            message = "Not enough disk space for \(what). Downloading \(f(bytes)) needs \(f(need)) free, which leaves 1 GB to spare; the disk has \(sp.text)."
            return .refused
        case .tight(let sp):
            AppLog.write("\(head), \(sp.text); enough only with space macOS can reclaim")
            if accepted { return .accepted }
            let text = "Downloading \(f(bytes)) needs \(f(need)) free, which leaves 1 GB to spare. The disk has \(f(sp.free)) free now. macOS reports \(f(sp.withReclaimable)) counting space it can reclaim, such as local snapshots and cached files, but it may not free that space in time, and the download can then fail part-way."
            let go = await runOutsideTask { self.confirmLowSpace("Download \(what) with little free space?", text) }
            AppLog.write("course models: \(what): downloading with little free space \(go ? "confirmed" : "declined")")
            if go { return .accepted }
            message = "Did not download \(what): the disk has \(sp.text), and the download needs \(f(need))."
            return .refused
        }
    }

    // MARK: Hugging Face

    func clearHFListing() {
        hfFiles = []
        hfSelection = nil
    }

    /// Lists the repo's .gguf files and preselects the one the input names, if any.
    func lookUpHF() {
        guard !busy else { return }
        guard let ref = HFRepoRef(parsing: hfInput) else { message = HFRepoRef.formatHint; return }
        clearHFListing()
        perform(cancellable: false) {
            self.progressText = "Looking up \(ref.repoName)…"
            let listing: HuggingFace.Listing
            do { listing = try await HuggingFace.lookUp(ref) } catch {
                self.message = error.localizedDescription
                return
            }
            self.hfFiles = listing.files
            let count = listing.files.count
            var notes = ["\(ref.repoName) has \(count) GGUF file\(count == 1 ? "" : "s")."]
            if listing.splitCount > 0 {
                let n = listing.splitCount
                notes.append("\(n) quantization\(n == 1 ? " is" : "s are") split into several files and not listed, since Ollama cannot download split GGUFs from Hugging Face.")
            }
            if let file = ref.file {
                self.hfSelection = listing.files.first(where: { $0.path == file })?.path
                if self.hfSelection == nil {
                    notes.append(HuggingFace.isSplitPart(file) ? HuggingFace.splitPartNote(file) : "None is named \(file).")
                }
            } else if let tag = ref.tag?.lowercased() {
                self.hfSelection = listing.files.first(where: {
                    $0.tag.lowercased() == tag || ($0.path as NSString).lastPathComponent.lowercased() == tag
                })?.path
                if self.hfSelection == nil { notes.append("None matches the tag \(ref.tag ?? ""); Download will ask for that tag as typed.") }
            } else if count == 1 {
                self.hfSelection = listing.files[0].path
            }
            if listing.gated { notes.append("The repo is gated (its owner approves each user), so the download may be refused.") }
            self.message = notes.joined(separator: " ")
        }
    }

    /// The tag in the Hugging Face field, if any; the picker's first entry then stands for it.
    var hfTypedTag: String? { HFRepoRef(parsing: hfInput)?.tag }

    /// Pulls hf.co/OWNER/REPO[:TAG]: the file picked after Look Up, else the tag (or file) in the
    /// input, else no tag (Ollama then picks a quantization itself). A file's quantization name
    /// is used as the tag when Hugging Face serves that file under it; otherwise the file's full
    /// name is, which Hugging Face accepts for every file.
    func downloadHF() {
        guard !busy else { return }
        guard let ref = HFRepoRef(parsing: hfInput) else { message = HFRepoRef.formatHint; return }
        let picked = hfSelection.flatMap { sel in hfFiles.first(where: { $0.path == sel }) }
        let fileName = (picked?.path ?? ref.file).map { ($0 as NSString).lastPathComponent }
        if let part = fileName ?? ref.tag, HuggingFace.isSplitPart(part) {
            message = HuggingFace.splitPartNote(part)
            return
        }
        hfDownloaded = nil
        hfAlias = ""
        perform(cancellable: true) {
            var tag = picked?.tag ?? ref.tag
            if let fileName, let t = tag, t != fileName {
                self.progressText = "Checking the tag \(t) on Hugging Face…"
                let size = await HuggingFace.modelSize(ref, tag: t)
                if size == nil || (picked.map { $0.size > 0 && $0.size != size } ?? false) {
                    AppLog.write("hf: \(ref.repoName):\(t) does not give \(fileName); pulling it by file name")
                    tag = fileName
                }
            }
            let name = ref.ollamaName(tag: tag)
            guard await self.runPull(name) else { return }
            self.hfDownloaded = name
            self.message = "Added \(name). Notebooks can use \"model\": \"\(name)\", or a shorter name set below."
        }
    }

    /// Gives the model just pulled from Hugging Face a second, shorter name (POST /api/copy).
    func nameHFModel() {
        guard !busy, let source = hfDownloaded else { return }
        let dest = hfAlias.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return }
        guard OllamaServer.isValidModelName(dest) else {
            message = "\(dest) is not a valid model name. \(OllamaServer.modelNameRule)"
            return
        }
        if models.contains(where: { $0.name == dest || $0.name == dest + ":latest" }) {
            let alert = NSAlert()
            alert.messageText = "Replace \(dest)?"
            alert.informativeText = "A model named \(dest) already exists. The name will point to \(source) instead."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        perform(cancellable: false) {
            self.progressText = "Adding the name \(dest)…"
            do {
                try await OllamaServer.copy(source, to: dest)
                AppLog.write("ollama: copied \(source) to \(dest)")
                self.message = "Notebooks can now use \"model\": \"\(dest)\"."
                self.hfDownloaded = nil
                self.hfAlias = ""
            } catch {
                self.message = "Could not name it \(dest): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Download a GGUF from a link

    /// Downloads the linked file, checks that it is a GGUF, imports it under a name the user
    /// picks, and deletes the download once Ollama has its own copy.
    func downloadLink() {
        guard !busy else { return }
        let url: URL
        do { url = try LinkDownload.directURL(for: linkInput) } catch { message = error.localizedDescription; return }
        perform(cancellable: true) {
            let dir = LinkDownload.downloadsDir
            let file: URL
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                self.progressText = "Contacting \(url.host ?? "the server")…"
                let size = await LinkDownload.contentLength(of: url)
                if let size, let warning = try LinkDownload.checkSpace(for: size, in: dir) {
                    AppLog.write("download: \(LinkDownload.bytes(size)) fits only with space macOS can reclaim; asking")
                    guard await self.runOutsideTask({ self.confirmLowSpace("Download this file with little free space?", warning) }) else {
                        AppLog.write("download: not started, too little free space")
                        self.message = "Did not download the file. " + warning
                        return
                    }
                }
                try Task.checkCancellation()
                AppLog.write("download: \(LinkDownload.redacted(url))")
                file = try await LinkDownload.download(url, into: dir, expectedSize: size) { done, total in
                    Task { @MainActor in
                        let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
                        self.progressFraction = total > 0 ? Double(done) / Double(total) : nil
                        self.progressText = "Downloaded \(f(done))" + (total > 0 ? " of \(f(total))" : "")
                    }
                }
            } catch {
                AppLog.write("download: \(LinkDownload.redacted(url)) failed: \(error.localizedDescription)")
                self.message = Task.isCancelled ? "Download cancelled." : "Could not download the file. \(error.localizedDescription)"
                return
            }
            // A Cancel that arrived as the transfer finished still cancels.
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: file)
                AppLog.write("download: cancelled after the transfer; deleted \(file.path)")
                self.message = "Download cancelled."
                return
            }
            self.canCancel = false
            self.progressFraction = nil
            self.progressText = "Checking \(file.lastPathComponent)…"
            AppLog.write("download: saved \(file.path)")
            guard GGUF.hasMagic(file) else {
                try? FileManager.default.removeItem(at: file)
                AppLog.write("download: \(file.lastPathComponent) is not a GGUF file; deleted")
                self.message = "The link did not lead to a GGUF file (it may be a web page), so the download was deleted."
                return
            }
            self.linkInput = ""
            guard let name = await self.runOutsideTask({ self.askModelName(for: file) }) else {
                self.message = "Kept the download at \(file.path). Use Import GGUF… to add it later."
                return
            }
            if await self.importFile(file, as: name) {
                try? FileManager.default.removeItem(at: file)
                AppLog.write("download: deleted \(file.path) after the import")
            } else {
                self.message = (self.message ?? "Import failed.") + " The download is kept at \(file.path)."
            }
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var mm: ModelManager
    @AppStorage(LaunchPrefs.showModelsWindow) private var showAtLaunch = true

    init() { _mm = ObservedObject(wrappedValue: AppState.shared.modelManager) }

    private var hfEmpty: Bool { mm.hfInput.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Course models") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        ForEach(mm.courseModels) { c in
                            GridRow {
                                Text(c.name).textSelection(.enabled)
                                Text(c.sizeText).monospacedDigit().foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                let status = mm.courseStatus(c)
                                Text(status).foregroundStyle(status == "Installed" ? .green : .secondary)
                                Button("Download") { mm.downloadCourseModel(c) }.disabled(mm.busy || !mm.modelsKnown)
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("The models the lab notebooks use, from hf.co/purdue-ie336. Download any that read Not installed; notebooks ask for them by the names above.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Download All") { mm.downloadAllCourseModels() }
                            .disabled(mm.busy || !mm.modelsKnown || mm.courseModels.allSatisfy { mm.isInstalled($0) })
                    }
                    // Kept in the layout while hidden, so the window does not shift when it appears.
                    Text(mm.courseListOrigin.caption)
                        .font(.caption).foregroundStyle(.tertiary)
                        .opacity(mm.courseListChecked ? 1 : 0)
                        .accessibilityHidden(!mm.courseListChecked)
                }
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mm.serverLabel).font(.headline)
                if !mm.storeLabel.isEmpty {
                    Text(mm.storeLabel).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Table(mm.models) {
                TableColumn("Model", value: \.name)
                TableColumn("Parameters", value: \.parameterSize).width(90)
                TableColumn("Quantization", value: \.quantization).width(100)
                TableColumn("Size") { m in Text(m.sizeText) }.width(80)
                TableColumn("Pulled", value: \.modified).width(90)
                TableColumn("") { m in
                    Button(role: .destructive) { mm.delete(m) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).disabled(mm.busy)
                }.width(30)
            }
            .frame(minHeight: 160)

            GroupBox("Add a model") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name from ollama.com/library, e.g. llama3.2:1b or qwen2.5:7b", text: $mm.pullName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { mm.pull() }
                            .disabled(mm.busy)
                        Button("Pull") { mm.pull() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(mm.busy || mm.pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Import GGUF…") { mm.importGGUF() }.disabled(mm.busy)
                    }
                    Text("Pulling downloads from the Ollama registry into the store above. Notebooks pick a model by the name shown in the first column.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Download from Hugging Face") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("hf.co/owner/repo, owner/repo:Q4_K_M, or a huggingface.co link", text: $mm.hfInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { mm.lookUpHF() }
                            .onChange(of: mm.hfInput) { _, _ in mm.clearHFListing() }
                            .disabled(mm.busy)
                        Button("Look Up") { mm.lookUpHF() }.disabled(mm.busy || hfEmpty)
                        Button("Download") { mm.downloadHF() }.disabled(mm.busy || hfEmpty)
                    }
                    if !mm.hfFiles.isEmpty {
                        Picker("File", selection: $mm.hfSelection) {
                            Text(mm.hfTypedTag.map { "As entered above (\($0))" } ?? "Ollama's default choice").tag(String?.none)
                            ForEach(mm.hfFiles) { f in
                                Text("\(f.path)  (\(f.sizeText))").tag(Optional(f.path))
                            }
                        }
                        .frame(maxWidth: 520)
                        .disabled(mm.busy)
                    }
                    if mm.hfDownloaded != nil {
                        HStack {
                            TextField("Name for notebooks (optional), e.g. irreducibility:3b", text: $mm.hfAlias)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit { mm.nameHFModel() }
                                .disabled(mm.busy)
                            Button("Add Name") { mm.nameHFModel() }
                                .disabled(mm.busy || mm.hfAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Text("Downloads a GGUF repo through Ollama. Ollama applies the repo's own template, system and params files when present.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Download a GGUF from a link") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("https:// link to a .gguf file (Hugging Face, Dropbox, or any direct link)", text: $mm.linkInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(mm.busy)
                        Button("Download") { mm.downloadLink() }
                            .disabled(mm.busy || mm.linkInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("The file is checked, imported under a name you choose, then deleted, since Ollama keeps its own copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if mm.busy {
                HStack {
                    if let f = mm.progressFraction {
                        ProgressView(value: f).frame(maxWidth: 260)
                        Text(String(format: "%.0f%%", f * 100)).font(.caption).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(mm.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if mm.canCancel { Button("Cancel") { mm.cancel() } }
                }
            }
            if let msg = mm.message {
                HStack(alignment: .top) {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { mm.message = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                }
            }

            HStack {
                Button("Refresh") { Task { await mm.refresh() } }.disabled(mm.busy)
                Button("Restart Ollama") { state.restartOllama(); Task { await mm.refresh() } }.disabled(mm.busy)
                Button("Show Log") { state.showOllamaLog() }
                Spacer()
                Toggle("Show this window when NotebookDeck opens", isOn: $showAtLaunch)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 720)
        .task { await mm.refresh() }
    }
}
